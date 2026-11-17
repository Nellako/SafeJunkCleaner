using System.Collections.ObjectModel;

namespace SafeJunkCleaner.Explorer.Analysis;

public enum TargetKind { Directory, File }
public enum Coverage { Complete, Partial, NotCovered }
public enum ExplorationAction { InspectLayout, InspectOwnership, InspectDuplicates, AskUser, Stop }
public enum EvidenceKind { Layout, Ownership, Protection, Duplicate, Space, Missing, Question }
public enum Classification { Unknown, Cache, BuildArtifact, InstallerDuplicate, UserData, Mixed, Portable, SpaceOnly }
public enum SuggestionLevel { Undetermined, ReviewSuggested, OrganizeOpportunity }
public enum AnalysisStatus { Complete, ModelUnavailable, BudgetExhausted, NoProgress, AskedUser, Cancelled, InvalidDecision }

// Constructed only by a trusted Inventory adapter, never by model output.
public sealed record InventoryTarget(string ObjectId, string? ParentId, string Path, TargetKind Kind,
    string FileIdentity, long? LogicalBytes, long ModifiedUtcTicks, uint Attributes, uint LinkCount,
    Coverage Coverage, bool HardProtected = false, bool? DirectoryEnumerationComplete = null);

public sealed class InventoryEvidenceSnapshot
{
    public string TaskId { get; }
    public long Revision { get; }
    public string RootId { get; }
    public IReadOnlyDictionary<string, InventoryTarget> Targets { get; }
    public InventoryEvidenceSnapshot(string taskId, long revision, string rootId, IEnumerable<InventoryTarget> authorizedInventoryTargets)
    {
        if (!Guid.TryParseExact(taskId, "D", out _) || revision < 1) throw new ArgumentException("Invalid inventory identity");
        var targets = authorizedInventoryTargets.ToDictionary(t => t.ObjectId, StringComparer.Ordinal);
        if (targets.Count < 1 || !targets.TryGetValue(rootId, out var root) || root.Kind != TargetKind.Directory || root.ParentId != null) throw new ArgumentException("Invalid inventory root");
        foreach (var t in targets.Values)
        {
            if (t.ObjectId.Length is < 1 or > 80 || !t.ObjectId.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_') || string.IsNullOrEmpty(t.FileIdentity) || t.Path != MetadataAccess.Canonical(t.Path)) throw new ArgumentException("Invalid inventory object");
            if (t.ObjectId != rootId && (t.ParentId == null || !targets.TryGetValue(t.ParentId, out var parent) || parent.Kind != TargetKind.Directory || !string.Equals(System.IO.Path.GetDirectoryName(t.Path), parent.Path, StringComparison.OrdinalIgnoreCase))) throw new ArgumentException("Invalid inventory parent");
            if (!MetadataAccess.Within(t.Path, root.Path)) throw new ArgumentException("Inventory target outside scope");
        }
        if (targets.Values.Select(t => t.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() != targets.Count) throw new ArgumentException("Duplicate inventory paths");
        TaskId = taskId; Revision = revision; RootId = rootId; Targets = new ReadOnlyDictionary<string, InventoryTarget>(targets);
    }
}

public sealed record AnalysisEvidence(string EvidenceId, string TargetId, EvidenceKind Kind, string Value, string DetectorVersion = "bounded-v1");
public sealed record StateEvidence(string EvidenceId, EvidenceKind Kind, string Value);
// Deliberately no path, filename, command, URL or file content in the decision state.
public sealed record ExecutedProbe(string TargetId, ExplorationAction Action);
public sealed record AnalysisState(string TaskId, long Revision, string TargetId, IReadOnlyList<StateEvidence> Evidence,
    IReadOnlyList<string> ExistingTargetIds, IReadOnlyList<ExplorationAction> AllowedActions, IReadOnlyList<Classification> AllowedClassifications,
    IReadOnlyList<ExecutedProbe>? ExecutedActions = null, BudgetUsage? CurrentUsage = null, AnalysisBudget? Budget = null);
public sealed record ExplorationDecision(bool Available, ExplorationAction Action, string TargetId, Classification Classification = Classification.Unknown);
public interface IExplorationDecider
{
    ValueTask<ExplorationDecision> DecideAsync(AnalysisState state, CancellationToken cancellationToken);
}
public sealed class UnavailableDecider : IExplorationDecider
{
    public ValueTask<ExplorationDecision> DecideAsync(AnalysisState state, CancellationToken cancellationToken) => ValueTask.FromResult(new ExplorationDecision(false, ExplorationAction.Stop, state.TargetId));
}
public sealed record CandidateFile(string ObjectId, string FileIdentity, long LogicalBytes, long ModifiedUtcTicks, string? ContentSha256 = null);
public sealed record DuplicateEvidence(string ContentSha256, IReadOnlyList<CandidateFile> RetainedFiles, bool RetainedChoiceConfirmed = false);
public sealed record Suggestion(string SuggestionId, string TargetId, Classification Classification, SuggestionLevel Level,
    IReadOnlyList<CandidateFile> CandidateFiles, IReadOnlyList<string> EvidenceIds, IReadOnlyList<string> Doubts,
    string Impact, bool HardProtected, bool SelectedByDefault = false, DuplicateEvidence? Duplicate = null)
{
    public bool MayPrepareForReview => !HardProtected && Classification is not (Classification.Unknown or Classification.UserData or Classification.Mixed or Classification.Portable or Classification.SpaceOnly) && Level == SuggestionLevel.ReviewSuggested && CandidateFiles.Count > 0;
}
public sealed record AnalysisBudget(int MaxSteps = 12, int MaxMetadataObjects = 4096, int MaxReadFiles = 24, long MaxSampleBytes = 65536,
    long MaxHashBytes = 67108864, int MaxHashFiles = 16, int MaxStateEvidence = 32, int MaxDecisionTargets = 32, long LargeFileBytes = 104857600);
public sealed record BudgetUsage(int Steps, int MetadataObjects, int ReadFiles, long SampleBytes, long HashBytes, int HashFiles);
public sealed record AnalysisResult(string TaskId, long Revision, AnalysisStatus Status, IReadOnlyList<AnalysisEvidence> Evidence,
    IReadOnlyList<Suggestion> Suggestions, IReadOnlyList<ExplorationAction> ExecutedActions, BudgetUsage Usage, string Reason);

internal sealed class BudgetMeter
{
    internal readonly AnalysisBudget Limits;
    private readonly int maxMetadata;
    private readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
    private readonly TimeSpan? duration;
    private readonly CancellationToken cancellation;
    private readonly bool untilComplete;
    private readonly AnalysisResources resources = AnalysisResources.Capture();
    private int resourceChecks;
    internal int Steps, MetadataObjects, ReadFiles, HashFiles;
    internal long SampleBytes, HashBytes;
    internal BudgetMeter(AnalysisBudget budget)
    { Limits = Validate(budget); maxMetadata = Limits.MaxMetadataObjects; }
    internal BudgetMeter(HeuristicBudget budget, CancellationToken token)
    {
        untilComplete = budget.UntilComplete;
        if (budget.MaxTargets is < 1 or > 250000 || budget.MaxActions is < 1 or > 750000 ||
            budget.MaxMetadataObjects < 1 || budget.MaxReadFiles < 0 ||
            budget.MaxSampleBytes is < 0 or > 1048576 || budget.MaxHashBytes is < 0 or > 268435456 ||
            budget.MaxHashFiles is < 0 or > 256 || budget.LargeFileBytes < 1 ||
            (budget.MaxDuration ?? TimeSpan.FromSeconds(30)) <= TimeSpan.Zero ||
            (budget.MaxDuration ?? TimeSpan.FromSeconds(30)) > TimeSpan.FromMinutes(10))
            throw new ArgumentException("Invalid heuristic budget");
        Limits = new AnalysisBudget(MaxSteps: budget.MaxActions, MaxMetadataObjects: budget.MaxMetadataObjects,
            MaxReadFiles: budget.MaxReadFiles, MaxSampleBytes: budget.MaxSampleBytes,
            MaxHashBytes: budget.MaxHashBytes, MaxHashFiles: budget.MaxHashFiles, LargeFileBytes: budget.LargeFileBytes);
        maxMetadata = budget.MaxMetadataObjects; duration = untilComplete ? null : budget.MaxDuration ?? TimeSpan.FromSeconds(30); cancellation = token;
    }
    private static AnalysisBudget Validate(AnalysisBudget b)
    {
        if (b.MaxSteps is < 1 or > 64 || b.MaxMetadataObjects is < 1 or > 50000 || b.MaxReadFiles is < 0 or > 256 || b.MaxSampleBytes is < 0 or > 1048576 || b.MaxHashBytes is < 0 or > 1073741824 || b.MaxHashFiles is < 0 or > 256 || b.MaxStateEvidence is < 1 or > 64 || b.MaxDecisionTargets is < 1 or > 64 || b.LargeFileBytes < 1) throw new ArgumentException("Invalid analysis budget"); return b;
    }
    internal void Check()
    {
        cancellation.ThrowIfCancellationRequested();
        if (untilComplete && (resourceChecks++ & 1023) == 0 && resources.Exceeded) throw new BudgetExceededException("AnalysisMemoryPressure");
        if (duration.HasValue && clock.Elapsed >= duration.Value) throw new BudgetExceededException("DurationBudget");
    }
    internal void Metadata()
    { Check(); if (!untilComplete && MetadataObjects >= maxMetadata) throw new BudgetExceededException("MetadataBudget"); MetadataObjects++; }
    internal void Sample(int bytes, bool newFile = true)
    {
        Check(); if (bytes < 0 || (!untilComplete && ((newFile && ReadFiles >= Limits.MaxReadFiles) || SampleBytes + bytes > Limits.MaxSampleBytes))) throw new BudgetExceededException("SampleBudget");
        if (newFile) ReadFiles++; SampleBytes += bytes;
    }
    internal void Hash(long bytes)
    {
        Check(); if (bytes < 0 || (!untilComplete && (HashFiles >= Limits.MaxHashFiles || HashBytes + bytes > Limits.MaxHashBytes))) throw new BudgetExceededException("HashBudget");
        HashFiles++; HashBytes += bytes;
    }
    internal BudgetUsage Usage => new(Steps, MetadataObjects, ReadFiles, SampleBytes, HashBytes, HashFiles);
}
internal sealed class BudgetExceededException(string reason = "ReadMetadataOrHashBudget") : Exception(reason);
