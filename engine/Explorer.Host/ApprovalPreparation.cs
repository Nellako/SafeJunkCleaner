using SafeJunkCleaner.Explorer.Execution;

namespace SafeJunkCleaner.Explorer.Host;

internal sealed partial class ExplorerCoordinator
{
    private readonly Dictionary<string, PreparationWork> preparations = new(StringComparer.Ordinal);
    private readonly AsyncLocal<CancellationToken?> preparationToken = new();
    private void AssertNoPreparation()
    {
        if (preparations.Values.Any(p => !p.Work.IsCompleted)) throw new InvalidOperationException("ApprovalPreparationActive");
    }
    internal object BeginPrepareApproval(string taskId, string analysisId, string[] suggestionIds, long revision)
    {
        lock (gate)
        {
            Alive(); AssertNoPreparation();
            if (executions.Values.Any(e => !e.Work.IsCompleted)) throw new InvalidOperationException("ExecutionEvidenceReservationActive");
            var analysis = OwnedAnalysis(taskId, analysisId);
            if (analysis.Revision != revision || analysis.Result == null) throw new InvalidOperationException("AnalysisNotReadyOrChanged");
            var permitted = analysis.Result.Suggestions.Where(s => s.MayPrepareForReview && s.Classification is Analysis.Classification.Cache or Analysis.Classification.BuildArtifact)
                .Select(s => SuggestionId(analysis.Result, s)).ToHashSet(StringComparer.Ordinal);
            if (suggestionIds.Length is < 1 or > 128 || suggestionIds.Distinct().Count() != suggestionIds.Length || suggestionIds.Any(s => !permitted.Contains(s))) throw new InvalidOperationException("SuggestionSetNotReviewable");
            foreach (var old in preparations.Where(p => p.Value.Work.IsCompleted).Select(p => p.Key).ToArray())
            { preparations[old].Cancellation.Dispose(); preparations.Remove(old); }
            string id = Guid.NewGuid().ToString("D"); var work = new PreparationWork(taskId, analysisId);
            preparations.Add(id, work);
            work.Work = Task.Run(() =>
            {
                var clock = System.Diagnostics.Stopwatch.StartNew();
                try
                {
                    preparationToken.Value = work.Cancellation.Token;
                    var draft = approval.PrepareApproval(taskId, suggestionIds, work.Cancellation.Token, (done, total) =>
                    { lock (gate) { work.Checked = done; work.Total = total; work.Stage = "CheckingFiles"; } });
                    lock (gate)
                    {
                        work.Cancellation.Token.ThrowIfCancellationRequested(); Current(analysis);
                        if (!analyses.TryGetValue(analysisId, out var current) || current != analysis) throw new InvalidOperationException("AnalysisRevisionInvalidated");
                        draftAnalyses[draft.DraftId] = analysisId; work.Draft = draft; work.Stage = "Ready"; work.Status = "Ready";
                    }
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    lock (gate) { work.Status = ex is OperationCanceledException ? "Cancelled" : "Failed"; work.Stage = work.Status;
                        string code = AnalysisFailureCode(ex);
                        work.Error = ex is OperationCanceledException ? "ExplicitCancellation" : code.StartsWith("AnalysisFailed:", StringComparison.Ordinal) ? "ApprovalPreparationFailed:" + ex.GetType().Name : code; }
                }
                finally { preparationToken.Value = null; lock (gate) work.ElapsedMilliseconds = clock.Elapsed.TotalMilliseconds; }
            });
            return PreparationResult(id, work);
        }
    }
    private PreparationWork OwnedPreparation(string taskId, string id)
    {
        Alive();
        if (!preparations.TryGetValue(id, out var work) || work.TaskId != taskId) throw new InvalidOperationException("PreparationNotOwnedOrMissing");
        _ = OwnedAnalysis(taskId, work.AnalysisId); return work;
    }
    internal object GetPreparationProgress(string taskId, string id)
    { lock (gate) return PreparationResult(id, OwnedPreparation(taskId, id)); }
    internal void CancelPreparation(string taskId, string id)
    { lock (gate) { var work = OwnedPreparation(taskId, id); if (!work.Work.IsCompleted) work.Cancellation.Cancel(); } }
    private static object PreparationResult(string id, PreparationWork work) => new
    {
        PreparationId = id, Status = work.Work.IsCompleted ? work.Status : "Running", work.Stage, CheckedFiles = work.Checked, TotalFiles = work.Total,
        ElapsedMilliseconds = work.Work.IsCompleted ? work.ElapsedMilliseconds : work.Clock.Elapsed.TotalMilliseconds, ErrorCode = work.Error,
        Prepared = work.Work.IsCompleted && work.Status == "Ready" && work.Draft is { } d ? new
        { d.DraftId, d.DisplayHash, d.CandidateSetHash, d.LogicalBytes, ItemCount = d.Items.Length, RecycleOnly = true, RecycleEnabled = false, AlgorithmMode = "Heuristic" } : null
    };
    private sealed class PreparationWork(string taskId, string analysisId)
    {
        internal readonly string TaskId = taskId, AnalysisId = analysisId;
        internal readonly System.Diagnostics.Stopwatch Clock = System.Diagnostics.Stopwatch.StartNew();
        internal readonly CancellationTokenSource Cancellation = new();
        internal Task Work = Task.CompletedTask;
        internal string Status = "Running", Stage = "ReadingSuggestions";
        internal int Checked, Total; internal double ElapsedMilliseconds; internal string? Error; internal ApprovalDraft? Draft;
    }
}
