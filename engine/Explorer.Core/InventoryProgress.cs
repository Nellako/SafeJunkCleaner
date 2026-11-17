namespace SafeJunkCleaner.Explorer;

public sealed partial class InventoryEngine
{
    // Display-only metadata. Never consulted by analysis, quota, identity or authorization checks.
    // The gate protects both this single active-generation map and the one-entry frozen cache.
    private ProgressAccumulator? progress;
    private long progressGeneration;
    private long progressFullQueries;
    private (string Task, long Revision, Dictionary<string, object?> Coverage)? progressSnapshot;

    private readonly record struct ProgressIdentity(string? Value);
    private sealed class IdentityBytes
    {
        public long? Logical;
        public long? Allocated;
    }
    private sealed class ProgressAccumulator(string task, long generation, long revision)
    {
        internal readonly string Task = task;
        internal readonly long Generation = generation;
        internal long Revision = revision;
        private readonly Dictionary<ProgressIdentity, IdentityBytes> identities = [];
        private long objects, pending, skipped, unknown, logicalGroups, allocatedGroups;
        private decimal logicalBytes, allocatedBytes;

        internal void Add(string kind, string? identity, long? logical, long? allocated, string scan, string coverage)
        {
            objects++;
            if (scan == "Pending") pending++;
            if (coverage == "NotCovered") skipped++;
            if (kind != "File") return;
            if (allocated == null) unknown++;
            if (logical == null && allocated == null) return;
            var key = new ProgressIdentity(identity); // SQL GROUP BY treats all NULL identities as one group.
            if (!identities.TryGetValue(key, out var bytes)) identities.Add(key, bytes = new());
            AddMaximum(ref bytes.Logical, logical, ref logicalBytes, ref logicalGroups);
            AddMaximum(ref bytes.Allocated, allocated, ref allocatedBytes, ref allocatedGroups);
        }
        private static void AddMaximum(ref long? maximum, long? value, ref decimal sum, ref long groups)
        {
            if (value == null || maximum != null && value <= maximum) return;
            if (maximum == null) groups++;
            sum += (decimal)value.Value - (maximum ?? 0);
            maximum = value;
        }
        internal void EndDirectory(bool failed)
        {
            pending--;
            if (failed) skipped++;
        }
        internal Dictionary<string, object?> Snapshot() => new()
        {
            ["ObservedObjects"] = objects,
            ["PendingDirectories"] = objects == 0 ? null : pending,
            ["SkippedObjects"] = objects == 0 ? null : skipped,
            ["ObservedLogicalBytes"] = logicalGroups == 0 ? null : checked((long)logicalBytes),
            ["ObservedAllocatedBytes"] = allocatedGroups == 0 ? null : checked((long)allocatedBytes),
            ["UnknownAllocationObjects"] = objects == 0 ? null : unknown
        };
    }
    private void ResetProgressGeneration()
    {
        progressGeneration++;
        progress = null;
        progressSnapshot = null;
    }
    private void InvalidateProgress(string task)
    {
        if (progress?.Task == task) progress = null;
        if (progressSnapshot?.Task == task) progressSnapshot = null;
    }
    private Dictionary<string, object?> ReadProgressCoverage(string task, string status, long revision)
    {
        if (status == "Inventory" && active == task)
        {
            if (progress == null || progress.Task != task || progress.Generation != progressGeneration || progress.Revision != revision)
            {
                var next = new ProgressAccumulator(task, progressGeneration, revision);
                using var command = Command("SELECT kind,identity,logical,allocated,scan,coverage FROM objects WHERE task=@p0", task);
                using var reader = command.ExecuteReader();
                while (reader.Read())
                    next.Add(reader.GetString(0), reader.IsDBNull(1) ? null : reader.GetString(1),
                        reader.IsDBNull(2) ? null : reader.GetInt64(2), reader.IsDBNull(3) ? null : reader.GetInt64(3),
                        reader.GetString(4), reader.GetString(5));
                progressFullQueries++;
                progress = next;
            }
            return progress.Snapshot();
        }
        if (progress?.Task == task) progress = null;
        if (progressSnapshot is { } cached && cached.Task == task && cached.Revision == revision) return cached.Coverage;
        var coverage = Rows("SELECT COUNT(*) AS ObservedObjects,SUM(CASE WHEN scan='Pending' THEN 1 ELSE 0 END) AS PendingDirectories,SUM(CASE WHEN coverage='NotCovered' THEN 1 ELSE 0 END) AS SkippedObjects,(SELECT SUM(logical) FROM (SELECT MAX(logical) AS logical FROM objects WHERE task=@p0 AND kind='File' AND logical IS NOT NULL GROUP BY identity)) AS ObservedLogicalBytes,(SELECT SUM(allocated) FROM (SELECT MAX(allocated) AS allocated FROM objects WHERE task=@p0 AND kind='File' AND allocated IS NOT NULL GROUP BY identity)) AS ObservedAllocatedBytes,SUM(CASE WHEN kind='File' AND allocated IS NULL THEN 1 ELSE 0 END) AS UnknownAllocationObjects FROM objects WHERE task=@p0", task)[0];
        progressFullQueries++;
        progressSnapshot = (task, revision, coverage);
        return coverage;
    }
    private void AddCommittedProgress(string task, long revision, List<ScanObservation> inserted, bool terminal, bool failed)
    {
        if (progress == null || progress.Task != task || progress.Generation != progressGeneration) return;
        if (progress.Revision != revision - 1) { progress = null; return; }
        foreach (var row in inserted)
            progress.Add(row.Kind, row.Fact?.Identity,
                row.Kind == "File" && row.Reason == null ? row.Fact?.LogicalBytes : null,
                row.Kind == "File" && row.Reason == null ? row.Fact?.AllocatedBytes : null,
                row.Kind == "Directory" ? row.Reason == null ? "Pending" : "Failed" : "Done",
                row.Reason != null ? "NotCovered" : row.Kind == "Directory" ? "Pending" : "Complete");
        if (terminal) progress.EndDirectory(failed);
        progress.Revision = revision;
    }
}
