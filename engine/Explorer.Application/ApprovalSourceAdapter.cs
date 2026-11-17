using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using SafeJunkCleaner.Explorer.Analysis;
using SafeJunkCleaner.Explorer.Execution;

namespace SafeJunkCleaner.Explorer.Application;

public sealed class ApprovalSourceAdapter(ITrustedInventoryRows inventory, ITrustedAnalysisSnapshots analysis, IExecutionFacts facts,
    Func<FileSnapshot, FileSnapshot?>? trustedBuildArtifactDllBinder = null) : IApprovalSource, IApprovalSourceReadScope
{
    private readonly AsyncLocal<ReadScope?> readScope = new();
    public IDisposable BeginReadScope()
    {
        if (readScope.Value != null) throw new InvalidOperationException("ApprovalReadScopeAlreadyActive");
        var scope = new ReadScope(() => readScope.Value = null); readScope.Value = scope; return scope;
    }
    private sealed class ReadScope(Action release) : IDisposable
    {
        internal ApprovalSource? Source; internal TrustedTaskHeader? Header;
        public void Dispose() { Source = null; Header = null; release(); }
    }
    public ApprovalSource Read(string taskId)
    {
        var cancellationToken = (analysis as ITrustedAnalysisBuildContext)?.BuildCancellationToken ?? CancellationToken.None;
        cancellationToken.ThrowIfCancellationRequested();
        var header = inventory.ReadHeader(taskId);
        if (readScope.Value is { Source: { } held, Header: { } heldHeader })
        {
            // Operation-local immutable canonical mapping only. Per-file execution facts,
            // marker hashes, ancestors and content checks still run freshly in the caller.
            // Host forbids inventory/analysis changes while preparing; the header is also
            // checked here on every read. Nothing survives this one Prepare operation.
            if (header != heldHeader || held.TaskId != taskId) throw new InvalidOperationException("SourceChangedDuringApprovalRead");
            return held;
        }
        var adapted = analysis is ITrustedInventorySnapshots snapshots ? snapshots.ReadInventory(taskId, header.Revision)
            : new InventorySnapshotAdapter(inventory, facts.OwnerSid).Load(taskId, header.Revision);
        if (adapted.Header != header || adapted.Header.OwnerSid != facts.OwnerSid) throw new InvalidOperationException("UnownedOrUnstableInventory");
        var result = AnalysisCandidateSet.Normalize(Copy(analysis.Read(taskId, header.Revision)), adapted.Evidence);
        if (result.TaskId != taskId || result.Revision != header.Revision
            || result.Suggestions.Select(s => s.SuggestionId).Distinct(StringComparer.Ordinal).Count() != result.Suggestions.Count
            || result.Evidence.Select(e => e.EvidenceId).Distinct(StringComparer.Ordinal).Count() != result.Evidence.Count) throw new InvalidOperationException("InvalidAnalysisSnapshot");
        if (result.Suggestions.Sum(s => (long)s.CandidateFiles.Count + (s.Duplicate?.RetainedFiles.Count ?? 0)) > InventorySnapshotAdapter.MaximumObjects)
            throw new InvalidOperationException("CandidateReferenceLimitExceeded");
        var targets = adapted.Evidence.Targets;
        var safeTargets = AnalysisCandidateSet.GetUsableTargets(adapted.Evidence);
        if (result.Evidence.Any(e => !targets.ContainsKey(e.TargetId))) throw new InvalidOperationException("EvidenceTargetNotInInventory");
        var evidence = result.Evidence.ToDictionary(e => e.EvidenceId, StringComparer.Ordinal);
        var suggestions = new List<SuggestionSnapshot>();
        foreach (var suggestion in result.Suggestions.OrderBy(s => s.SuggestionId, StringComparer.Ordinal))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (string.IsNullOrWhiteSpace(suggestion.SuggestionId) || !targets.TryGetValue(suggestion.TargetId, out var target)
                || suggestion.EvidenceIds.Any(id => !evidence.ContainsKey(id)) || suggestion.CandidateFiles.Count > InventorySnapshotAdapter.MaximumObjects)
                throw new InvalidOperationException("UnboundSuggestionEvidence");
            bool complete = safeTargets.Contains(target.ObjectId);
            bool eligible = suggestion.MayPrepareForReview && complete && suggestion.Classification is Classification.Cache or Classification.BuildArtifact;
            // Current installer duplicates remain organize-only even if an injected result claims keeper confirmation.
            // Host must add a separately reviewed provenance/keeper workflow before promoting that category.
            var duplicate = suggestion.Duplicate;
            var files = suggestion.CandidateFiles.Select(f => MapFile(f, adapted.Evidence, duplicate?.ContentSha256)).ToArray();
            var keepers = duplicate?.RetainedFiles.Select(f => MapFile(f, adapted.Evidence, duplicate.ContentSha256)).ToArray() ?? [];
            if (files.Select(f => f.ObjectId).Distinct().Count() != files.Length || files.Select(f => f.Identity).Distinct().Count() != files.Length
                || keepers.Any(k => files.Any(f => f.ObjectId == k.ObjectId || f.Identity == k.Identity))) throw new InvalidOperationException("OverlappingCandidateOrKeeperSet");
            if (duplicate != null && (keepers.Length == 0 || duplicate.ContentSha256.Length != 64 || !duplicate.ContentSha256.All(Uri.IsHexDigit))) throw new InvalidOperationException("MissingDuplicateProof");
            if (suggestion.CandidateFiles.Any(c => !safeTargets.Contains(c.ObjectId) || targets[c.ObjectId].LinkCount != 1 || (targets[c.ObjectId].Attributes & 1) != 0)) eligible = false;
            if (suggestion.CandidateFiles.Any(c => !WindowsFacts.Within(targets[c.ObjectId].Path, target.Path))) throw new InvalidOperationException("CandidateOutsideSuggestionTarget");
            bool DllException(FileSnapshot file) => eligible && suggestion.Classification == Classification.BuildArtifact && Path.GetExtension(file.Path).Equals(".dll", StringComparison.OrdinalIgnoreCase) && facts.HardProtection(file.Path) == "ProtectedDocumentPhotoBackupOrProgram";
            if (files.Any(f => facts.HardProtection(f.Path) != null && !DllException(f))) eligible = false;
            if (eligible && files.Any(DllException))
            {
                for (int i = 0; i < files.Length; i++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (!DllException(files[i])) continue;
                    var bound = trustedBuildArtifactDllBinder?.Invoke(files[i]);
                    if (bound == null || bound with { ContentSha256 = files[i].ContentSha256 } != files[i] || bound.ContentSha256 is not { Length: 64 }) { eligible = false; break; }
                    files[i] = bound;
                }
            }
            suggestions.Add(new(StableIds.Create(taskId, header.Revision, "suggestion", suggestion.SuggestionId),
                eligible ? ProcessingClass.ReviewSuggested : MapProtectedClass(suggestion.Classification), !eligible || suggestion.HardProtected,
                suggestion.Impact, suggestion.EvidenceIds.Select(id => StableIds.Create(taskId, header.Revision, "evidence", id)).ToArray(), files, keepers));
        }
        // Recheck both live providers after mapping. Neither source may silently change during expansion.
        if (inventory.ReadHeader(taskId) != header || Hash(AnalysisCandidateSet.Normalize(Copy(analysis.Read(taskId, header.Revision)), adapted.Evidence)) != Hash(result)) throw new InvalidOperationException("SourceChangedDuringApprovalRead");
        cancellationToken.ThrowIfCancellationRequested();
        facts.ValidateLocalPath(header.RootPath);
        var mapped = new ApprovalSource(taskId, header.ScopeId, header.ScopeRevision, header.Revision.ToString(CultureInfo.InvariantCulture) + ":" + Hash(result), header.PolicyRevision,
            header.OwnerSid, [header.RootPath], suggestions.ToArray());
        if (readScope.Value is { } scope) { scope.Header = header; scope.Source = mapped; }
        return mapped;
    }
    private FileSnapshot MapFile(CandidateFile candidate, InventoryEvidenceSnapshot snapshot, string? duplicateHash)
    {
        if (!snapshot.Targets.TryGetValue(candidate.ObjectId, out var target) || target.Kind != TargetKind.File || target.LogicalBytes == null
            || candidate.FileIdentity != target.FileIdentity || candidate.LogicalBytes != target.LogicalBytes || candidate.ModifiedUtcTicks != target.ModifiedUtcTicks)
            throw new InvalidOperationException("CandidateDoesNotMatchInventory");
        string? hash = candidate.ContentSha256;
        if (hash != null && (hash.Length != 64 || !hash.All(Uri.IsHexDigit))) throw new InvalidOperationException("InvalidCandidateHash");
        if (duplicateHash != null && (hash == null || !hash.Equals(duplicateHash, StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("DuplicateHashNotBoundToCopy");
        return new(StableIds.Create(snapshot.TaskId, snapshot.Revision, "object", candidate.ObjectId), target.Path, target.FileIdentity,
            target.LogicalBytes.Value, new DateTime(target.ModifiedUtcTicks, DateTimeKind.Utc).ToString("O"), hash?.ToUpperInvariant());
    }
    private static ProcessingClass MapProtectedClass(Classification classification) => classification switch
    {
        Classification.UserData => ProcessingClass.UserData,
        Classification.Mixed => ProcessingClass.Mixed,
        _ => ProcessingClass.Unknown
    };
    private static AnalysisResult Copy(AnalysisResult value) => JsonSerializer.Deserialize<AnalysisResult>(JsonSerializer.SerializeToUtf8Bytes(value)) ?? throw new InvalidOperationException("InvalidAnalysis");
    private static string Hash(AnalysisResult value) => Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(value)));
}
