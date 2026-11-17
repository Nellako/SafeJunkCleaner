using System.Buffers.Binary;
using System.Text.RegularExpressions;

namespace SafeJunkCleaner.Explorer.Analysis;

// Format facts only, independently implemented. Chromium net/disk_cache/simple/
// simple_entry_format.h and simple_backend_version.h (entry v5, not index v9):
// https://github.com/chromium/chromium/blob/main/net/disk_cache/simple/simple_entry_format.h
internal static class SimpleCacheFormat
{
    internal const ulong InitialMagic = 0xfcfb6d1ba7725c30, FinalMagic = 0xf4fa6f45970d41d8;
    internal const int FixedBytes = 24, MaximumFiles = 32;
    internal static bool IsEntry(string name) => Regex.IsMatch(name, "^[0-9a-f]{16}_[01]$", RegexOptions.CultureInvariant);
    internal static bool IsClue(string name) => Regex.IsMatch(name, "^[0-9a-fA-F]{16}_[01s]$", RegexOptions.CultureInvariant) || name.StartsWith("todelete_", StringComparison.Ordinal);
    internal static uint U32(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
    internal static ulong U64(byte[] bytes) => BinaryPrimitives.ReadUInt64LittleEndian(bytes);
    internal static string? Header(byte[] bytes)
    {
        if (U64(bytes) != InitialMagic) return "MalformedHeader";
        if (U32(bytes, 8) != 5) return "UnknownVersion";
        if (U32(bytes, 12) is 0 or >= int.MaxValue || U32(bytes, 20) != 0) return "MalformedHeader";
        return null;
    }
    internal static string? Footer(byte[] bytes, bool stream0)
    {
        if (U64(bytes) != FinalMagic) return "MalformedFooter";
        uint flags = U32(bytes, 8);
        if ((flags & ~3u) != 0 || (!stream0 && (flags & 2) != 0)) return "UnknownFlags";
        if (U32(bytes, 20) != 0 || (stream0 && U32(bytes, 16) >= int.MaxValue)) return "MalformedFooter";
        return null;
    }
}

internal sealed partial class ProbeContext
{
    private void SimpleCacheLayout(InventoryTarget target)
    {
        var facts = new List<string>();
        void Note(string code, EvidenceKind kind = EvidenceKind.Missing) => facts.Add(Fact(target, kind, "ChromiumSimpleCache" + code));
        void Display(bool recognized)
        {
            Note("DisplayOnlyNoContentCrc", EvidenceKind.Protection);
            Suggest(target, recognized ? Classification.Cache : Classification.Unknown, SuggestionLevel.OrganizeOpportunity,
                [], facts, true, "Fixed structure only; key, URL, HTTP headers, payload and key SHA are not read; content CRC is not verified; no processing authorization");
        }
        try
        {
            var summary = Index.Get(target);
            if (Protected(target) || ProtectedByInventory(target) || !summary.SubtreeComplete || summary.Portable || summary.PrivateFiles > 0 || summary.SourceFiles > 0)
            { Note("ProtectedScope", EvidenceKind.Protection); Display(false); return; }
            for (InventoryTarget? ancestor = target; ancestor != null; ancestor = ancestor.ParentId != null ? Snapshot.Targets[ancestor.ParentId] : null)
            {
                if (HardProtection(ancestor) || Source(ancestor) || !AncestorCoverageAllowed(ancestor) || Index.Blocked(ancestor) || Index.Get(ancestor).Portable)
                { Note("ProtectedScope", EvidenceKind.Protection); Display(false); return; }
            }
            var members = Children(target);
            var entries = new List<InventoryTarget>();
            var all = new List<InventoryTarget>(members);
            foreach (var member in members)
            {
                string name = Path.GetFileName(member.Path);
                if (member.Kind == TargetKind.File && SimpleCacheFormat.IsEntry(name)) entries.Add(member);
                else if (member.Kind == TargetKind.File && name == "index") { /* metadata only */ }
                else if (member.Kind == TargetKind.Directory && name == "index-dir")
                {
                    var auxiliary = Children(member);
                    if (auxiliary.Any(t => t.Kind != TargetKind.File || Path.GetFileName(t.Path) is not ("the-real-index" or "temp-index")))
                    { Note("UnsupportedMember"); Display(false); return; }
                    all.AddRange(auxiliary);
                }
                else { Note("UnsupportedMember"); Display(false); return; }
            }
            var zeroHashes = entries.Where(t => t.Path.EndsWith("_0", StringComparison.Ordinal)).Select(t => Path.GetFileName(t.Path)[..16]).ToHashSet(StringComparer.Ordinal);
            if (zeroHashes.Count == 0 || entries.Any(t => !zeroHashes.Contains(Path.GetFileName(t.Path)[..16])))
            { Note("UnsupportedMember"); Display(false); return; }
            if (all.Any(t => Protected(t) || ProtectedByInventory(t) || Source(t) || t.LinkCount != 1 || !Index.Get(t).SubtreeComplete || (t.Kind == TargetKind.File && t.LogicalBytes is null)))
            { Note("ProtectedScope", EvidenceKind.Protection); Display(false); return; }
            // Preflight the entire batch. Never silently sample one entry then claim a whole directory.
            long fixedBytes = entries.Sum(t => t.Path.EndsWith("_0", StringComparison.Ordinal) ? 72L : 48L);
            if (entries.Count > SimpleCacheFormat.MaximumFiles || entries.Count > Meter.Limits.MaxReadFiles - Meter.ReadFiles || fixedBytes > Meter.Limits.MaxSampleBytes - Meter.SampleBytes)
            { Note("BudgetExceeded"); Display(false); throw new BudgetExceededException("SimpleCacheSampleBudget"); }
            if (entries.Any(t => t.LogicalBytes < (t.Path.EndsWith("_0", StringComparison.Ordinal) ? 72 : 48)))
            { Note("Truncated"); Display(false); return; }
            using var guard = MetadataAccess.Guard(Snapshot, target, Index, Meter);
            // Exact observed membership and every member's identity are checked BEFORE any content open.
            SimpleCacheMembership(target);
            foreach (var member in all) Validate(member);
            var headers = new Dictionary<string, (uint Length, uint Hash)>(StringComparer.Ordinal);
            foreach (var entry in entries.OrderBy(t => t.Path, StringComparer.Ordinal))
            {
                cancellation.ThrowIfCancellationRequested(); Meter.Check();
                SimpleCacheMembership(target);
                using var entryGuard = MetadataAccess.Guard(Snapshot, entry, Index, Meter);
                using var stream = MetadataAccess.ReadContent(Snapshot, entry, Meter);
                bool firstSegment = true;
                byte[] Segment(long offset)
                {
                    cancellation.ThrowIfCancellationRequested();
                    Meter.Sample(SimpleCacheFormat.FixedBytes, firstSegment); firstSegment = false;
                    byte[] bytes = new byte[SimpleCacheFormat.FixedBytes];
                    int received = 0;
                    while (received < bytes.Length)
                    {
                        int read = RandomAccess.Read(stream.SafeFileHandle, bytes.AsSpan(received), offset + received);
                        if (read == 0) throw new EndOfStreamException("SimpleCacheTruncated");
                        received += read;
                    }
                    return bytes;
                }
                long length = entry.LogicalBytes!.Value;
                var header = Segment(0); string? error = SimpleCacheFormat.Header(header);
                if (error != null) { Note(error); Display(false); return; }
                uint keyLength = SimpleCacheFormat.U32(header, 12), keyHash = SimpleCacheFormat.U32(header, 16);
                string hash = Path.GetFileName(entry.Path)[..16];
                if (headers.TryGetValue(hash, out var prior) && (prior.Length != keyLength || prior.Hash != keyHash))
                { Note("MalformedHeader"); Display(false); return; }
                headers[hash] = (keyLength, keyHash);
                bool stream0 = entry.Path.EndsWith("_0", StringComparison.Ordinal);
                var tail = Segment(length - 24); error = SimpleCacheFormat.Footer(tail, stream0);
                if (error != null) { Note(error); Display(false); return; }
                long keyEnd = 24L + keyLength;
                if (stream0)
                {
                    // _1 stores stream2 and has NO bearing on stream1 in _0. No key/SHA bytes read.
                    long middle = length - 24L - ((SimpleCacheFormat.U32(tail, 8) & 2) != 0 ? 32 : 0) - SimpleCacheFormat.U32(tail, 16) - 24;
                    if (middle < keyEnd || middle - keyEnd >= int.MaxValue)
                    { Note("MalformedArithmetic"); Display(false); return; }
                    var eof1 = Segment(middle); error = SimpleCacheFormat.Footer(eof1, false);
                    if (error != null) { Note(error); Display(false); return; }
                }
                else if (length - 24 < keyEnd || length - 24 - keyEnd >= int.MaxValue)
                { Note("MalformedArithmetic"); Display(false); return; }
                Validate(entry);
            }
            SimpleCacheMembership(target);
            foreach (var member in all) Validate(member);
            Note("Recognized", EvidenceKind.Layout); Display(true);
        }
        catch (BudgetExceededException)
        {
            Note("BudgetExceeded"); Display(false); throw;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            Note(ex.Message == "SimpleCacheMembershipChanged" ? "MembershipChanged" : "UnavailableOrInventoryChanged"); Display(false);
        }
    }

    private void SimpleCacheMembership(InventoryTarget target)
    {
        var pending = new Stack<InventoryTarget>(); pending.Push(target);
        while (pending.TryPop(out var directory))
        {
            Validate(directory);
            var expected = Index.Direct(directory).Select(t => t.ObjectId).ToHashSet(StringComparer.Ordinal);
            foreach (var path in Directory.EnumerateFileSystemEntries(directory.Path))
            {
                Meter.Metadata(); var observed = Index.AtPath(path);
                if (observed == null || observed.ParentId != directory.ObjectId || !expected.Remove(observed.ObjectId)) throw new IOException("SimpleCacheMembershipChanged");
                Validate(observed);
                if (observed.Kind == TargetKind.Directory) pending.Push(observed);
            }
            if (expected.Count != 0) throw new IOException("SimpleCacheMembershipChanged");
        }
    }
}
