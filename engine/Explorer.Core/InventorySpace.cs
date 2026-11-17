using System.Globalization;

namespace SafeJunkCleaner.Explorer;

public sealed partial class InventoryEngine
{
    private readonly OpaqueCursorCodec spaceCursors = new();
    private readonly Dictionary<string, (long Revision, SpaceItem[] Items)> spaceCache = new(StringComparer.Ordinal);
    public void ReleaseSpaceDisplayCache(string task)
    {
        lock (gate) { Owned(task); spaceCache.Clear(); }
    }

    // Owner validation is retained on EVERY access; unlike GetProgress this does
    // not run byte/count aggregates for every page of a trusted snapshot export.
    public InventoryTaskHeader ReadTaskHeader(string task)
    {
        lock (gate)
        {
            Owned(task);
            var values = Rows("""
                SELECT t.state,t.reason,t.revision,t.root,t.identity,t.owner,o.id
                FROM tasks t JOIN objects o ON o.task=t.id AND o.parent IS NULL
                WHERE t.id=@p0 ORDER BY o.id LIMIT 2
                """, task);
            if (values.Count != 1) throw new InvalidOperationException("InventoryRootMissing");
            var row = values[0];
            return new(task, (string)row["state"]!, row["reason"] as string, (long)row["revision"]!,
                ((long)row["id"]!).ToString(CultureInfo.InvariantCulture), (string)row["root"]!, (string)row["identity"]!, (string)row["owner"]!);
        }
    }
    public SpacePage QuerySpace(string task, string? afterCursor, int size)
    {
        InventoryTaskHeader header;
        int offset;
        SpaceObservation[]? observations = null;
        (long Revision, SpaceItem[] Items) cached;
        lock (gate)
        {
            Owned(task); Page(0, size);
            header = ReadTaskHeader(task);
            if (header.State is not ("Ready" or "Partial" or "Paused" or "Cancelled" or "Failed")) throw new InvalidOperationException("InventoryNotStableForSpace");
            offset = spaceCursors.Decode(afterCursor, task, header.EvidenceRevision, "", ObservedSpaceIndex.Sort, "space");
            if (!spaceCache.TryGetValue(task, out cached) || cached.Revision != header.EvidenceRevision)
            {
                // One indexed read per evidence generation. No filesystem walk.
                var rows = Rows("SELECT id,parent,path,kind,identity,logical,allocated,links,coverage,scan FROM objects WHERE task=@p0 ORDER BY id", task);
                observations = rows.Select(r => new SpaceObservation((long)r["id"]!, r["parent"] as long?, (string)r["path"]!, (string)r["kind"]!, r["identity"] as string,
                    r["logical"] as long?, r["allocated"] as long?, r["links"] as long? ?? 0, (string)r["coverage"]!, (string)r["scan"]!)).ToArray();
            }
        }
        // Aggregation uses captured metadata only and must not block progress/cancel
        // behind the engine gate. A changed generation can never publish this cache.
        if (observations != null)
        {
            cached = (header.EvidenceRevision, ObservedSpaceIndex.Build(observations));
            lock (gate)
            {
                if (ReadTaskHeader(task) != header) throw new InvalidOperationException("SpaceRevisionChanged");
                spaceCache[task] = cached;
            }
        }
        lock (gate)
        {
            if (ReadTaskHeader(task) != header) throw new InvalidOperationException("SpaceRevisionChanged");
            if (offset > cached.Items.Length) throw new InvalidOperationException("InvalidCursor");
            var items = cached.Items.Skip(offset).Take(size).ToArray();
            string? next = offset + items.Length < cached.Items.Length
                ? spaceCursors.Encode(task, header.EvidenceRevision, "", ObservedSpaceIndex.Sort, "space", offset + items.Length) : null;
            return new(items, next, header.EvidenceRevision, ObservedSpaceIndex.Semantics);
        }
    }
}
