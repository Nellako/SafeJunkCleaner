namespace SafeJunkCleaner.Explorer.Analysis;

// One budget covers index construction, all targets, metadata revalidation and content probes.
public sealed record HeuristicBudget(int MaxTargets = 128, int MaxActions = 384,
    int MaxMetadataObjects = 250000, int MaxReadFiles = 128, long MaxSampleBytes = 1048576,
    long MaxHashBytes = 268435456, int MaxHashFiles = 64, TimeSpan? MaxDuration = null,
    long LargeFileBytes = 104857600, bool UntilComplete = false);

public sealed record HeuristicProgress(int VisitedTargets, int QueuedTargets, int CompletedActions,
    string? CurrentTargetId, string Reason, bool HasMore);
