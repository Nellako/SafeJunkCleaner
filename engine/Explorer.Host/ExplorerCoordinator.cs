using SafeJunkCleaner.Explorer.Analysis;
using SafeJunkCleaner.Explorer.Application;
using SafeJunkCleaner.Explorer.Execution;

namespace SafeJunkCleaner.Explorer.Host;

// Inventory lifetime and trusted row export remain owned by the Inventory engine.
// This coordinator never accepts paths/candidate files from the wire or a decider.
internal sealed partial class ExplorerCoordinator : ITrustedAnalysisSnapshots, ITrustedInventorySnapshots, ITrustedAnalysisBuildContext, IHostProofContext, IDisposable
{
    private readonly InventorySnapshotAdapter inventory;
    private readonly ITrustedInventoryRows rows;
    private readonly IApprovalStore store;
    private readonly IApprovalSource source;
    private readonly ApprovalExecutor approval;
    private readonly IRecycleOnly recycler;
    private readonly StaExecutionQueue sta = new();
    private readonly object gate = new();
    private readonly OpaqueCursorCodec cursors = new();
    private readonly Dictionary<string, AnalysisWork> analyses = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ExecutionWork> executions = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> draftAnalyses = new(StringComparer.Ordinal);
    private readonly AsyncLocal<AnalysisWork?> building = new();
    internal bool RecycleAvailable => recycler.IsAvailable;
    internal void AssertIdle()
    {
        lock (gate)
        {
            Alive();
            AssertNoPreparation();
            if (analyses.Values.Any(w => !w.Work.IsCompleted) || executions.Values.Any(w => !w.Work.IsCompleted)) throw new InvalidOperationException("SessionWorkActive");
        }
    }
    internal object GetSessionInfo()
    {
        lock (gate) return new { AnalysisSessions = analyses.Count, AnalysisLimit = 8, ActiveAnalyses = analyses.Values.Count(w => !w.Work.IsCompleted),
            ExecutionSessions = executions.Count, ActiveExecutions = executions.Values.Count(w => !w.Work.IsCompleted), ExecutionLimit = 8,
            DraftBindings = draftAnalyses.Count, ApprovalStorage = store is IApprovalMaintenance m ? m.GetStorageInfo(draftAnalyses.Keys.ToHashSet(StringComparer.Ordinal)) : null };
    }
    internal object ArchiveUnconfirmedDrafts(bool confirmed)
    {
        lock (gate)
        {
            AssertIdle();
            if (store is not IApprovalMaintenance m) throw new InvalidOperationException("ApprovalMaintenanceUnavailable");
            return m.ArchiveUnconfirmed(draftAnalyses.Keys.ToHashSet(StringComparer.Ordinal), confirmed);
        }
    }
    internal object ReleaseFinishedSessions(bool confirmed)
    {
        lock (gate)
        {
            if (!confirmed) throw new InvalidOperationException("ExplicitSessionReleaseConfirmationRequired");
            AssertIdle();
            int count = analyses.Count;
            foreach (var w in analyses.Values) w.Cancellation.Dispose();
            analyses.Clear(); draftAnalyses.Clear();
            foreach (var w in executions.Values) w.Cancellation.Dispose();
            executions.Clear();
            return new { ReleasedAnalyses = count, ExistingApprovalsInvalidated = true, PersistedClaimsAndLedgersRetained = true };
        }
    }
    private void PruneFinishedExecutions()
    {
        foreach (var id in executions.Where(p => p.Value.Work.IsCompleted).Select(p => p.Key).ToArray())
        { executions[id].Cancellation.Dispose(); executions.Remove(id); }
    }
    public CancellationToken BuildCancellationToken => preparationToken.Value ?? building.Value?.BuildToken ?? CancellationToken.None;
    public ProofHashSession? ProofHashes => building.Value?.ProofHashes;
    private bool disposed;
    private readonly Action<string>? registerBuildTask;
    private readonly TimeSpan analysisDuration;
    private readonly long investigationHashBytes;
    private readonly int investigationHashFiles;
    private readonly bool completeAnalysis;
    internal ExplorerCoordinator(ITrustedInventoryRows rows, string ownerSid, IApprovalStore store,
        IExecutionFacts facts, IRecycleOnly recycler, Func<ITrustedAnalysisSnapshots, IApprovalSource> sourceFactory, Action<string>? registerBuildTask = null, TimeSpan? analysisDuration = null, long investigationHashBytes = 268435456, int investigationHashFiles = 64)
    {
        this.rows = rows; inventory = new(rows, ownerSid); this.store = store; this.recycler = recycler; this.registerBuildTask = registerBuildTask;
        completeAnalysis = analysisDuration == null;
        this.analysisDuration = analysisDuration ?? TimeSpan.FromSeconds(30);
        if (this.analysisDuration <= TimeSpan.Zero || this.analysisDuration > TimeSpan.FromSeconds(30)) throw new ArgumentOutOfRangeException(nameof(analysisDuration));
        if (investigationHashBytes is < 0 or > 268435456 || investigationHashFiles is < 0 or > 64) throw new ArgumentOutOfRangeException(nameof(investigationHashBytes));
        this.investigationHashBytes = investigationHashBytes; this.investigationHashFiles = investigationHashFiles;
        source = sourceFactory(this); approval = new(source, facts, store, recycler);
    }
    internal object Analyze(string taskId, string? targetId, long expectedRevision, string explorationMode = "Selected")
    {
        lock (gate)
        {
            Alive();
            AssertNoPreparation();
            if (explorationMode is not ("Scope" or "Selected") || explorationMode == "Scope" && targetId != null || explorationMode == "Selected" && string.IsNullOrEmpty(targetId)) throw new InvalidOperationException("InvalidExplorationModeTarget");
            if (analyses.Values.Any(w => !w.Work.IsCompleted)) throw new InvalidOperationException("AnalysisWorkerBusy");
            if (analyses.Values.Any(w => w.TaskId == taskId)) throw new InvalidOperationException("InvalidatePreviousAnalysisFirst");
            if (executions.Values.Any(w => w.TaskId == taskId && !w.Work.IsCompleted)) throw new InvalidOperationException("TaskHasActiveWork");
            if (analyses.Count >= 8) throw new InvalidOperationException("AnalysisQuotaInvalidatePrevious");
            var header = rows.ReadHeader(taskId);
            if (header.Revision != expectedRevision || header.State is not ("Ready" or "Partial")) throw new InvalidOperationException("InventoryRevisionOrStageChanged");
            // Return the analysis identity before any paged export, path validation,
            // hashing or canonical display preparation. These stay off the JSONL reader.
            string analysisId = Guid.NewGuid().ToString("D"); var work = new AnalysisWork(taskId, expectedRevision, explorationMode, header);
            analyses.Add(analysisId, work);
            work.Work = Task.Run(async () =>
            {
                var clock = System.Diagnostics.Stopwatch.StartNew();
                using var deadline = completeAnalysis ? new CancellationTokenSource() : new CancellationTokenSource(analysisDuration);
                using var linked = CancellationTokenSource.CreateLinkedTokenSource(work.Cancellation.Token, deadline.Token);
                try
                {
                    lock (gate) work.Progress = work.Progress with { Reason = "LoadingInventorySnapshot" };
                    var adapted = inventory.Load(taskId, expectedRevision, linked.Token, targetId);
                    if (adapted.Header != header) throw new InvalidOperationException("InventoryRevisionChangedDuringAnalysis");
                    if (targetId != null && !adapted.Evidence.Targets.ContainsKey(targetId)) throw new InvalidOperationException("TargetNotInInventory");
                    linked.Token.ThrowIfCancellationRequested();
                    lock (gate) { work.Snapshot = adapted; work.SnapshotMilliseconds = clock.Elapsed.TotalMilliseconds; }
                    var remaining = analysisDuration - clock.Elapsed;
                    if (!completeAnalysis && remaining <= TimeSpan.Zero) throw new OperationCanceledException(deadline.Token);
                    var progress = new InlineProgress<HeuristicProgress>(p => { lock (gate) work.Progress = p; });
                    var result = await new HeuristicExplorationScheduler().ExploreAsync(adapted.Evidence, targetId, new HeuristicBudget(MaxDuration: completeAnalysis ? null : remaining, MaxHashBytes: investigationHashBytes, MaxHashFiles: investigationHashFiles, UntilComplete: completeAnalysis), progress, linked.Token);
                    if (rows.ReadHeader(taskId) != adapted.Header) throw new InvalidOperationException("InventoryRevisionChangedDuringAnalysis");
                    linked.Token.ThrowIfCancellationRequested();
                    lock (gate) work.AnalysisMilliseconds = clock.Elapsed.TotalMilliseconds - work.SnapshotMilliseconds;
                    result = AnalysisCandidateSet.Normalize(result, adapted.Evidence);
                    work.PendingResult = result with { Reason = result.Reason + "|HostAnalysis:" + analysisId };
                    lock (gate) work.Progress = work.Progress with { Reason = "PreparingSuggestionDisplay", CurrentTargetId = null };
                    work.BuildToken = linked.Token; building.Value = work;
                    bool fullProof = completeAnalysis && investigationHashBytes == 268435456 && investigationHashFiles == 64;
                    using var proofHashes = new ProofHashSession(fullProof ? long.MaxValue : investigationHashBytes, fullProof ? int.MaxValue : investigationHashFiles, result.Usage, linked.Token);
                    work.ProofHashes = proofHashes;
                    var preparedSource = source.Read(taskId);
                    // Final counters and whole-group budget decisions are bound BEFORE
                    // the canonical source used for review is published/sealed.
                    var denied = result.Suggestions.Where(s => s.CandidateFiles.Any(f => proofHashes.DeniedIdentities.Contains(f.FileIdentity))).Select(s => s.SuggestionId).ToHashSet(StringComparer.Ordinal);
                    result = result with { Usage = proofHashes.Merge(), Status = denied.Count > 0 ? AnalysisStatus.BudgetExhausted : result.Status, Reason = denied.Count > 0 ? ProofHashSession.BudgetReason : result.Reason, Suggestions = result.Suggestions.Select(s => denied.Contains(s.SuggestionId)
                        ? s with { HardProtected = true, Doubts = s.Doubts.Concat([ProofHashSession.BudgetReason]).ToArray() } : s).ToArray() };
                    work.PendingResult = result with { Reason = result.Reason + "|HostAnalysis:" + analysisId };
                    work.ProofBlockedSuggestions = denied;
                    proofHashes.Sealed = true;
                    var finalSource = source.Read(taskId);
                    // Exact canonical groups must be unchanged by final Usage binding;
                    // only SuggestionRevision changes. Recheck once using held hashes.
                    if (System.Text.Json.JsonSerializer.Serialize(preparedSource.Suggestions.Where(s => !s.HardProtected)) != System.Text.Json.JsonSerializer.Serialize(finalSource.Suggestions.Where(s => !s.HardProtected))) throw new InvalidOperationException("ProofSourceChangedDuringBinding");
                    var display = finalSource.Suggestions.ToDictionary(s => s.SuggestionId, StringComparer.Ordinal);
                    building.Value = null;
                    linked.Token.ThrowIfCancellationRequested();
                    if (rows.ReadHeader(taskId) != header) throw new InvalidOperationException("InventoryRevisionChangedDuringAnalysis");
                    lock (gate)
                    {
                        work.DisplaySource = display; work.Result = work.PendingResult; work.PendingResult = null;
                        work.TotalMilliseconds = clock.Elapsed.TotalMilliseconds;
                        work.DisplayMilliseconds = Math.Max(0, work.TotalMilliseconds - work.SnapshotMilliseconds - work.AnalysisMilliseconds);
                        work.Progress = work.Progress with { HasMore = result.Status == AnalysisStatus.BudgetExhausted, CurrentTargetId = null, Reason = result.Reason };
                        registerBuildTask?.Invoke(taskId);
                    }
                }
                catch (Exception ex)
                {
                    lock (gate)
                    {
                        bool timedOut = ex is OperationCanceledException && !work.Cancellation.IsCancellationRequested && deadline.IsCancellationRequested;
                        work.Error = timedOut ? "BudgetExhausted" : ex is OperationCanceledException ? "Cancelled" : "Failed";
                        work.ErrorReason = timedOut ? "DurationBudget" : ex is OperationCanceledException ? "ExplicitCancellation" : AnalysisFailureCode(ex);
                        work.TotalMilliseconds = clock.Elapsed.TotalMilliseconds;
                        if (work.Snapshot == null) work.SnapshotMilliseconds = work.TotalMilliseconds;
                        work.PendingResult = null; work.Snapshot = null; work.DisplaySource = null;
                        work.Progress = work.Progress with { HasMore = timedOut, Reason = work.ErrorReason, CurrentTargetId = null };
                    }
                }
                finally
                {
                    lock (gate) if (work.ProofHashes != null) work.FinalUsage = work.ProofHashes.Merge();
                    building.Value = null;
                }
            });
            return ProgressResult(analysisId, work, "Started");
        }
    }
    internal object GetAnalysisProgress(string taskId, string analysisId)
    {
        lock (gate) { var w = OwnedAnalysis(taskId, analysisId); return ProgressResult(analysisId, w); }
    }
    private static string AnalysisFailureCode(Exception exception)
    {
        // Only fixed internal codes cross the UI boundary; exception messages can contain paths.
        string[] safeCodes = ["AnalysisMemoryPressure", "AnalysisResourcePressure", "SourceChangedDuringApprovalRead", "ApprovalRevisionChanged", "ArtifactTooLarge", "ApprovalStorageQuota", "InvalidCandidateCount", "UnsafeOrOccupiedFile", "TargetNotInInventory", "NonCanonicalPath", "UnsupportedPath", "InventoryOutsideScope",
            "InventoryRootUnavailable", "InventoryRootMismatch", "InventoryRevisionChangedDuringExport",
            "InventoryRevisionChangedDuringAnalysis", "InvalidInventoryParent", "InvalidInventoryRow",
            "InventoryLimitOrDuplicateObject", "DuplicateInventoryPath", "UnownedOrUnstableInventory",
            "ProofSourceChangedDuringBinding", "AnalysisUnavailable", "InvalidAnalysisSnapshot"];
        return exception is InvalidOperationException && safeCodes.Contains(exception.Message, StringComparer.Ordinal)
            ? exception.Message : "AnalysisFailed:" + exception.GetType().Name;
    }
    private static object ProgressResult(string id, AnalysisWork w, string? status = null) => new
    {
        AnalysisId = id, Status = status ?? w.Result?.Status.ToString() ?? w.Error ?? "Running", Reason = w.Result?.Reason ?? w.ErrorReason ?? w.Progress.Reason,
        Usage = w.Result?.Usage ?? w.FinalUsage, HasResult = w.Result != null, ExplorationMode = w.Mode, Progress = w.Progress,
        Timing = new { SnapshotMilliseconds = w.SnapshotMilliseconds, AnalysisMilliseconds = w.AnalysisMilliseconds, ProofAndDisplayMilliseconds = w.DisplayMilliseconds, TotalMilliseconds = w.TotalMilliseconds },
        Outcome = w.DisplaySource == null ? null : new
        {
            ReviewGroups = w.DisplaySource.Values.Count(s => !s.HardProtected && s.Classification is ProcessingClass.ReviewSuggested or ProcessingClass.VerifiedCache),
            ReviewLogicalBytes = w.DisplaySource.Values.Where(s => !s.HardProtected && s.Classification is ProcessingClass.ReviewSuggested or ProcessingClass.VerifiedCache).SelectMany(s => s.Files).Sum(f => f.Size),
            DisplayOnlyGroups = w.DisplaySource.Values.Count(s => s.HardProtected || s.Classification is not (ProcessingClass.ReviewSuggested or ProcessingClass.VerifiedCache)),
            IncompleteObjects = w.Snapshot?.Coverage.Count(c => c.Coverage != "Complete") ?? 0,
            ReasonCounts = w.Result == null ? null : w.Result.Suggestions.Select(s =>
            {
                bool review = w.DisplaySource.TryGetValue(SuggestionId(w.Result, s), out var canonical) && !canonical.HardProtected && canonical.Classification is ProcessingClass.VerifiedCache or ProcessingClass.ReviewSuggested;
                return SuggestionReasons.For(w.Result, s, review, w.ProofBlockedSuggestions.Contains(s.SuggestionId)).Category;
            }).GroupBy(c => c).ToDictionary(g => g.Key, g => g.Count(), StringComparer.Ordinal)
        }
    };
    internal void CancelAnalysis(string taskId, string analysisId)
    {
        lock (gate) { var w = OwnedAnalysis(taskId, analysisId); if (!w.Work.IsCompleted) w.Cancellation.Cancel(); }
    }
    public AnalysisResult Read(string taskId, long revision)
    {
        lock (gate)
        {
            var w = building.Value is { } pending && pending.TaskId == taskId && pending.Revision == revision ? pending
                : analyses.Values.SingleOrDefault(w => w.TaskId == taskId && w.Revision == revision && w.Result != null) ?? throw new InvalidOperationException("AnalysisUnavailable");
            Current(w); return w.Result ?? w.PendingResult ?? throw new InvalidOperationException("AnalysisUnavailable");
        }
    }
    public AdaptedInventory ReadInventory(string taskId, long revision)
    {
        lock (gate)
        {
            var w = building.Value is { } pending && pending.TaskId == taskId && pending.Revision == revision ? pending
                : analyses.Values.SingleOrDefault(w => w.TaskId == taskId && w.Revision == revision && w.Result != null) ?? throw new InvalidOperationException("AnalysisUnavailable");
            Current(w); return w.Snapshot ?? throw new InvalidOperationException("AnalysisUnavailable");
        }
    }
    private AnalysisWork OwnedAnalysis(string taskId, string analysisId)
    {
        Alive();
        if (!analyses.TryGetValue(analysisId, out var w) || w.TaskId != taskId) throw new InvalidOperationException("AnalysisNotOwnedOrMissing");
        Current(w); return w;
    }
    private void Current(AnalysisWork w)
    {
        var header = rows.ReadHeader(w.TaskId);
        if (header != w.Header) throw new InvalidOperationException("AnalysisRevisionInvalidated");
    }
    private static string SuggestionId(AnalysisResult r, Suggestion s) => StableIds.Create(r.TaskId, r.Revision, "suggestion", s.SuggestionId);
    internal object QuerySuggestions(string taskId, string analysisId, string? afterId, int size)
    {
        lock (gate)
        {
            Page(size); var w = OwnedAnalysis(taskId, analysisId); var r = w.Result ?? throw new InvalidOperationException("AnalysisNotReady");
            int offset = cursors.Decode(afterId, taskId, r.Revision, analysisId, AnalysisCandidateSet.Sort, "suggestions");
            var sorted = r.Suggestions.OrderBy(AnalysisCandidateSet.ReviewRank).ThenByDescending(AnalysisCandidateSet.LogicalBytes).ThenBy(s => s.SuggestionId, StringComparer.Ordinal).ToArray();
            if (offset > sorted.Length) throw new InvalidOperationException("InvalidCursor");
            // Canonical adapter applies complete-ancestor, per-file protections,
            // and the narrow trusted DLL binder; display matches approval policy.
            var canonical = w.DisplaySource ?? throw new InvalidOperationException("AnalysisNotReady");
            var items = sorted.Skip(offset).Take(size).Select(s =>
            {
                string id = SuggestionId(r, s);
                bool eligible = canonical.TryGetValue(id, out var candidate) && !candidate.HardProtected && candidate.Classification is ProcessingClass.VerifiedCache or ProcessingClass.ReviewSuggested;
                var reason = SuggestionReasons.For(r, s, eligible, w.ProofBlockedSuggestions.Contains(s.SuggestionId));
                return new
                {
                    SuggestionId = id, s.TargetId, TargetPath = w.Snapshot!.Evidence.Targets[s.TargetId].Path, Classification = s.Classification.ToString(), Level = s.Level.ToString(), CandidateCount = s.CandidateFiles.Count,
                    LogicalBytes = AnalysisCandidateSet.LogicalBytes(s), s.Impact, s.Doubts, s.HardProtected, SelectedByDefault = false,
                    s.EvidenceIds, MayPrepareForReview = eligible, ApprovalBlockedReason = eligible ? null : w.ProofBlockedSuggestions.Contains(s.SuggestionId) ? ProofHashSession.BudgetReason : "DeterministicProtectionOrExecutionPolicy",
                    ReasonCategory = reason.Category, ReasonCode = reason.Code, ReviewHint = reason.Hint,
                    DuplicateSummary = s.Duplicate == null ? null : new { s.Duplicate.ContentSha256, RetainedCount = s.Duplicate.RetainedFiles.Count, s.Duplicate.RetainedChoiceConfirmed }
                };
            }).ToArray();
            return new { Items = items, NextAfterId = offset + items.Length < sorted.Length ? cursors.Encode(taskId, r.Revision, analysisId, AnalysisCandidateSet.Sort, "suggestions", offset + items.Length) : null,
                AnalysisStatus = r.Status.ToString(), Revision = r.Revision, Sort = AnalysisCandidateSet.Sort, CursorSchema = "opaque-hmac-v1",
                NoResultReason = sorted.Length == 0 ? r.Status == AnalysisStatus.BudgetExhausted ? "InvestigationBudgetExceeded" : "NoSupportedLayoutEvidence" : null };
        }
    }
    internal object QuerySuggestionFiles(string taskId, string analysisId, string suggestionId, string? afterId, int size)
    {
        lock (gate)
        {
            Page(size); var w = OwnedAnalysis(taskId, analysisId); var r = w.Result ?? throw new InvalidOperationException("AnalysisNotReady");
            var suggestion = r.Suggestions.SingleOrDefault(s => SuggestionId(r, s) == suggestionId) ?? throw new InvalidOperationException("SuggestionNotOwnedOrMissing");
            const string sort = "objectid-ordinal-v1";
            int offset = cursors.Decode(afterId, taskId, r.Revision, analysisId, sort, suggestionId);
            var sorted = suggestion.CandidateFiles.OrderBy(f => f.ObjectId, StringComparer.Ordinal).ToArray();
            if (offset > sorted.Length) throw new InvalidOperationException("InvalidCursor");
            var items = sorted.Skip(offset).Take(size).Select(f => new { f.ObjectId, Path = w.Snapshot!.Evidence.Targets[f.ObjectId].Path, f.FileIdentity, f.LogicalBytes, f.ModifiedUtcTicks, f.ContentSha256 }).ToArray();
            return new { Items = items, NextAfterId = offset + items.Length < sorted.Length ? cursors.Encode(taskId, r.Revision, analysisId, sort, suggestionId, offset + items.Length) : null,
                Revision = r.Revision, Sort = sort, CursorSchema = "opaque-hmac-v1" };
        }
    }
    internal object PrepareApproval(string taskId, string analysisId, string[] suggestionIds, long revision)
    {
        lock (gate)
        {
            AssertNoPreparation();
            if (executions.Values.Any(e => !e.Work.IsCompleted)) throw new InvalidOperationException("ExecutionEvidenceReservationActive");
            var w = OwnedAnalysis(taskId, analysisId);
            if (w.Revision != revision || w.Result == null) throw new InvalidOperationException("AnalysisNotReadyOrChanged");
            var permitted = w.Result.Suggestions.Where(s => s.MayPrepareForReview && s.Classification is Classification.Cache or Classification.BuildArtifact).Select(s => SuggestionId(w.Result, s)).ToHashSet(StringComparer.Ordinal);
            if (suggestionIds.Length is < 1 or > 128 || suggestionIds.Distinct().Count() != suggestionIds.Length || suggestionIds.Any(s => !permitted.Contains(s))) throw new InvalidOperationException("SuggestionSetNotReviewable");
            var draft = approval.PrepareApproval(taskId, suggestionIds); draftAnalyses[draft.DraftId] = analysisId;
            return new { draft.DraftId, draft.DisplayHash, draft.CandidateSetHash, draft.LogicalBytes, ItemCount = draft.Items.Length, RecycleOnly = true, RecycleEnabled = false, AlgorithmMode = "Heuristic" };
        }
    }
    internal object QueryApprovalItems(string taskId, string draftId, int after, int size)
    {
        lock (gate)
        {
            Page(size); if (after < 0) throw new InvalidOperationException("InvalidPage");
            var draft = OwnedDraft(taskId, draftId); var items = draft.Items.Skip(after).Take(size).ToArray();
            return new { draft.DisplayHash, draft.CandidateSetHash, draft.LogicalBytes, Items = items, NextAfter = after + items.Length < draft.Items.Length ? (int?)(after + items.Length) : null };
        }
    }
    private void CurrentDraft(ApprovalDraft draft)
    {
        if (!draftAnalyses.TryGetValue(draft.DraftId, out var id)) throw new InvalidOperationException("ApprovalAnalysisInvalidated");
        var w = OwnedAnalysis(draft.TaskId, id);
        if (w.Result == null) throw new InvalidOperationException("ApprovalAnalysisInvalidated");
    }
    private ApprovalDraft OwnedDraft(string taskId, string draftId)
    {
        var draft = store.ReadDraft(draftId);
        if (draft.TaskId != taskId) throw new InvalidOperationException("DraftNotOwnedByTask");
        CurrentDraft(draft); return draft;
    }
    internal object ConfirmApproval(string taskId, string draftId, string displayHash)
    {
        lock (gate)
        {
            AssertNoPreparation();
            _ = OwnedDraft(taskId, draftId); var approvalId = approval.ConfirmApproval(draftId, displayHash);
            return new { ApprovalId = approvalId, RecycleEnabled = recycler.IsAvailable, CanExecute = recycler.IsAvailable };
        }
    }
    internal object ExecuteApproved(string taskId, string approvalId)
    {
        lock (gate)
        {
            Alive();
            AssertNoPreparation();
            if (!recycler.IsAvailable) throw new InvalidOperationException("RecycleDisabledNoClaimConsumed");
            var seal = store.ReadSeal(approvalId);
            if (seal.Draft.TaskId != taskId) throw new InvalidOperationException("ApprovalNotOwnedByTask");
            CurrentDraft(seal.Draft);
            if (executions.ContainsKey(approvalId) || store is IApprovalMaintenance maintenance && maintenance.IsClaimed(approvalId)) throw new InvalidOperationException("ExecutionAlreadyRequested");
            PruneFinishedExecutions();
            if (executions.Count >= 8) throw new InvalidOperationException("ExecutionSessionLimit");
            var w = new ExecutionWork(taskId); executions.Add(approvalId, w);
            try { w.Work = sta.Enqueue(token => approval.ExecuteApproved(approvalId, token), w.Cancellation.Token); }
            catch { executions.Remove(approvalId); w.Cancellation.Dispose(); throw; }
            return new { ExecutionId = approvalId, Status = "Queued", RecycleEnabled = false };
        }
    }
    internal object GetExecutionResult(string taskId, string approvalId, int after, int size)
    {
        lock (gate)
        {
            Page(size); if (after < 0) throw new InvalidOperationException("InvalidPage");
            var seal = store.ReadSeal(approvalId); if (seal.Draft.TaskId != taskId) throw new InvalidOperationException("ApprovalNotOwnedByTask");
            _ = rows.ReadHeader(taskId);
            if (executions.TryGetValue(approvalId, out var w) && !w.Work.IsCompleted) return new { Status = "Running", Entries = Array.Empty<ExecutionEntry>(), NextAfter = (int?)null, RecycleEnabled = false };
            if (w?.Work.IsFaulted == true) throw new InvalidOperationException("ExecutionRejected");
            var r = approval.GetExecutionResult(approvalId);
            var paths = seal.Draft.Items.ToDictionary(i => i.File.ObjectId, i => i.File.Path, StringComparer.Ordinal);
            if (r.Entries.Any(e => !paths.ContainsKey(e.ObjectId))) throw new InvalidOperationException("LedgerObjectNotInDraft");
            if (after > r.Entries.Length) throw new InvalidOperationException("InvalidPage");
            var entries = r.Entries.Skip(after).Take(size).Select(e => new { e.ObjectId, Path = paths[e.ObjectId], e.Status, e.Reason, e.LogicalBytes }).ToArray();
            var final = r.Entries.GroupBy(e => e.ObjectId).Select(g => g.Last()).ToArray();
            return new { r.Status, Entries = entries, NextAfter = after + entries.Length < r.Entries.Length ? (int?)(after + entries.Length) : null, r.RecycledLogicalBytes,
                LedgerEntries = r.Entries.Length, ExpectedItems = seal.Draft.Items.Length, FinalItems = final.Length,
                RecycledItems = final.Count(e => e.Status == "Recycled"), SkippedItems = final.Count(e => e.Status is "Skipped" or "NotAttempted"),
                UnknownItems = final.Count(e => e.Status is not ("Recycled" or "Skipped" or "NotAttempted")), RecycleEnabled = false };
        }
    }
    internal void CancelExecution(string taskId, string approvalId)
    {
        lock (gate)
        {
            _ = rows.ReadHeader(taskId);
            if (!executions.TryGetValue(approvalId, out var w) || w.TaskId != taskId) throw new InvalidOperationException("ExecutionNotOwnedOrMissing");
            w.Cancellation.Cancel();
        }
    }
    internal void InvalidateAnalysis(string taskId, string analysisId)
    {
        lock (gate)
        {
            Alive();
            AssertNoPreparation();
            if (!analyses.TryGetValue(analysisId, out var w) || w.TaskId != taskId) throw new InvalidOperationException("AnalysisNotOwnedOrMissing");
            _ = rows.ReadHeader(taskId);
            if (!w.Work.IsCompleted || executions.Values.Any(e => e.TaskId == taskId && !e.Work.IsCompleted)) throw new InvalidOperationException("TaskHasActiveWork");
            analyses.Remove(analysisId); w.Cancellation.Dispose();
            foreach (var id in draftAnalyses.Where(p => p.Value == analysisId).Select(p => p.Key).ToArray()) draftAnalyses.Remove(id);
        }
    }
    internal void AssertCanChangeInventory(string taskId)
    {
        lock (gate)
        {
            AssertNoPreparation();
            foreach (var key in spaceQueries.Keys.Where(k => k.StartsWith(taskId + "|", StringComparison.Ordinal)).ToArray())
            {
                if (!spaceQueries[key].IsCompleted) throw new InvalidOperationException("TaskHasActiveWork");
                spaceQueries.Remove(key);
            }
            _ = rows.ReadHeader(taskId);
            if (analyses.Values.Any(w => w.TaskId == taskId && !w.Work.IsCompleted) || executions.Values.Any(w => w.TaskId == taskId && !w.Work.IsCompleted)) throw new InvalidOperationException("TaskHasActiveWork");
        }
    }
    internal void AssertReleasable(string taskId)
    {
        lock (gate)
        {
            AssertCanChangeInventory(taskId);
            foreach (var id in analyses.Where(p => p.Value.TaskId == taskId).Select(p => p.Key).ToArray())
            {
                analyses[id].Cancellation.Dispose(); analyses.Remove(id);
                foreach (var draft in draftAnalyses.Where(p => p.Value == id).Select(p => p.Key).ToArray()) draftAnalyses.Remove(draft);
            }
        }
    }
    private static void Page(int size) { if (size is < 1 or > 64) throw new InvalidOperationException("InvalidPage"); }
    private void Alive() { if (disposed) throw new ObjectDisposedException(nameof(ExplorerCoordinator)); }
    public void Dispose()
    {
        Task[] pending;
        lock (gate) { disposed = true; foreach (var w in preparations.Values) w.Cancellation.Cancel(); foreach (var w in analyses.Values) w.Cancellation.Cancel(); foreach (var w in executions.Values) w.Cancellation.Cancel(); pending = preparations.Values.Select(w => w.Work).Concat(analyses.Values.Select(w => w.Work)).Concat(executions.Values.Select(w => w.Work)).ToArray(); }
        try { Task.WaitAll(pending.Concat(spaceQueries.Values).ToArray()); } catch (AggregateException) { /* Persisted ledger, never retry. */ }
        sta.Dispose(); foreach (var w in preparations.Values) w.Cancellation.Dispose(); foreach (var w in analyses.Values) w.Cancellation.Dispose(); foreach (var w in executions.Values) w.Cancellation.Dispose();
    }
    private sealed class AnalysisWork(string taskId, long revision, string mode, TrustedTaskHeader header)
    {
        internal readonly string TaskId = taskId; internal readonly long Revision = revision; internal readonly string Mode = mode; internal readonly TrustedTaskHeader Header = header;
        internal AdaptedInventory? Snapshot;
        internal CancellationToken BuildToken;
        internal ProofHashSession? ProofHashes;
        internal BudgetUsage? FinalUsage;
        internal double SnapshotMilliseconds, AnalysisMilliseconds, DisplayMilliseconds, TotalMilliseconds;
        internal HashSet<string> ProofBlockedSuggestions = new(StringComparer.Ordinal);
        internal readonly CancellationTokenSource Cancellation = new(); internal Task Work = Task.CompletedTask; internal AnalysisResult? Result, PendingResult; internal string? Error, ErrorReason;
        internal HeuristicProgress Progress = new(0, 0, 0, null, "Queued", true);
        internal Dictionary<string, SuggestionSnapshot>? DisplaySource;
    }
    private sealed class InlineProgress<T>(Action<T> action) : IProgress<T> { public void Report(T value) => action(value); }
    private sealed class ExecutionWork(string taskId)
    {
        internal readonly string TaskId = taskId; internal readonly CancellationTokenSource Cancellation = new(); internal Task<ExecutionResult> Work = Task.FromResult(new ExecutionResult("", "NotStarted", [], 0));
    }
}
