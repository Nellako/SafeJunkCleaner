using System.Globalization;

namespace SafeJunkCleaner.Explorer;

public sealed record TrustedInventoryObject(string ObjectId, string? ParentId, string Path, string Kind,
    string? FileIdentity, long? LogicalBytes, string? ModifiedUtc, uint? Attributes, uint? LinkCount,
    string Coverage, string? SkippedReason, bool? DirectoryEnumerationComplete);
public sealed record TrustedInventoryObjectPage(IReadOnlyList<TrustedInventoryObject> Rows, string? NextCursor);

public sealed partial class InventoryEngine
{
    // In-process export only. A selected target is an owned object ID, never a caller-supplied path.
    public TrustedInventoryObjectPage ReadTrustedObjects(string task, long revision, long after, int size, long? selectedTarget = null)
    {
        lock (gate)
        {
            var header = ReadTaskHeader(task);
            if (header.EvidenceRevision != revision || header.State is not ("Ready" or "Partial"))
                throw new InvalidOperationException("InventoryRevisionChanged");
            Page(after, size);
            if (selectedTarget.HasValue && Convert.ToInt64(Scalar("SELECT COUNT(*) FROM objects WHERE task=@p0 AND id=@p1", task, selectedTarget.Value)) != 1)
                throw new InvalidOperationException("TargetNotInInventory");
            string prefix = selectedTarget.HasValue ? """
                WITH RECURSIVE descendants(id) AS (
                    SELECT id FROM objects WHERE task=@p0 AND id=@p4
                    UNION ALL SELECT c.id FROM objects c JOIN descendants d ON c.parent=d.id WHERE c.task=@p0
                ), ancestors(id,parent) AS (
                    SELECT id,parent FROM objects WHERE task=@p0 AND id=@p4
                    UNION ALL SELECT p.id,p.parent FROM objects p JOIN ancestors a ON p.id=a.parent WHERE p.task=@p0
                ), selected(id) AS (
                    SELECT id FROM descendants UNION SELECT id FROM ancestors
                    UNION SELECT c.id FROM objects c JOIN ancestors a ON c.parent=a.id WHERE c.task=@p0
                )
                """ : "";
            string filter = selectedTarget.HasValue ? " AND id IN (SELECT id FROM selected)" : "";
            using var command = Command(prefix + "SELECT id,parent,path,kind,identity,logical,modified,attributes,links,coverage,reason,enumeration_complete FROM objects WHERE task=@p0 AND id>@p1" + filter + " ORDER BY id LIMIT @p2", task, after, size, null, selectedTarget);
            using var reader = command.ExecuteReader();
            var rows = new List<TrustedInventoryObject>();
            while (reader.Read())
            {
                string? Text(int column) => reader.IsDBNull(column) ? null : reader.GetString(column);
                uint? Number(int column) => reader.IsDBNull(column) ? null : checked((uint)reader.GetInt64(column));
                bool? complete = reader.IsDBNull(11) ? null : reader.GetInt64(11) == 1;
                rows.Add(new(reader.GetInt64(0).ToString(CultureInfo.InvariantCulture), reader.IsDBNull(1) ? null : reader.GetInt64(1).ToString(CultureInfo.InvariantCulture),
                    reader.GetString(2), reader.GetString(3), Text(4), reader.IsDBNull(5) ? null : reader.GetInt64(5), Text(6), Number(7), Number(8), reader.GetString(9), Text(10), complete));
            }
            return new(rows, rows.Count == size ? rows[^1].ObjectId : null);
        }
    }
}
