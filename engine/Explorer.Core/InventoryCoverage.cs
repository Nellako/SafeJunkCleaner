namespace SafeJunkCleaner.Explorer;

public sealed partial class InventoryEngine
{
    private readonly Dictionary<string, (long Revision, Dictionary<string, long> Reasons)> coverageReasons = new(StringComparer.Ordinal);
    private Dictionary<string, long>? ReadCoverageReasons(string task, string status, long revision)
    {
        if (status == "Inventory") return null;
        if (coverageReasons.TryGetValue(task, out var held) && held.Revision == revision) return held.Reasons;
        var result = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var row in Rows("SELECT reason,COUNT(*) AS amount FROM objects WHERE task=@p0 AND coverage='NotCovered' GROUP BY reason", task))
        {
            string raw = row["reason"] as string ?? "Unknown";
            string kind = raw switch
            {
                "ReparseOfflineOrCloudPlaceholder" => "LinkOrCloud",
                "ProtectedVolumeInternal" or "OtherAccount" or "ProtectedSystemOrOtherAccount" or "ApplicationState" => "ProtectedScope",
                _ when raw.StartsWith("MetadataUnavailable:", StringComparison.Ordinal) => "MetadataUnavailable",
                _ when raw.StartsWith("DirectoryUnavailable:", StringComparison.Ordinal) => "DirectoryUnavailable",
                _ => "Other"
            };
            result[kind] = result.GetValueOrDefault(kind) + Convert.ToInt64(row["amount"]);
        }
        // Keep the last summary only: display cache, never execution authorization.
        coverageReasons.Clear(); coverageReasons[task] = (revision, result); return result;
    }
}
