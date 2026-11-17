namespace SafeJunkCleaner.Explorer;

public sealed record InventoryScanMetrics(long DirectorySelections, long PrioritySelections, long FairSelections,
    long QueueQueries, long CommittedBatches, long CommittedObjects, double MetadataMilliseconds, double CommitMilliseconds, double ElapsedMilliseconds);
internal sealed record PendingDirectory(long Id, string Path, string Identity);
internal sealed class InventoryScanQueue(bool prioritize)
{
    private readonly Queue<PendingDirectory> fair = new();
    private readonly PriorityQueue<PendingDirectory, (int, long)> preferred = new();
    private readonly HashSet<long> pending = [];
    private long selections;
    internal void Add(PendingDirectory directory)
    {
        if (!pending.Add(directory.Id)) return;
        fair.Enqueue(directory);
        string name = System.IO.Path.GetFileName(directory.Path).ToLowerInvariant();
        int score = name is "bin" or "obj" or "dist" or "cache_data" ? 2 : name is "cache" or "code cache" or "gpucache" ? 1 : 0;
        if (prioritize && score > 0) preferred.Enqueue(directory, (-score, directory.Id));
    }
    internal (PendingDirectory? Directory, bool Preferred) Take()
    {
        PendingDirectory? selected = null; bool usedPriority = false;
        if (selections % 4 != 3)
            while (preferred.TryDequeue(out var item, out _)) if (pending.Remove(item.Id)) { selected = item; usedPriority = true; break; }
        if (selected == null)
            while (fair.TryDequeue(out var item)) if (pending.Remove(item.Id)) { selected = item; break; }
        if (selected != null) selections++;
        return (selected, usedPriority);
    }
}

public sealed partial class InventoryEngine
{
    private readonly Dictionary<string, InventoryScanMetrics> scanMetrics = new(StringComparer.Ordinal);
    private InventoryScanMetrics? ReadScanMetrics(string task) => scanMetrics.GetValueOrDefault(task);
}
