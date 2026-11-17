using System.Security.Cryptography;
using System.Text.Json;
using SafeJunkCleaner.Explorer.Analysis;
using SafeJunkCleaner.Explorer.Application;
using SafeJunkCleaner.Explorer.Execution;

namespace SafeJunkCleaner.Explorer.Host;

// Two-stage composition: canonical source is built with BASE facts and the narrow
// hash binder, then execution exceptions crosscheck that SAME current adapter source.
internal sealed class HostBuildArtifactProvider(ITrustedInventoryRows rows, Func<ITrustedAnalysisSnapshots> analysis) : ITrustedBuildArtifactAuthorizations
{
    private IApprovalSource? currentSource;
    internal void Bind(IApprovalSource source) { if (currentSource != null) throw new InvalidOperationException("SourceAlreadyBound"); currentSource = source; }
    private static string Hash<T>(T value) => Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(value)));
    internal FileSnapshot? BindCandidateHash(FileSnapshot expected)
    {
        var snapshots = analysis();
        if (snapshots is IHostProofContext { ProofHashes: { } proof }) return proof.Bind(expected);
        try
        {
            if (expected.Size is < 0 or > 67108864) return null;
            using var guard = WindowsFacts.Guard(Path.GetDirectoryName(expected.Path)!);
            var before = WindowsFacts.Read(expected.Path);
            if (before.Identity != expected.Identity || before.LogicalBytes != expected.Size || before.ModifiedUtc != expected.ModifiedUtc || before.Links != 1 || (before.Attributes & (WindowsFacts.UnsafeAttributes | 16 | 1)) != 0) return null;
            using var stream = new FileStream(expected.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
            var token = (analysis() as ITrustedAnalysisBuildContext)?.BuildCancellationToken ?? CancellationToken.None;
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[65536]; int count;
            while ((count = stream.Read(buffer)) != 0) { token.ThrowIfCancellationRequested(); digest.AppendData(buffer, 0, count); }
            token.ThrowIfCancellationRequested();
            string hash = Convert.ToHexString(digest.GetHashAndReset());
            return WindowsFacts.Read(expected.Path) == before ? expected with { ContentSha256 = hash } : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { return null; }
    }
    public BuildArtifactAuthorization? ReadCurrent(string canonicalPath)
    {
        if (currentSource == null || !Path.GetExtension(canonicalPath).Equals(".dll", StringComparison.OrdinalIgnoreCase)) return null;
        // Task selection only from trusted current snapshots, never filesystem discovery.
        string[] tasks; lock (knownTasks) tasks = knownTasks.ToArray();
        foreach (var task in tasks)
        {
            try
            {
                var source = currentSource.Read(task); var header = rows.ReadHeader(task); var result = analysis().Read(task, header.Revision);
                var snapshots = analysis();
                var adapted = snapshots is ITrustedInventorySnapshots cached ? cached.ReadInventory(task, header.Revision)
                    : new InventorySnapshotAdapter(rows, source.OwnerSid).Load(task, header.Revision);
                foreach (var suggestion in result.Suggestions.Where(s => s.Classification == Classification.BuildArtifact && s.MayPrepareForReview))
                {
                    var id = StableIds.Create(task, header.Revision, "suggestion", suggestion.SuggestionId);
                    var group = source.Suggestions.SingleOrDefault(s => s.SuggestionId == id && !s.HardProtected);
                    var candidate = group?.Files.SingleOrDefault(f => f.Path.Equals(canonicalPath, StringComparison.OrdinalIgnoreCase));
                    if (candidate == null || candidate.ContentSha256 == null) continue;
                    var output = adapted.Evidence.Targets[suggestion.TargetId];
                    if (Path.GetFileName(output.Path) is not ("bin" or "obj") || output.ParentId == null) continue;
                    var project = adapted.Evidence.Targets[output.ParentId];
                    var marker = adapted.Evidence.Targets.Values.FirstOrDefault(t => t.ParentId == project.ObjectId && t.Kind == TargetKind.File && Path.GetExtension(t.Path).ToLowerInvariant() is ".csproj" or ".fsproj" or ".vbproj");
                    if (marker == null || marker.LogicalBytes is null or > 8192) continue;
                    var markerFile = BindCandidateHash(new(StableIds.Create(task, header.Revision, "object", marker.ObjectId), marker.Path, marker.FileIdentity, marker.LogicalBytes.Value, new DateTime(marker.ModifiedUtcTicks, DateTimeKind.Utc).ToString("O")));
                    if (markerFile == null || analysis().Read(task, header.Revision).Revision != header.Revision) continue;
                    var markerCurrent = WindowsFacts.Read(marker.Path);
                    if (markerCurrent.Identity != marker.FileIdentity || markerCurrent.LogicalBytes != marker.LogicalBytes || markerCurrent.ModifiedUtc != new DateTime(marker.ModifiedUtcTicks, DateTimeKind.Utc).ToString("O")) continue;
                    var evidence = suggestion.EvidenceIds.FirstOrDefault(e => result.Evidence.Any(f => f.EvidenceId == e && f.Value == "DotNetGeneratedOutputMarkers"));
                    if (evidence == null) continue;
                    // Crosscheck against the exact same current canonical source builder.
                    var reread = currentSource.Read(task);
                    if ((!ReferenceEquals(reread, source) && Hash(reread) != Hash(source)) || rows.ReadHeader(task) != header) return null;
                    return new(source, id, candidate, project.Path, markerFile, StableIds.Create(task, header.Revision, "evidence", evidence), true);
                }
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { }
        }
        return null;
    }
    private readonly HashSet<string> knownTasks = new(StringComparer.Ordinal);
    internal void Register(string taskId) { lock (knownTasks) knownTasks.Add(taskId); }
}
