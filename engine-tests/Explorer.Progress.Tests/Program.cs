using System.Reflection;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using SafeJunkCleaner.Explorer;

internal static class Program
{
    private static readonly BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
    private static readonly List<object> Results = [];
    private static string root = "";
    private static int assertions;
    private const string Baseline = """
        SELECT COUNT(*) AS ObservedObjects,
            SUM(CASE WHEN scan='Pending' THEN 1 ELSE 0 END) AS PendingDirectories,
            SUM(CASE WHEN coverage='NotCovered' THEN 1 ELSE 0 END) AS SkippedObjects,
            (SELECT SUM(logical) FROM (SELECT MAX(logical) AS logical FROM objects
                WHERE task=$task AND kind='File' AND logical IS NOT NULL GROUP BY identity)) AS ObservedLogicalBytes,
            (SELECT SUM(allocated) FROM (SELECT MAX(allocated) AS allocated FROM objects
                WHERE task=$task AND kind='File' AND allocated IS NOT NULL GROUP BY identity)) AS ObservedAllocatedBytes,
            SUM(CASE WHEN kind='File' AND allocated IS NULL THEN 1 ELSE 0 END) AS UnknownAllocationObjects
        FROM objects WHERE task=$task
        """;

    private static object Gate(InventoryEngine engine) => typeof(InventoryEngine).GetField("gate", PrivateInstance)!.GetValue(engine)!;
    private static long FullQueries(InventoryEngine engine) => (long)typeof(InventoryEngine).GetField("progressFullQueries", PrivateInstance)!.GetValue(engine)!;
    private static void Assert(bool condition, string message)
    {
        assertions++;
        if (!condition) throw new InvalidOperationException(message);
    }
    private static SqliteConnection Open(string state)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = Path.Combine(state, "inventory.db"), Pooling = false
        }.ToString());
        connection.Open();
        return connection;
    }
    private static void Execute(SqliteConnection connection, string sql, params (string Name, object? Value)[] values)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        foreach (var (name, value) in values) command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        command.ExecuteNonQuery();
    }
    private static long Number(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(command.ExecuteScalar());
    }
    private static Dictionary<string, long?> ReadBaseline(SqliteConnection connection, string task)
    {
        using var command = connection.CreateCommand();
        command.CommandText = Baseline;
        command.Parameters.AddWithValue("$task", task);
        using var reader = command.ExecuteReader();
        Assert(reader.Read(), "baseline returns one row");
        return Enumerable.Range(0, reader.FieldCount).ToDictionary(reader.GetName,
            i => reader.IsDBNull(i) ? (long?)null : reader.GetInt64(i));
    }
    private static JsonElement Compare(InventoryEngine engine, SqliteConnection connection, string task)
    {
        lock (Gate(engine))
        {
            var actual = JsonSerializer.SerializeToElement(engine.GetProgress(task));
            foreach (var (key, value) in ReadBaseline(connection, task))
            {
                var field = actual.GetProperty("Coverage").GetProperty(key);
                Assert(value == (field.ValueKind == JsonValueKind.Null ? null : field.GetInt64()), "SQL baseline: " + key);
            }
            return actual;
        }
    }
    private static void Wait(InventoryEngine engine)
    {
        var worker = (Task?)typeof(InventoryEngine).GetField("worker", PrivateInstance)!.GetValue(engine);
        Assert(worker == null || worker.Wait(TimeSpan.FromSeconds(30)), "worker completed within bound");
    }
    private static string DirectoryAt(string name)
    {
        string path = Path.Combine(root, name);
        Directory.CreateDirectory(path);
        return path;
    }
    private static void SeedFile(SqliteConnection connection, string task, string path, long parent,
        string? identity, long? logical, long? allocated, string coverage = "Complete", string kind = "File")
    {
        Execute(connection, """
            INSERT INTO objects(task,path,parent,kind,identity,logical,allocated,observed,coverage,reason,scan,protection)
            VALUES($task,$path,$parent,$kind,$identity,$logical,$allocated,'fixture',$coverage,
                CASE WHEN $coverage='NotCovered' THEN 'FixtureUnavailable' ELSE NULL END,'Done','ReadOnly')
            """, ("$task", task), ("$path", WindowsFacts.Canonical(path)), ("$parent", parent), ("$kind", kind),
            ("$identity", identity), ("$logical", logical), ("$allocated", allocated), ("$coverage", coverage));
    }
    private static void ActiveAndTerminal()
    {
        string state = Path.Combine(root, "active-state"), tree = DirectoryAt("active-tree");
        for (int i = 0; i < 600; i++) File.WriteAllText(Path.Combine(tree, $"file-{i:D4}.tmp"), new string('x', i % 51));
        Directory.CreateDirectory(Path.Combine(tree, "nested"));
        using var engine = new InventoryEngine(state);
        using var connection = Open(state);
        string task;
        JsonElement before;
        lock (Gate(engine))
        {
            task = engine.CreateInventory(tree);
            long parent = Number(connection, "SELECT id FROM objects");
            // Two paths for one identity with independent logical/allocated maxima. Existing physical
            // paths also exercise INSERT ... DO NOTHING, not simulated insertion return values.
            SeedFile(connection, task, Path.Combine(tree, "file-0000.tmp"), parent, "fixture-hardlink", 10, 120);
            SeedFile(connection, task, Path.Combine(tree, "file-0001.tmp"), parent, "fixture-hardlink", 30, 80);
            SeedFile(connection, task, Path.Combine(tree, "null-one"), parent, null, 7, null);
            SeedFile(connection, task, Path.Combine(tree, "null-two"), parent, null, 11, 32);
            SeedFile(connection, task, Path.Combine(tree, "unknown"), parent, "fixture-unknown", null, null, "NotCovered");
            SeedFile(connection, task, Path.Combine(tree, "unclassified"), parent, null, null, null, "NotCovered", "Unknown");
            Execute(connection, "UPDATE tasks SET revision=revision+1 WHERE id=$task", ("$task", task));
            before = Compare(engine, connection, task);
            Assert(before.GetProperty("Coverage").GetProperty("ObservedLogicalBytes").GetInt64() == 41, "identity MAX, including NULL group");
            Assert(before.GetProperty("Coverage").GetProperty("ObservedAllocatedBytes").GetInt64() == 152, "allocated MAX independent of logical MAX");
            long queries = FullQueries(engine);
            Compare(engine, connection, task);
            Assert(FullQueries(engine) == queries, "active hot query does not repeat full SQL");
        }
        long initialQueries = FullQueries(engine);
        int activeSamples = 0;
        while (true)
        {
            var snapshot = Compare(engine, connection, task);
            if (snapshot.GetProperty("Task").GetProperty("State").GetString() != "Inventory") break;
            activeSamples++;
            Assert(FullQueries(engine) == initialQueries, "revision advances without rebuilding active map");
            Thread.Sleep(1);
        }
        Wait(engine);
        var terminal = Compare(engine, connection, task);
        Assert(activeSamples > 0, "real worker sampled while active");
        Assert(terminal.GetProperty("Task").GetProperty("State").GetString() == "Partial", "skipped records produce terminal Partial");
        Assert(terminal.GetProperty("Coverage").GetProperty("ObservedObjects").GetInt64() == 606, "duplicate paths not counted twice");
        Assert(Number(connection, "SELECT COUNT(*) FROM objects WHERE kind='Directory' AND enumeration_complete=1") == 2, "real directory enumeration proof retained");
        Assert(before.GetProperty("Coverage").GetProperty("ObservedObjects").GetInt64() == 7, "returned snapshots stay immutable");
        long terminalQueries = FullQueries(engine);
        Compare(engine, connection, task);
        Assert(FullQueries(engine) == terminalQueries, "terminal revision snapshot reused");
        Assert(Number(connection, "PRAGMA user_version") == 4, "schema remains 4");
        VerifyGroups(engine, connection, task);
    }
    private static void VerifyGroups(InventoryEngine engine, SqliteConnection connection, string task)
    {
        long after = 0;
        do
        {
            var page = JsonSerializer.SerializeToElement(engine.QueryGroups(task, after, 1));
            foreach (var group in page.GetProperty("Items").EnumerateArray())
            {
                long id = group.GetProperty("GroupId").GetInt64();
                using var command = connection.CreateCommand();
                command.CommandText = "SELECT COUNT(*),SUM(logical),SUM(allocated) FROM objects WHERE parent=$parent";
                command.Parameters.AddWithValue("$parent", id);
                using var reader = command.ExecuteReader();
                Assert(reader.Read(), "group baseline row");
                string[] names = ["ObservedDirectChildren", "DirectLogicalBytes", "DirectAllocatedBytes"];
                for (int i = 0; i < names.Length; i++)
                    Assert((reader.IsDBNull(i) ? (long?)null : reader.GetInt64(i)) ==
                        (group.GetProperty(names[i]).ValueKind == JsonValueKind.Null ? null : group.GetProperty(names[i]).GetInt64()), "group baseline: " + names[i]);
            }
            var cursor = page.GetProperty("NextAfter");
            if (cursor.ValueKind == JsonValueKind.Null) break;
            Assert(cursor.GetInt64() > after, "group cursor order");
            after = cursor.GetInt64();
        } while (true);
        using var plan = connection.CreateCommand();
        plan.CommandText = """
            EXPLAIN QUERY PLAN WITH page AS MATERIALIZED (
                SELECT id,path,coverage,reason,protection FROM objects
                WHERE task=$task AND kind='Directory' AND id>0 ORDER BY id LIMIT 64
            ), totals AS (
                SELECT page.id,COUNT(c.id),SUM(c.logical),SUM(c.allocated)
                FROM page LEFT JOIN objects c ON c.task=$task AND c.parent=page.id GROUP BY page.id
            ) SELECT * FROM page o JOIN totals ON totals.id=o.id ORDER BY o.id
            """;
        plan.Parameters.AddWithValue("$task", task);
        using var rows = plan.ExecuteReader();
        var details = new List<string>();
        while (rows.Read()) details.Add(rows.GetString(3));
        Assert(details.Any(line => line.Contains("SEARCH c USING INDEX children (task=? AND parent=?)", StringComparison.Ordinal)), "page aggregation searches children task/parent index");
        Assert(!details.Any(line => line.Contains("SCAN c", StringComparison.Ordinal)), "page aggregation has no full child scan");
        File.WriteAllLines(Path.Combine(root, "groups-explain.txt"), details);
    }
    private static void ResumeAndReopen()
    {
        string state = Path.Combine(root, "resume-state"), tree = DirectoryAt("resume-tree"), task;
        using (var engine = new InventoryEngine(state))
        using (var connection = Open(state))
        {
            lock (Gate(engine)) { task = engine.CreateInventory(tree); Compare(engine, connection, task); engine.Pause(task); }
            Wait(engine);
            Compare(engine, connection, task);
            lock (Gate(engine))
            {
                long parent = Number(connection, "SELECT id FROM objects");
                SeedFile(connection, task, Path.Combine(tree, "old-generation-only"), parent, "old", 999, 4096);
                Execute(connection, "UPDATE tasks SET revision=revision+1 WHERE id=$task", ("$task", task));
                Assert(Compare(engine, connection, task).GetProperty("Coverage").GetProperty("ObservedLogicalBytes").GetInt64() == 999, "paused old-generation snapshot populated");
                engine.Resume(task);
                var fresh = Compare(engine, connection, task).GetProperty("Coverage");
                Assert(fresh.GetProperty("ObservedObjects").GetInt64() == 1 && fresh.GetProperty("ObservedLogicalBytes").ValueKind == JsonValueKind.Null, "Resume never shows prior-generation totals");
                engine.Cancel(task);
            }
            Wait(engine);
            var cancelled = Compare(engine, connection, task);
            Assert(cancelled.GetProperty("Task").GetProperty("State").GetString() == "Cancelled", "cancel state retained");
            Assert(Number(connection, "SELECT COUNT(*) FROM objects WHERE scan='Pending' AND enumeration_complete IS NULL") == 1, "cancellation does not fabricate completion proof");
        }
        using (var reopened = new InventoryEngine(state))
        using (var connection = Open(state))
        {
            Compare(reopened, connection, task);
            long queries = FullQueries(reopened);
            Compare(reopened, connection, task);
            Assert(FullQueries(reopened) == queries, "reopened terminal SQL initialized once");
            string second;
            lock (Gate(reopened))
            {
                second = reopened.CreateInventory(tree);
                Compare(reopened, connection, second);
                long activeQueries = FullQueries(reopened);
                Compare(reopened, connection, task);
                Compare(reopened, connection, second);
                Assert(FullQueries(reopened) == activeQueries + 1, "reading another task preserves active-generation map");
                reopened.Cancel(second);
            }
            Wait(reopened);
            Compare(reopened, connection, second);
            reopened.ReleaseTask(task);
            bool missing = false;
            try { reopened.GetProgress(task); }
            catch (InvalidOperationException ex) when (ex.Message == "TaskNotOwnedOrMissing") { missing = true; }
            Assert(missing, "Release does not serve stale progress");
        }
    }
    private static void Rollback()
    {
        string state = Path.Combine(root, "rollback-state"), tree = DirectoryAt("rollback-tree");
        File.WriteAllText(Path.Combine(tree, "first.tmp"), "one");
        File.WriteAllText(Path.Combine(tree, "second.tmp"), "two");
        using var engine = new InventoryEngine(state);
        using var connection = Open(state);
        string task;
        lock (Gate(engine))
        {
            task = engine.CreateInventory(tree);
            Compare(engine, connection, task);
            Execute(connection, """
                CREATE TRIGGER fixture_fail_insert BEFORE INSERT ON objects
                WHEN NEW.kind='File' AND (SELECT COUNT(*) FROM objects WHERE kind='File')>=1
                BEGIN SELECT RAISE(ABORT,'fixture-insert-rollback'); END
                """);
        }
        Wait(engine);
        var failed = Compare(engine, connection, task);
        Assert(failed.GetProperty("Task").GetProperty("State").GetString() == "Failed", "trigger failure propagated");
        Assert(failed.GetProperty("Coverage").GetProperty("ObservedObjects").GetInt64() == 1, "rolled-back inserted prefix not counted");
        Assert(Number(connection, "SELECT COUNT(*) FROM objects WHERE enumeration_complete IS NOT NULL") == 0, "rollback leaves enumeration proof unset");
    }
    private static void EmptyAndNullSums()
    {
        string state = Path.Combine(root, "empty-state"), tree = DirectoryAt("empty-tree"), task;
        using var engine = new InventoryEngine(state);
        using var connection = Open(state);
        lock (Gate(engine)) { task = engine.CreateInventory(tree); engine.Cancel(task); }
        Wait(engine);
        // Artificial owned fixture only: empty historical inventory preserves SUM(empty) == NULL.
        Execute(connection, "DELETE FROM objects WHERE task=$task; UPDATE tasks SET revision=revision+1 WHERE id=$task", ("$task", task));
        var coverage = Compare(engine, connection, task).GetProperty("Coverage");
        Assert(coverage.GetProperty("PendingDirectories").ValueKind == JsonValueKind.Null && coverage.GetProperty("UnknownAllocationObjects").ValueKind == JsonValueKind.Null, "empty SUM is null, not zero");
    }
    private static void OrderedTaskExport()
    {
        string state = Path.Combine(root, "export-state"), tree = DirectoryAt("export-tree");
        for (int i = 0; i < 145; i++) File.WriteAllText(Path.Combine(tree, $"file-{i:D3}.tmp"), "fixture");
        string first;
        using (var engine = new InventoryEngine(state))
        {
            bool refused = false;
            try { engine.ConfigureStorageBudget(2048, false); } catch (InvalidOperationException) { refused = true; }
            Assert(refused, "storage budget cannot change without explicit confirmation");
            var budget = JsonSerializer.SerializeToElement(engine.ConfigureStorageBudget(2048, true));
            Assert(budget.GetProperty("MaxStateBytes").GetInt64() == 2147483648L && budget.GetProperty("SessionOnly").GetBoolean()
                && !budget.GetProperty("ObjectCountLimited").GetBoolean(), "confirmed session storage budget does not reinstate an object count cap");
            foreach (int invalid in new[] { 0, 511, 16385 })
            {
                refused = false; try { engine.ConfigureStorageBudget(invalid, true); } catch (InvalidOperationException) { refused = true; }
                Assert(refused, "invalid disk budget refused: " + invalid);
            }
            first = engine.CreateInventory(tree); Wait(engine);
            string second = engine.CreateInventory(tree); Wait(engine);
            using var connection = Open(state);
            using var command = connection.CreateCommand();
            command.CommandText = "EXPLAIN QUERY PLAN SELECT id,parent,path,kind,identity,logical,modified,attributes,links,coverage,reason,enumeration_complete FROM objects WHERE task=$task AND id>0 ORDER BY id LIMIT 64";
            command.Parameters.AddWithValue("$task", first);
            using var reader = command.ExecuteReader(); var plans = new List<string>();
            while (reader.Read()) plans.Add(reader.GetString(3));
            reader.Close();
            Assert(plans.All(p => !p.Contains("TEMP B-TREE", StringComparison.Ordinal)), "ordered export does not sort every page");
            foreach (string task in new[] { first, second })
            {
                var header = engine.ReadTaskHeader(task); long after = 0; var ids = new HashSet<string>();
                do
                {
                    var page = engine.ReadTrustedObjects(task, header.EvidenceRevision, after, 64);
                    foreach (var row in page.Rows) Assert(ids.Add(row.ObjectId), "no duplicate across pages");
                    if (page.NextCursor == null) break;
                    long next = long.Parse(page.NextCursor); Assert(next > after, "cursor advances"); after = next;
                } while (true);
                Assert(ids.Count == 146, "exact task set across multiple history ranges");
            }
            // Simulate an existing v4 database before this additive index, retaining all facts.
            Execute(connection, "DROP INDEX task_objects");
        }
        using (var reopened = new InventoryEngine(state))
        using (var connection = Open(state))
        {
            Assert(Number(connection, "PRAGMA user_version") == 4, "additive access path does not change stored schema semantics");
            Assert(Number(connection, "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='task_objects'") == 1, "existing v4 index repaired on open");
            Assert(Number(connection, "SELECT COUNT(*) FROM objects") == 292, "index creation preserves all history rows");
        }
    }
    private static void Run(string name, Action test)
    {
        try { test(); Results.Add(new { name, status = "Passed" }); Console.WriteLine("PASS " + name); }
        catch (Exception ex) { Results.Add(new { name, status = "Failed", error = ex.ToString() }); Console.WriteLine("FAIL " + name + " " + ex.Message); }
        File.WriteAllText(Path.Combine(root, "results.json"), JsonSerializer.Serialize(new { assertions, Results }, new JsonSerializerOptions { WriteIndented = true }));
    }
    public static int Main(string[] args)
    {
        if (args.Length != 1) throw new ArgumentException("Explicit existing retained evidence parent required");
        root = TestEvidence.CreateFixture(args[0], "progress-fixture");
        Run("ActiveCommittedIdentityAndGroups", ActiveAndTerminal);
        Run("ResumeCancelReopenSwitchRelease", ResumeAndReopen);
        Run("RealSqliteTriggerRollback", Rollback);
        Run("EmptyAndNullSums", EmptyAndNullSums);
        Run("LongPathMetadataAndHardLink", () => LongPathChecks.Run(root, Assert));
        Run("OrderedTaskExportAndExistingV4", OrderedTaskExport);
        Console.WriteLine($"Assertions: {assertions}; evidence: {root}");
        return Results.Any(result => JsonSerializer.SerializeToElement(result).GetProperty("status").GetString() == "Failed") ? 1 : 0;
    }
}
