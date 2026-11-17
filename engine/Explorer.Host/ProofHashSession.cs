using System.Security.Cryptography;
using SafeJunkCleaner.Explorer.Analysis;
using SafeJunkCleaner.Explorer.Execution;

namespace SafeJunkCleaner.Explorer.Host;

internal interface IHostProofContext { ProofHashSession? ProofHashes { get; } }

// Investigation-only hash budget. Successful handles remain read-shared (no
// write/delete sharing) until the final canonical display source is published.
// Prepare/Execution do not reuse this cache: they perform fresh validation.
internal sealed class ProofHashSession(long maximumBytes, int maximumFiles, BudgetUsage schedulerUsage, CancellationToken token) : IDisposable
{
    private readonly AnalysisResources resources = AnalysisResources.Capture();
    internal const string BudgetReason = "ProofHashBudgetExceeded";
    private sealed record Entry(FileSnapshot Snapshot, string Hash, FileStream Stream, IDisposable Guard);
    private readonly Dictionary<(string Identity, long Size, string Modified), Entry> cache = new();
    internal readonly HashSet<string> DeniedIdentities = new(StringComparer.Ordinal);
    internal long HashBytes { get; private set; }
    internal int HashFiles { get; private set; }
    internal bool Sealed { get; set; }
    internal FileSnapshot? Bind(FileSnapshot expected)
    {
        token.ThrowIfCancellationRequested();
        if (expected.Size is < 0 or > 67108864) return null;
        IDisposable? guard = null; FileStream? stream = null;
        try
        {
            guard = WindowsFacts.Guard(Path.GetDirectoryName(expected.Path)!);
            var before = WindowsFacts.Read(expected.Path);
            if (before.Identity != expected.Identity || before.LogicalBytes != expected.Size || before.ModifiedUtc != expected.ModifiedUtc || before.Links != 1 || (before.Attributes & (WindowsFacts.UnsafeAttributes | 16 | 1)) != 0) return null;
            var key = (expected.Identity, expected.Size, expected.ModifiedUtc);
            if (cache.TryGetValue(key, out var cached))
            {
                // The original protected handle still prohibits content replacement
                // or same-metadata writes; fresh path/ancestor facts are checked above.
                return expected with { ContentSha256 = cached.Hash };
            }
            if (Sealed || schedulerUsage.HashFiles + HashFiles >= maximumFiles || expected.Size > maximumBytes - schedulerUsage.HashBytes - HashBytes)
            { DeniedIdentities.Add(expected.Identity); return null; }
            if (maximumFiles == int.MaxValue)
            {
                using var process = System.Diagnostics.Process.GetCurrentProcess();
                if (resources.Exceeded || process.HandleCount > 16384)
                    throw new InvalidOperationException("AnalysisResourcePressure");
            }
            stream = new(expected.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length != expected.Size) return null;
            HashFiles++;
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[65536]; long remaining = expected.Size;
            while (remaining > 0)
            {
                token.ThrowIfCancellationRequested();
                int count = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                if (count == 0) throw new IOException("ProofFileShortRead");
                HashBytes += count; remaining -= count; digest.AppendData(buffer, 0, count);
            }
            token.ThrowIfCancellationRequested();
            string hash = Convert.ToHexString(digest.GetHashAndReset());
            if (WindowsFacts.Read(expected.Path) != before) return null;
            cache.Add(key, new(expected, hash, stream, guard)); stream = null; guard = null;
            return expected with { ContentSha256 = hash };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { return null; }
        finally { stream?.Dispose(); guard?.Dispose(); }
    }
    internal BudgetUsage Merge() => schedulerUsage with { HashBytes = checked(schedulerUsage.HashBytes + HashBytes), HashFiles = checked(schedulerUsage.HashFiles + HashFiles) };
    public void Dispose() { foreach (var entry in cache.Values) { entry.Stream.Dispose(); entry.Guard.Dispose(); } cache.Clear(); }
}
