using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SafeJunkCleaner.Explorer.Analysis;

namespace SafeJunkCleaner.Explorer.Application;

public static class StableIds
{
    private static readonly Guid Namespace = new("cc2d2fd2-3b1f-45f4-9d6f-e6f4c448e6ab");
    // RFC 9562 UUIDv5; length-delimited JSON prevents ambiguous concatenation of untrusted IDs.
    public static string Create(string taskId, long revision, string kind, string sourceId)
    {
        if (!Guid.TryParseExact(taskId, "D", out var task) || revision < 1 || string.IsNullOrWhiteSpace(kind) || string.IsNullOrWhiteSpace(sourceId)) throw new ArgumentException("InvalidStableIdentity");
        var name = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[] { task.ToString("D"), revision.ToString(CultureInfo.InvariantCulture), kind, sourceId }));
        byte[] input = new byte[16 + name.Length]; Namespace.TryWriteBytes(input, bigEndian: true, out _); name.CopyTo(input, 16);
        var hash = SHA1.HashData(input); hash[6] = (byte)((hash[6] & 15) | 0x50); hash[8] = (byte)((hash[8] & 63) | 0x80);
        return new Guid(hash.AsSpan(0, 16), bigEndian: true).ToString("D");
    }
}

// Host-only providers read an owned local task index, never JSON supplied by UI/model.
public sealed record TrustedTaskHeader(string TaskId, long Revision, string ScopeId, string ScopeRevision,
    string PolicyRevision, string OwnerSid, string RootObjectId, string RootPath, string RootIdentity, string State);
public sealed record InventoryRow(string ObjectId, string? ParentId, string Path, string Kind, string? FileIdentity,
    long? LogicalBytes, string? ModifiedUtc, uint? Attributes, uint? LinkCount, string Coverage, string? SkippedReason, bool HardProtected = false, bool? DirectoryEnumerationComplete = null);
public sealed record InventoryPage(IReadOnlyList<InventoryRow> Rows, string? NextCursor);
public interface ITrustedInventoryRows
{
    TrustedTaskHeader ReadHeader(string taskId);
    InventoryPage ReadPage(string taskId, long revision, string? after, int size);
}
public interface ITrustedSelectedInventoryRows : ITrustedInventoryRows
{
    InventoryPage ReadSelectedPage(string taskId, long revision, string targetId, string? after, int size);
}
public interface ITrustedSnapshotResources { void ReleaseDisplayCaches(string taskId); }
public interface ITrustedAnalysisSnapshots { AnalysisResult Read(string taskId, long revision); }
public interface ITrustedInventorySnapshots { AdaptedInventory ReadInventory(string taskId, long revision); }
public interface ITrustedAnalysisBuildContext { CancellationToken BuildCancellationToken { get; } }
public sealed record InventoryCoverageRow(string ObjectId, string? ParentId, string Path, string Coverage, string? Reason, bool Analyzable);
public sealed record AdaptedInventory(TrustedTaskHeader Header, InventoryEvidenceSnapshot Evidence, IReadOnlyList<InventoryCoverageRow> Coverage);

