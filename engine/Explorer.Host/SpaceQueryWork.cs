namespace SafeJunkCleaner.Explorer.Host;

internal sealed partial class ExplorerCoordinator
{
    private readonly Dictionary<string, Task<SpacePage>> spaceQueries = new(StringComparer.Ordinal);
    internal object QuerySpaceAsync(string taskId, string? cursor, int size, Func<SpacePage> query)
    {
        lock (gate)
        {
            Alive(); Page(size);
            string key = taskId + "|" + (cursor ?? "") + "|" + size;
            if (!spaceQueries.TryGetValue(key, out var work))
            {
                foreach (var old in spaceQueries.Where(p => p.Value.IsCompleted).Select(p => p.Key).ToArray()) spaceQueries.Remove(old);
                if (spaceQueries.Count >= 8) throw new InvalidOperationException("SpaceQueryBusy");
                // Capture the trusted task at admission only. Polls must not wait for the
                // engine's aggregation gate, which is the very work being observed.
                _ = rows.ReadHeader(taskId);
                work = Task.Run(query); spaceQueries.Add(key, work);
            }
            return new { Status = !work.IsCompleted ? "Running" : work.IsCompletedSuccessfully ? "Ready" : "Failed",
                Page = work.IsCompletedSuccessfully ? work.Result : null,
                ErrorCode = work.IsFaulted ? "SpaceQueryFailed:" + work.Exception!.GetBaseException().GetType().Name : null };
        }
    }
}
