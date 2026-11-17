using System.Globalization;
using SafeJunkCleaner.Explorer.Application;

namespace SafeJunkCleaner.Explorer.Host;

// Trusted in-process adapter: UI never supplies rows, scope identities or owner SIDs.
internal sealed class HostInventoryRows(InventoryEngine engine) : ITrustedSelectedInventoryRows, ITrustedSnapshotResources
{
    public void ReleaseDisplayCaches(string taskId) => engine.ReleaseSpaceDisplayCache(taskId);
    public TrustedTaskHeader ReadHeader(string taskId)
    {
        var header = engine.ReadTaskHeader(taskId);
        return new(taskId, header.EvidenceRevision, StableIds.Create(taskId, 1, "scope", header.RootIdentity), header.RootIdentity,
            "read-only-policy-v1", header.OwnerSid, header.RootObjectId, header.RootPath, header.RootIdentity, header.State);
    }
    public InventoryPage ReadPage(string taskId, long revision, string? after, int size) => Read(taskId, revision, after, size, null);
    public InventoryPage ReadSelectedPage(string taskId, long revision, string targetId, string? after, int size)
    {
        if (!long.TryParse(targetId, NumberStyles.None, CultureInfo.InvariantCulture, out var target) || target <= 0)
            throw new InvalidOperationException("TargetNotInInventory");
        return Read(taskId, revision, after, size, target);
    }
    private InventoryPage Read(string taskId, long revision, string? after, int size, long? target)
    {
        if (size is < 1 or > 64 || after != null && (!long.TryParse(after, NumberStyles.None, CultureInfo.InvariantCulture, out _) || after.Length > 20))
            throw new InvalidOperationException("InvalidInventoryCursor");
        long cursor = after == null ? 0 : long.Parse(after, CultureInfo.InvariantCulture);
        var page = engine.ReadTrustedObjects(taskId, revision, cursor, size, target);
        return new(page.Rows.Select(r => new InventoryRow(r.ObjectId, r.ParentId, r.Path, r.Kind, r.FileIdentity,
            r.LogicalBytes, r.ModifiedUtc, r.Attributes, r.LinkCount, r.Coverage, r.SkippedReason,
            DirectoryEnumerationComplete: r.DirectoryEnumerationComplete)).ToArray(), page.NextCursor);
    }
}
