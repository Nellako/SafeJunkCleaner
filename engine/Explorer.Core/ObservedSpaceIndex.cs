using System.Globalization;

namespace SafeJunkCleaner.Explorer;

public sealed record InventoryTaskHeader(string TaskId, string State, string? Reason, long EvidenceRevision,
    string RootObjectId, string RootPath, string RootIdentity, string OwnerSid);
public sealed record SpaceItem(string ObjectId, string Path, string Kind, long? ObservedLogicalBytes,
    long? ObservedAllocatedBytes, string Coverage, long UnknownAllocationObjects, long HardLinkedFiles);
public sealed record SpacePage(IReadOnlyList<SpaceItem> Items, string? NextCursor, long Revision, string Semantics);

internal sealed record SpaceObservation(long Id, long? Parent, string Path, string Kind, string? Identity,
    long? Logical, long? Allocated, long Links, string Coverage, string Scan);

// Bottom-up, small-to-large identity set unions. No per-target SQL/recursive tree
// queries, and no recursion on the managed stack for adversarially deep trees.
internal static class ObservedSpaceIndex
{
    internal const string Sort = "observed-logical-desc-allocated-desc-objectid-v1";
    internal const string Semantics = "Recursive observed metadata, not reclaimable bytes or a live snapshot. Each row deduplicates file identity within its subtree; the root deduplicates the entire scope. Directory rows overlap and must not be added together. Partial sums are lower bounds; null means no observed measure, never a fabricated zero for a coverage gap. UnknownAllocationObjects counts distinct unmeasured identities/unknown objects or unscanned directories. HardLinkedFiles counts distinct identities with multiple links (including repeated observed identities); allocation is counted once, not an estimate of releasable space.";
    private sealed record Measure(long? Logical, long? Allocated, bool Linked, int Observations);
    private sealed class Aggregate
    {
        internal readonly Dictionary<string, Measure> Files = new(StringComparer.Ordinal);
        internal long Logical, Allocated, LogicalKnown, AllocatedKnown, Unknown, Linked;
        internal void Add(string identity, Measure value)
        {
            if (Files.TryGetValue(identity, out var previous))
            {
                Apply(previous, -1);
                value = new(Max(previous.Logical, value.Logical), Max(previous.Allocated, value.Allocated), previous.Linked || value.Linked || previous.Observations + value.Observations > 1, previous.Observations + value.Observations);
            }
            Files[identity] = value; Apply(value, 1);
        }
        private static long? Max(long? x, long? y) => x == null ? y : y == null ? x : Math.Max(x.Value, y.Value);
        private void Apply(Measure value, int direction)
        {
            checked
            {
                if (value.Logical != null) { Logical += direction * value.Logical.Value; LogicalKnown += direction; }
                if (value.Allocated != null) { Allocated += direction * value.Allocated.Value; AllocatedKnown += direction; } else Unknown += direction;
                if (value.Linked) Linked += direction;
            }
        }
    }
    internal static SpaceItem[] Build(IReadOnlyList<SpaceObservation> observations)
    {
        var nodes = observations.ToDictionary(o => o.Id);
        var pending = new Dictionary<long, Aggregate>();
        var incomplete = new HashSet<long>();
        var items = new List<SpaceItem>(observations.Count);
        foreach (var o in observations.OrderByDescending(o => o.Id))
        {
            if (!pending.Remove(o.Id, out var sum)) sum = new();
            bool gap = o.Coverage != "Complete" || incomplete.Contains(o.Id);
            if (o.Kind == "File") sum.Add(o.Identity == null ? "object:" + o.Id : "identity:" + o.Identity, new(o.Logical, o.Allocated, o.Links > 1, 1));
            else if (o.Kind != "Directory" || o.Scan == "Pending" || o.Coverage == "NotCovered") sum.Add("object:" + o.Id, new(null, null, false, 1));
            bool emptyComplete = !gap && o.Kind == "Directory" && sum.Files.Count == 0;
            items.Add(new(o.Id.ToString(CultureInfo.InvariantCulture), o.Path, o.Kind,
                sum.LogicalKnown > 0 || emptyComplete ? sum.Logical : null,
                sum.AllocatedKnown > 0 || emptyComplete ? sum.Allocated : null,
                gap && o.Coverage == "Complete" ? "Partial" : o.Coverage, sum.Unknown, sum.Linked));
            if (o.Parent != null)
            {
                if (!nodes.TryGetValue(o.Parent.Value, out var parent) || parent.Id >= o.Id || parent.Kind != "Directory") throw new InvalidOperationException("InvalidSpaceIndexParent");
                if (gap) incomplete.Add(parent.Id);
                if (pending.TryGetValue(parent.Id, out var destination))
                {
                    if (destination.Files.Count < sum.Files.Count) (destination, sum) = (sum, destination);
                    foreach (var entry in sum.Files) destination.Add(entry.Key, entry.Value);
                    pending[parent.Id] = destination;
                }
                else pending.Add(parent.Id, sum);
            }
        }
        return items.OrderByDescending(i => i.ObservedLogicalBytes).ThenByDescending(i => i.ObservedAllocatedBytes)
            .ThenBy(i => i.ObjectId, StringComparer.Ordinal).ToArray();
    }
}
