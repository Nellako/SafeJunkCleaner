using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SafeJunkCleaner.Explorer.Execution;

public enum ProcessingClass { VerifiedCache, ReviewSuggested, UserData, Photos, Backup, Mixed, System, Unknown }
public sealed record FileSnapshot(string ObjectId, string Path, string Identity, long Size, string ModifiedUtc, string? ContentSha256 = null);
public sealed record SuggestionSnapshot(string SuggestionId, ProcessingClass Classification, bool HardProtected,
    string Impact, string[] EvidenceIds, FileSnapshot[] Files, FileSnapshot[] RetainedCopies);
public sealed record ApprovalSource(string TaskId, string ScopeId, string ScopeRevision, string SuggestionRevision,
    string PolicyRevision, string OwnerSid, string[] Roots, SuggestionSnapshot[] Suggestions);
public interface IApprovalSource { ApprovalSource Read(string taskId); }
public interface IApprovalSourceReadScope { IDisposable BeginReadScope(); }
public sealed record AncestorSnapshot(string Path, string Identity);
public sealed record RetainedCopySnapshot(FileSnapshot File, AncestorSnapshot[] Ancestors);
public sealed record ApprovedItem(string SuggestionId, FileSnapshot File, AncestorSnapshot[] Ancestors, RetainedCopySnapshot[] RetainedCopies);
public sealed record ApprovalDraft(int SchemaVersion, string DraftId, string TaskId, string ScopeId, string ScopeRevision,
    string SuggestionRevision, string PolicyRevision, string OwnerSid, DateTimeOffset CreatedUtc, bool RecycleOnly,
    string[] SuggestionIds, string[] Roots, SuggestionSnapshot[] DisplayedSuggestions, ApprovedItem[] Items,
    long LogicalBytes, string CandidateSetHash, string DisplayHash);
public sealed record ApprovalSeal(int SchemaVersion, string ApprovalId, DateTimeOffset ConfirmedUtc, ApprovalDraft Draft);
public sealed record ExecutionEntry(string ObjectId, string Status, string Reason, long LogicalBytes);
public sealed record ExecutionResult(string ApprovalId, string Status, ExecutionEntry[] Entries, long RecycledLogicalBytes);
public sealed record CurrentFile(FileSnapshot Snapshot, bool IsDirectory, bool ReadOnly, uint Links, bool Unsafe, bool Occupied);
public interface IExecutionFacts
{
    string OwnerSid { get; }
    void ValidateLocalPath(string path);
    string? HardProtection(string path);
    AncestorSnapshot[] Ancestors(string path);
    CurrentFile Read(string path, bool verifyContent);
    IDisposable GuardAncestors(string path, AncestorSnapshot[] expected);
    IDisposable GuardRetainedCopy(FileSnapshot expected);
}
public sealed record RecycleResult(bool Recycled, string Reason);
public interface IRecycleOnly
{
    bool IsAvailable { get; }
    string UnavailableReason { get; }
    RecycleResult Recycle(FileSnapshot expected, CancellationToken cancellationToken);
}
public interface IApprovalStore
{
    void PutDraft(ApprovalDraft draft);
    ApprovalDraft ReadDraft(string id);
    void PutSeal(ApprovalSeal seal);
    ApprovalSeal ReadSeal(string id);
    IDisposable Claim(string approvalId);
    bool IsClaimed(string approvalId);
    void Append(string approvalId, ExecutionEntry entry);
    ExecutionEntry[] ReadLedger(string approvalId);
}
internal static class Wire
{
    internal static readonly JsonSerializerOptions Json = new() { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
    internal static string Hash<T>(T value) => Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(value, Json)));
    internal static T Clone<T>(T value) => JsonSerializer.Deserialize<T>(JsonSerializer.SerializeToUtf8Bytes(value, Json), Json)!;
    internal static void Id(string id) { if (!Guid.TryParseExact(id, "D", out _)) throw new InvalidOperationException("InvalidId"); }
    internal static void Require(bool ok, string reason) { if (!ok) throw new InvalidOperationException(reason); }
}

