using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using SafeJunkCleaner.Explorer;

internal static class Program
{
    private static readonly List<object> checks = [];
    private static int assertions;
    private static void Check(bool ok, string name) { assertions++; checks.Add(new { Name = name, Passed = ok }); if (!ok) throw new Exception(name); }
    private static JsonElement J(object o) => JsonSerializer.SerializeToElement(o);
    private static JsonElement Wait(InventoryEngine e, string task)
    {
        var timer = Stopwatch.StartNew();
        while (timer.Elapsed < TimeSpan.FromSeconds(90))
        {
            var p = J(e.GetProgress(task));
            if (p.GetProperty("Task").GetProperty("State").GetString() != "Inventory") return p;
            Thread.Sleep(2);
        }
        throw new TimeoutException("Inventory did not terminate");
    }
    private static void QueueTests()
    {
        var q = new InventoryScanQueue(true);
        // Unknowns precede preferred work, making each fair slot observable.
        for (int i = 1; i <= 10; i++) q.Add(new(i, @"E:\synthetic\unknown-" + i, "u" + i));
        for (int i = 11; i <= 110; i++) q.Add(new(i, @"E:\synthetic\p-" + i + @"\bin", "p" + i));
        for (int i = 1; i <= 110; i++) q.Add(new(i, @"E:\synthetic\duplicate\obj", "duplicate"));
        var seen = new HashSet<long>(); var order = new List<long>();
        for (int step = 1; step <= 110; step++)
        {
            var taken = q.Take(); Check(taken.Directory != null && seen.Add(taken.Directory.Id), "priority item unique step " + step);
            order.Add(taken.Directory!.Id);
            if (step <= 40 && step % 4 == 0) Check(taken.Directory.Id == step / 4 && !taken.Preferred, "fourth slot takes earliest unknown " + step);
            else if (step <= 40) Check(taken.Preferred, "nonfair slot preferred " + step);
        }
        Check(q.Take().Directory == null && seen.Count == 110, "duplicates do not create extra selections");
        var fifo = new InventoryScanQueue(false);
        long[] ids = [9, 3, 17, 1, 25];
        foreach (long id in ids) { fifo.Add(new(id, id % 2 == 0 ? @"E:\synthetic\bin" : @"E:\synthetic\obj", "x")); fifo.Add(new(id, @"E:\synthetic\cache", "x")); }
        foreach (long id in ids) { var t = fifo.Take(); Check(t.Directory?.Id == id && !t.Preferred, "disabled priority insertion FIFO " + id); }
        Check(fifo.Take().Directory == null, "FIFO deduplicated drain");
        checks.Add(new { Name = "FairOrder", First40 = order.Take(40).ToArray() });
    }
    private static List<string> AllPaths(InventoryEngine e, string task)
    {
        List<string> rows = []; long after = 0;
        while (true)
        {
            var page = J(e.QueryEvidence(task, after, 64, null));
            foreach (var row in page.GetProperty("Items").EnumerateArray())
                rows.Add(JsonSerializer.Serialize(new { Path = row.GetProperty("Path").GetString(), Coverage = row.GetProperty("Coverage").GetString(), Identity = row.GetProperty("FileIdentity").GetString(), Logical = row.GetProperty("LogicalBytes").ToString(), Allocated = row.GetProperty("AllocatedBytes").ToString(), Protection = row.GetProperty("Protection").GetString() }));
            if (page.GetProperty("NextAfter").ValueKind == JsonValueKind.Null) break;
            after = page.GetProperty("NextAfter").GetInt64();
        }
        rows.Sort(StringComparer.Ordinal); return rows;
    }
    private static (long Pending, long Unproved, long Count) ReadProof(string state, string task)
    {
        using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(state, "inventory.db"), Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString()); db.Open();
        using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT SUM(CASE WHEN scan='Pending' THEN 1 ELSE 0 END),SUM(CASE WHEN scan='Pending' AND enumeration_complete IS NULL AND coverage='Pending' THEN 1 ELSE 0 END),COUNT(*) FROM objects WHERE task=$t"; cmd.Parameters.AddWithValue("$t", task);
        using var r = cmd.ExecuteReader(); r.Read(); return (r.GetInt64(0), r.GetInt64(1), r.GetInt64(2));
    }
    private static JsonElement Scan(string state, string fixture, bool priority, out List<string> rows)
    {
        using var engine = new InventoryEngine(state, new ExplorerLimits(PrioritizeLayouts: priority));
        var task = engine.CreateInventory(fixture); var progress = Wait(engine, task);
        Check(progress.GetProperty("Task").GetProperty("State").GetString() == "Ready", "full scan ready priority=" + priority);
        rows = AllPaths(engine, task);
        var metrics = progress.GetProperty("Metrics");
        Check(metrics.GetProperty("QueueQueries").GetInt64() == 2, "exactly two queue queries priority=" + priority);
        Check(metrics.GetProperty("CommittedObjects").GetInt64() == rows.Count - 1, "committed objects match all evidence minus root priority=" + priority);
        Check(progress.GetProperty("Coverage").GetProperty("PendingDirectories").GetInt64() == 0, "complete scan no pending priority=" + priority);
        Check(priority ? metrics.GetProperty("PrioritySelections").GetInt64() > 0 : metrics.GetProperty("PrioritySelections").GetInt64() == 0, "priority switch reflected in metrics=" + priority);
        long revision = progress.GetProperty("Task").GetProperty("EvidenceRevision").GetInt64(); long after = 0; int proofCount = 0;
        while (true) { var p = engine.ReadTrustedObjects(task, revision, after, 64); foreach (var row in p.Rows.Where(r => r.Kind == "Directory")) { Check(row.DirectoryEnumerationComplete == true, "complete directory proved " + row.Path); proofCount++; } if (p.NextCursor == null) break; after = long.Parse(p.NextCursor); }
        checks.Add(new { Name = "FullScan", Priority = priority, Task = task, Progress = progress, AllPaths = rows, ProvedDirectories = proofCount });
        return progress;
    }
    public static int Main(string[] args)
    {
        string run = Path.Combine(Path.GetFullPath(args[0]), "scanqueue-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(run);
        try
        {
            QueueTests();
            string fixture = Path.Combine(run, "fixture"); Directory.CreateDirectory(fixture);
            string[] layouts = ["unknown-a", "unknown-b", "bin", "obj", "cache", "dist", "cache_data", "Code Cache", "GPUCache", "unknown-c"];
            foreach (string name in layouts) { var dir = Path.Combine(fixture, name); Directory.CreateDirectory(dir); for (int i = 0; i < 500; i++) File.WriteAllBytes(Path.Combine(dir, "file-" + i.ToString("D4") + ".dat"), new byte[1 + i % 97]); }
            Scan(Path.Combine(run, "state-fifo"), fixture, false, out var fifo);
            Scan(Path.Combine(run, "state-priority"), fixture, true, out var priority);
            Check(fifo.SequenceEqual(priority), "FIFO and priority full Path Coverage Identity Logical Allocated Protection sets equal");
            Check(fifo.Count == 5011 && fifo.Distinct(StringComparer.Ordinal).Count() == 5011, "all 5000 files and 11 directories covered exactly once");
            Check(priority.All(row => row.Contains("ReadOnlyNoProcessingAuthorization", StringComparison.Ordinal)), "layout names never confer processing authorization");
            // A single wide directory keeps enumeration in progress at object quota/cancellation.
            string wide = Path.Combine(run, "wide"); Directory.CreateDirectory(wide);
            for (int i = 0; i < 5000; i++) File.WriteAllText(Path.Combine(wide, "f-" + i.ToString("D4")), "fixture");
            string quotaState = Path.Combine(run, "state-quota"), quotaTask; JsonElement quota;
            using (var e = new InventoryEngine(quotaState, new ExplorerLimits(MaxObjectsPerTask: 501))) { quotaTask = e.CreateInventory(wide); quota = Wait(e, quotaTask); }
            Check(quota.GetProperty("Task").GetProperty("State").GetString() == "Partial" && quota.GetProperty("Task").GetProperty("Reason").GetString() == "IndexQuotaExceeded", "object quota partial explicit reason");
            var qp = ReadProof(quotaState, quotaTask);
            Check(qp.Count == 501 && qp.Pending == 1 && qp.Unproved == 1, "quota keeps root pending with null enumeration proof");
            Check(quota.GetProperty("Metrics").GetProperty("CommittedObjects").GetInt64() == 500, "quota committed metrics exact persisted children");
            checks.Add(new { Name = "Quota", Progress = quota, Pending = qp.Pending, Unproved = qp.Unproved, Persisted = qp.Count });
            string cancelState = Path.Combine(run, "state-cancel"), cancelTask; JsonElement cancelled;
            using (var e = new InventoryEngine(cancelState))
            {
                cancelTask = e.CreateInventory(wide); var timer = Stopwatch.StartNew();
                while (timer.Elapsed < TimeSpan.FromSeconds(30)) { var p = J(e.GetProgress(cancelTask)); if (p.GetProperty("Metrics").ValueKind == JsonValueKind.Object && p.GetProperty("Metrics").GetProperty("CommittedObjects").GetInt64() > 0) break; if (p.GetProperty("Task").GetProperty("State").GetString() != "Inventory") throw new Exception("Cancellation fixture finished before trigger"); Thread.Sleep(1); }
                e.Cancel(cancelTask); cancelled = Wait(e, cancelTask);
            }
            Check(cancelled.GetProperty("Task").GetProperty("State").GetString() == "Cancelled", "cancel terminates explicitly");
            var cp = ReadProof(cancelState, cancelTask);
            Check(cp.Pending == 1 && cp.Unproved == 1 && cp.Count > 1 && cp.Count < 5001, "cancel after committed batch keeps unfinished directory proof pending");
            Check(cancelled.GetProperty("Metrics").GetProperty("CommittedObjects").GetInt64() == cp.Count - 1, "cancel committed metrics match persisted evidence");
            checks.Add(new { Name = "Cancellation", Progress = cancelled, Pending = cp.Pending, Unproved = cp.Unproved, Persisted = cp.Count });
            var sources = new[] { "InventoryScanQueue.cs", "InventoryEngine.cs" }.ToDictionary(x => x, x => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.Combine(args[1], x)))));
            File.WriteAllText(Path.Combine(run, "result.json"), JsonSerializer.Serialize(new { Passed = true, Assertions = assertions, Utc = DateTime.UtcNow, Sources = sources, Checks = checks }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"SCANQUEUE PASS {assertions} assertions; evidence {run}"); return 0;
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(run, "failure.json"), JsonSerializer.Serialize(new { Passed = false, Assertions = assertions, Error = ex.ToString(), Checks = checks }, new JsonSerializerOptions { WriteIndented = true })); Console.Error.WriteLine(ex); Console.Error.WriteLine("Evidence: " + run); return 1; }
    }
}