public sealed class InventorySnapshotAdapter(ITrustedInventoryRows rows, string expectedOwnerSid)
{
    // Container/wire arithmetic bound only, not a production scan quota.
    public const int MaximumObjects = int.MaxValue;
    public AdaptedInventory Load(string taskId, long revision, CancellationToken cancellationToken = default, string? targetId = null)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var header = rows.ReadHeader(taskId); ValidateHeader(header, taskId, revision);
        (rows as ITrustedSnapshotResources)?.ReleaseDisplayCaches(taskId);
        var resources = AnalysisResources.Capture();
        var all = new Dictionary<string, InventoryRow>(StringComparer.Ordinal); var cursors = new HashSet<string>(StringComparer.Ordinal);
        string? cursor = null;
        do
        {
            cancellationToken.ThrowIfCancellationRequested();
            var page = targetId != null && rows is ITrustedSelectedInventoryRows selected
                ? selected.ReadSelectedPage(taskId, revision, targetId, cursor, 64)
                : rows.ReadPage(taskId, revision, cursor, 64);
            cancellationToken.ThrowIfCancellationRequested();
            if (page.Rows.Count > 64 || page.Rows.Count == 0 && page.NextCursor != null) throw new InvalidOperationException("InvalidInventoryPage");
            foreach (var row in page.Rows)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if ((all.Count & 1023) == 0 && resources.Exceeded) throw new InvalidOperationException("AnalysisMemoryPressure");
                if (string.IsNullOrWhiteSpace(row.ObjectId) || row.ObjectId.Length > 80 || row.Coverage is not ("Complete" or "Partial" or "NotCovered" or "Pending")) throw new InvalidOperationException("InvalidInventoryRow");
                if (all.Count >= MaximumObjects || !all.TryAdd(row.ObjectId, row)) throw new InvalidOperationException("InventoryLimitOrDuplicateObject");
                bool canonical;
                try { canonical = WindowsFacts.Canonical(row.Path) == row.Path; }
                catch (InvalidOperationException ex) when (ex.Message is "NonCanonicalPath" or "UnsupportedPath")
                {
                    // Inventory deliberately stores metadata failures as opaque coverage gaps.
                    // Never normalize or open them. Ordinary files/roots must still pass Canonical.
                    bool opaqueGap = row.ObjectId != header.RootObjectId && row.Kind == "Unknown"
                        && row.Coverage == "NotCovered" && row.SkippedReason == "MetadataUnavailable:InvalidOperationException"
                        && row.FileIdentity == null && row.LogicalBytes == null && row.ModifiedUtc == null
                        && row.Attributes == null && row.LinkCount == null && row.DirectoryEnumerationComplete == null;
                    if (!opaqueGap) throw;
                    canonical = true; // Coverage-only raw path; HasFacts below excludes it from analysis.
                }
                if (!canonical || !WindowsFacts.Within(row.Path, header.RootPath)) throw new InvalidOperationException("InventoryOutsideScope");
            }
            cursor = page.NextCursor;
            if (cursor != null && !cursors.Add(cursor)) throw new InvalidOperationException("RepeatedInventoryCursor");
        } while (cursor != null);
        if (rows.ReadHeader(taskId) != header) throw new InvalidOperationException("InventoryRevisionChangedDuringExport");
        if (!all.TryGetValue(header.RootObjectId, out var root) || root.ParentId != null || root.Kind != "Directory" || root.Path != header.RootPath || root.FileIdentity != header.RootIdentity) throw new InvalidOperationException("InventoryRootMismatch");
        if (all.Values.Select(r => r.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() != all.Count) throw new InvalidOperationException("DuplicateInventoryPath");
        foreach (var row in all.Values.Where(r => r.ObjectId != header.RootObjectId))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (row.ParentId == null || !all.TryGetValue(row.ParentId, out var parent) || parent.Kind != "Directory" || !string.Equals(Path.GetDirectoryName(row.Path), parent.Path, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("InvalidInventoryParent");
        }
        bool HasFacts(InventoryRow r) => r.SkippedReason == null && r.Kind is "Directory" or "File" && !string.IsNullOrWhiteSpace(r.FileIdentity)
            && r.Attributes != null && r.LinkCount != null && DateTimeOffset.TryParse(r.ModifiedUtc, out _) && (r.Kind != "File" || r.LogicalBytes is >= 0);
        var ordered = all.Values.OrderBy(r => r.Path.Length).ToArray();
        var included = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in ordered)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (HasFacts(row) && (row.ParentId == null || included.Contains(row.ParentId))) included.Add(row.ObjectId);
        }
        if (!included.Contains(header.RootObjectId)) throw new InvalidOperationException("InventoryRootUnavailable");
        var incomplete = new HashSet<string>(StringComparer.Ordinal);
        if (targetId != null)
        {
            if (!all.TryGetValue(targetId, out var selectedTarget)) throw new InvalidOperationException("TargetNotInInventory");
            // Ancestors carry identity/protection context, not a claim that their omitted siblings were exported.
            for (var parentId = selectedTarget.ParentId; parentId != null; parentId = all[parentId].ParentId)
                incomplete.Add(parentId);
            foreach (var row in all.Values)
                if (!WindowsFacts.Within(row.Path, selectedTarget.Path) && row.Kind == "Directory") incomplete.Add(row.ObjectId);
        }
        // Children precede parents. Propagate each gap once rather than walking
        // every ancestor for every object in a deep or wide inventory.
        foreach (var row in ordered.Reverse())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!included.Contains(row.ObjectId) || row.Coverage != "Complete") incomplete.Add(row.ObjectId);
            if (incomplete.Contains(row.ObjectId) && row.ParentId != null) incomplete.Add(row.ParentId);
        }
        var targets = all.Values.Where(r => included.Contains(r.ObjectId)).Select(r => new InventoryTarget(r.ObjectId, r.ParentId, r.Path,
            r.Kind == "Directory" ? TargetKind.Directory : TargetKind.File, r.FileIdentity!, r.Kind == "File" ? r.LogicalBytes : null,
            DateTimeOffset.Parse(r.ModifiedUtc!, CultureInfo.InvariantCulture).UtcTicks, r.Attributes!.Value, r.LinkCount!.Value,
            incomplete.Contains(r.ObjectId) ? Coverage.Partial : Coverage.Complete, r.HardProtected, r.DirectoryEnumerationComplete)).ToArray();
        cancellationToken.ThrowIfCancellationRequested();
        var evidence = new InventoryEvidenceSnapshot(taskId, revision, header.RootObjectId, targets);
        cancellationToken.ThrowIfCancellationRequested();
        if (rows.ReadHeader(taskId) != header) throw new InvalidOperationException("InventoryRevisionChangedDuringExport");
        return new(header, evidence, Array.AsReadOnly(all.Values.Select(r => new InventoryCoverageRow(r.ObjectId, r.ParentId, r.Path, r.Coverage, r.SkippedReason,
            included.Contains(r.ObjectId))).ToArray()));
    }
    private void ValidateHeader(TrustedTaskHeader header, string taskId, long revision)
    {
        if (!Guid.TryParseExact(taskId, "D", out _) || !Guid.TryParseExact(header.ScopeId, "D", out _) || revision < 1 || header.TaskId != taskId || header.Revision != revision
            || header.OwnerSid != expectedOwnerSid || string.IsNullOrWhiteSpace(expectedOwnerSid) || string.IsNullOrWhiteSpace(header.ScopeRevision) || string.IsNullOrWhiteSpace(header.PolicyRevision)
            || header.State is not ("Ready" or "Partial") || WindowsFacts.Canonical(header.RootPath) != header.RootPath) throw new InvalidOperationException("UnownedOrUnstableInventory");
    }
}