public sealed class ApprovalExecutor(IApprovalSource source, IExecutionFacts facts, IApprovalStore store, IRecycleOnly recycler)
{
    public ApprovalDraft PrepareApproval(string taskId, string[] suggestionIds, CancellationToken cancellationToken = default, Action<int, int>? progress = null)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var readScope = (source as IApprovalSourceReadScope)?.BeginReadScope();
        Wire.Id(taskId);
        Wire.Require(suggestionIds is { Length: > 0 and <= 10000 } && suggestionIds.Distinct(StringComparer.Ordinal).Count() == suggestionIds.Length, "InvalidSuggestionSet");
        foreach (var id in suggestionIds) Wire.Id(id);
        var current = Wire.Clone(source.Read(taskId));
        ValidateSource(current, taskId);
        var selected = suggestionIds.Order(StringComparer.Ordinal).Select(id => current.Suggestions.Single(s => s.SuggestionId == id)).ToArray();
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var identities = new HashSet<string>(StringComparer.Ordinal);
        var objectIds = new HashSet<string>(StringComparer.Ordinal);
        var items = new List<ApprovedItem>();
        int total = selected.Sum(g => g.Files.Length);
        progress?.Invoke(0, total);
        foreach (var group in selected)
        {
            Wire.Require(!group.HardProtected && group.Classification is ProcessingClass.VerifiedCache or ProcessingClass.ReviewSuggested, "HardProtectedSuggestion");
            Wire.Require(!string.IsNullOrWhiteSpace(group.Impact) && group.EvidenceIds.Length > 0 && group.Files.Length > 0, "MissingImpactOrEvidence");
            foreach (var file in group.Files)
            {
                cancellationToken.ThrowIfCancellationRequested();
                ValidateSnapshot(file, current.Roots);
                Wire.Require(paths.Add(file.Path) && identities.Add(file.Identity) && objectIds.Add(file.ObjectId), "OverlappingSet");
                var ancestors = facts.Ancestors(file.Path);
                Wire.Require(ancestors.Length > 0, "MissingAncestors");
                var item = new ApprovedItem(group.SuggestionId, file, ancestors, group.RetainedCopies.Select(k => new RetainedCopySnapshot(k, facts.Ancestors(k.Path))).ToArray());
                ValidateCurrent(item, current.Roots);
                items.Add(item);
                progress?.Invoke(items.Count, total);
            }
        }
        Wire.Require(items.Count is > 0 and <= 100000, "InvalidCandidateCount");
        foreach (var keeper in items.SelectMany(i => i.RetainedCopies))
            Wire.Require(!paths.Contains(keeper.File.Path) && !identities.Contains(keeper.File.Identity), "RetainedCopySelected");
        var sorted = items.OrderBy(i => i.File.ObjectId, StringComparer.Ordinal).ToArray();
        var draft = new ApprovalDraft(1, Guid.NewGuid().ToString("D"), current.TaskId, current.ScopeId, current.ScopeRevision,
            current.SuggestionRevision, current.PolicyRevision, facts.OwnerSid, DateTimeOffset.UtcNow, true,
            suggestionIds.Order(StringComparer.Ordinal).ToArray(), current.Roots, selected, sorted,
            checked(sorted.Sum(i => i.File.Size)), Wire.Hash(sorted), "");
        draft = draft with { DisplayHash = Wire.Hash(draft) };
        cancellationToken.ThrowIfCancellationRequested();
        store.PutDraft(draft);
        return Wire.Clone(draft);
    }

    public string ConfirmApproval(string draftId, string displayedHash)
    {
        using var readScope = (source as IApprovalSourceReadScope)?.BeginReadScope();
        Wire.Id(draftId);
        var draft = store.ReadDraft(draftId);
        ValidateDraft(draft);
        Wire.Require(draft.DraftId == draftId && draft.DisplayHash == displayedHash, "DisplayedSnapshotMismatch");
        ValidateRevision(draft);
        foreach (var item in draft.Items) ValidateCurrent(item, draft.Roots);
        // A draft confirmation itself is single use, including across process restarts.
        using var confirmation = store.Claim(draftId);
        var seal = new ApprovalSeal(1, Guid.NewGuid().ToString("D"), DateTimeOffset.UtcNow, draft);
        store.PutSeal(seal);
        return seal.ApprovalId;
    }

    public ExecutionResult ExecuteApproved(string approvalId, CancellationToken cancellationToken = default)
    {
        using var readScope = (source as IApprovalSourceReadScope)?.BeginReadScope();
        Wire.Id(approvalId);
        var seal = store.ReadSeal(approvalId);
        Wire.Require(seal.SchemaVersion == 1 && seal.ApprovalId == approvalId, "InvalidSeal");
        var draft = seal.Draft;
        ValidateDraft(draft);
        ValidateRevision(draft);
        // Validate the entire set before any effect. Claim persists even when validation/cancellation fails.
        using var evidenceReservation = store is IApprovalMaintenance maintenance ? maintenance.ReserveExecution(approvalId, draft.Items.Length) : null;
        using var claim = store.Claim(approvalId);
        try
        {
            foreach (var item in draft.Items) { cancellationToken.ThrowIfCancellationRequested(); ValidateCurrent(item, draft.Roots); }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            foreach (var item in draft.Items) store.Append(approvalId, new(item.File.ObjectId, "NotAttempted", ex is OperationCanceledException ? "Cancelled" : ex.GetType().Name + ":" + ex.Message, 0));
            return Result(approvalId, draft, ex is OperationCanceledException ? "Cancelled" : "Rejected");
        }
        foreach (var item in draft.Items)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                store.Append(approvalId, new(item.File.ObjectId, "NotAttempted", "Cancelled", 0));
                continue;
            }
            if (!recycler.IsAvailable)
            {
                store.Append(approvalId, new(item.File.ObjectId, "Skipped", recycler.UnavailableReason, 0));
                continue;
            }
            // Durable intent precedes any external side effect. Unknown outcomes are never replayed.
            store.Append(approvalId, new(item.File.ObjectId, "Attempting", "WriteAheadIntent", 0));
            try
            {
                using var guard = facts.GuardAncestors(item.File.Path, item.Ancestors);
                ValidateCurrent(item, draft.Roots);
                using var keepers = new GuardSet();
                foreach (var retained in item.RetainedCopies)
                {
                    keepers.Add(facts.GuardAncestors(retained.File.Path, retained.Ancestors));
                    keepers.Add(facts.GuardRetainedCopy(retained.File));
                }
                var outcome = recycler.Recycle(item.File, cancellationToken);
                store.Append(approvalId, new(item.File.ObjectId, outcome.Recycled ? "Recycled" : "Skipped", outcome.Reason, outcome.Recycled ? item.File.Size : 0));
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                store.Append(approvalId, new(item.File.ObjectId, "UnknownOrFailed", ex.GetType().Name + ":" + ex.Message, 0));
            }
        }
        return Result(approvalId, draft, cancellationToken.IsCancellationRequested ? "Cancelled" : null);
    }

    public ExecutionResult GetExecutionResult(string approvalId)
    {
        Wire.Id(approvalId); var seal = store.ReadSeal(approvalId);
        Wire.Require(seal.SchemaVersion == 1 && seal.ApprovalId == approvalId, "InvalidSeal");
        // Historical display authenticates the sealed record, never renews execution authority.
        ValidateDraft(seal.Draft, historical: true); return Result(approvalId, seal.Draft, null);
    }
    private ExecutionResult Result(string id, ApprovalDraft draft, string? status)
    {
        var entries = store.ReadLedger(id);
        var last = entries.GroupBy(e => e.ObjectId, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Last(), StringComparer.Ordinal);
        bool claimed = store.IsClaimed(id);
        // A successful prefix is not a completed approval. Authenticate the exact sealed
        // set and its logical sizes, including zero-byte files; never invent suffix rows.
        bool complete = claimed && last.Count == draft.Items.Length && draft.Items.All(item =>
            last.TryGetValue(item.File.ObjectId, out var entry) && entry.Status == "Recycled" && entry.LogicalBytes == item.File.Size);
        return new(id, status ?? (complete ? "Completed" : last.Count == 0 && !claimed ? "NotStarted" : "PartialOrInterrupted"),
            entries, last.Values.Where(e => e.Status == "Recycled").Sum(e => e.LogicalBytes));
    }
    private void ValidateSource(ApprovalSource value, string taskId)
    {
        Wire.Require(value.TaskId == taskId && value.OwnerSid == facts.OwnerSid, "TaskOwnerMismatch");
        Wire.Id(value.ScopeId);
        Wire.Require(!string.IsNullOrWhiteSpace(value.ScopeRevision) && !string.IsNullOrWhiteSpace(value.SuggestionRevision) && !string.IsNullOrWhiteSpace(value.PolicyRevision) && value.Roots.Length > 0, "InvalidRevisions");
        foreach (var root in value.Roots) facts.ValidateLocalPath(root);
    }
    private void ValidateRevision(ApprovalDraft draft)
    {
        var current = Wire.Clone(source.Read(draft.TaskId));
        ValidateSource(current, draft.TaskId);
        Wire.Require(current.ScopeId == draft.ScopeId && current.ScopeRevision == draft.ScopeRevision && current.SuggestionRevision == draft.SuggestionRevision && current.PolicyRevision == draft.PolicyRevision && Wire.Hash(current.Roots) == Wire.Hash(draft.Roots), "ApprovalRevisionChanged");
        var selected = draft.SuggestionIds.Select(id => current.Suggestions.Single(s => s.SuggestionId == id)).ToArray();
        Wire.Require(Wire.Hash(selected) == Wire.Hash(draft.DisplayedSuggestions), "SuggestionsChanged");
    }
    private void ValidateDraft(ApprovalDraft draft, bool historical = false)
    {
        Wire.Require(draft.SchemaVersion == 1 && draft.RecycleOnly && draft.OwnerSid == facts.OwnerSid, "InvalidDraftOwnerOrSchema");
        Wire.Id(draft.DraftId); Wire.Id(draft.TaskId); Wire.Id(draft.ScopeId);
        Wire.Require(draft.Items.Length is > 0 and <= 100000 && draft.SuggestionIds.Distinct().Count() == draft.SuggestionIds.Length, "InvalidDraftSet");
        Wire.Require(draft.DisplayHash == Wire.Hash(draft with { DisplayHash = "" }) && draft.CandidateSetHash == Wire.Hash(draft.Items) && draft.LogicalBytes == checked(draft.Items.Sum(i => i.File.Size)), "DraftHashMismatch");
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase); var ids = new HashSet<string>(); var objects = new HashSet<string>();
        foreach (var item in draft.Items)
        {
            ValidateSnapshot(item.File, draft.Roots, historical);
            Wire.Require(paths.Add(item.File.Path) && ids.Add(item.File.Identity) && objects.Add(item.File.ObjectId), "OverlappingSet");
            var suggestion = draft.DisplayedSuggestions.Single(s => s.SuggestionId == item.SuggestionId);
            Wire.Require(draft.SuggestionIds.Contains(item.SuggestionId) && !suggestion.HardProtected && suggestion.Classification is ProcessingClass.VerifiedCache or ProcessingClass.ReviewSuggested && suggestion.Files.Contains(item.File), "ProtectedOrUnboundItem");
            Wire.Require(Wire.Hash(item.RetainedCopies.Select(k => k.File).ToArray()) == Wire.Hash(suggestion.RetainedCopies), "UnboundRetainedCopies");
        }
        Wire.Require(Wire.Hash(draft.Items.Select(i => i.File.ObjectId).Order(StringComparer.Ordinal).ToArray()) == Wire.Hash(draft.DisplayedSuggestions.SelectMany(s => s.Files).Select(f => f.ObjectId).Order(StringComparer.Ordinal).ToArray()), "IncompleteDisplayedSet");
        foreach (var keeper in draft.Items.SelectMany(i => i.RetainedCopies)) Wire.Require(!paths.Contains(keeper.File.Path) && !ids.Contains(keeper.File.Identity), "RetainedCopySelected");
    }
    private void ValidateSnapshot(FileSnapshot file, string[] roots, bool historical = false)
    {
        Wire.Id(file.ObjectId);
        if (historical)
        {
            Wire.Require(WindowsFacts.Canonical(file.Path) == file.Path && roots.All(r => WindowsFacts.Canonical(r) == r), "InvalidHistoricalPath");
        }
        else facts.ValidateLocalPath(file.Path);
        Wire.Require(roots.Any(r => WindowsFacts.Within(file.Path, r)) && roots.All(r => !file.Path.Equals(r, StringComparison.OrdinalIgnoreCase)), "OutsideScopeOrRoot");
        if (!historical) Wire.Require(facts.HardProtection(file.Path) == null, "HardProtectedPath");
        Wire.Require(!string.IsNullOrWhiteSpace(file.Identity) && file.Size >= 0 && DateTimeOffset.TryParse(file.ModifiedUtc, out _), "InvalidFileSnapshot");
        Wire.Require(file.ContentSha256 == null || file.ContentSha256.Length == 64 && file.ContentSha256.All(Uri.IsHexDigit), "InvalidContentHash");
    }
    private void ValidateCurrent(ApprovedItem item, string[] roots)
    {
        ValidateSnapshot(item.File, roots);
        using var guard = facts.GuardAncestors(item.File.Path, item.Ancestors);
        Match(item.File, facts.Read(item.File.Path, item.File.ContentSha256 != null));
        foreach (var retained in item.RetainedCopies)
        {
            var keeper = retained.File;
            ValidateSnapshot(keeper, roots);
            Wire.Require(item.File.ContentSha256 != null && keeper.ContentSha256 == item.File.ContentSha256 && keeper.Identity != item.File.Identity, "UnverifiedDuplicate");
            using var keeperGuard = facts.GuardAncestors(keeper.Path, retained.Ancestors);
            Match(keeper, facts.Read(keeper.Path, true), retainedCopy: true);
        }
    }
    private sealed class GuardSet : IDisposable
    {
        private readonly List<IDisposable> guards = [];
        public void Add(IDisposable guard) => guards.Add(guard);
        public void Dispose() { for (var n = guards.Count - 1; n >= 0; n--) guards[n].Dispose(); }
    }
    private static void Match(FileSnapshot expected, CurrentFile current, bool retainedCopy = false)
    {
        Wire.Require(!current.IsDirectory && (retainedCopy || !current.ReadOnly) && current.Links == 1 && !current.Unsafe && !current.Occupied, "UnsafeOrOccupiedFile");
        Wire.Require(current.Snapshot.Identity == expected.Identity && current.Snapshot.Size == expected.Size && current.Snapshot.ModifiedUtc == expected.ModifiedUtc && (expected.ContentSha256 == null || current.Snapshot.ContentSha256 == expected.ContentSha256), "FileChanged");
    }
}
