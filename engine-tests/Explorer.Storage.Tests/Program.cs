using System.Security.Principal;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using SafeJunkCleaner.Explorer;

internal static class Program
{
    private static readonly List<string> checks = [];
    private static void Assert(bool value, string name) { if (!value) throw new Exception(name); checks.Add(name); }
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value);
    private static void Reject(Action action, string code)
    {
        try { action(); } catch (InvalidOperationException ex) when (ex.Message == code) { Assert(true, code); return; }
        throw new Exception("Expected rejection " + code);
    }
    private static void Wait(InventoryEngine e, string id)
    {
        for (int i = 0; i < 2000 && e.ReadTaskHeader(id).State == "Inventory"; i++) Thread.Sleep(5);
        Assert(e.ReadTaskHeader(id).State is "Ready" or "Partial", "Inventory terminal"); Thread.Sleep(10);
    }
    private static SqliteConnection Open(string root)
    {
        var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(root, "inventory.db"), Pooling = false }.ToString()); db.Open(); return db;
    }
    private static void Exec(SqliteConnection db, string sql) { using var c = db.CreateCommand(); c.CommandText = sql; c.ExecuteNonQuery(); }
    private static long Scalar(SqliteConnection db, string sql) { using var c = db.CreateCommand(); c.CommandText = sql; return Convert.ToInt64(c.ExecuteScalar()); }
    private static string RowsFingerprint(SqliteConnection db, string table)
    {
        using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT * FROM " + table + (table == "batch_entries" ? " ORDER BY batch,entry_index" : " ORDER BY id");
        using var reader = cmd.ExecuteReader(); using var hash = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
        while (reader.Read())
        {
            var values = new object?[reader.FieldCount]; for (int i = 0; i < values.Length; i++) values[i] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            var row = JsonSerializer.SerializeToUtf8Bytes(values); hash.AppendData(BitConverter.GetBytes(row.Length)); hash.AppendData(row);
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }
    private static void CheckpointFailure(string local, string files)
    {
        string state = Path.Combine(local, "reader-failure-state");
        using var e = new InventoryEngine(state); string task = e.CreateInventory(files); Wait(e, task);
        using var readerDb = Open(state); using var transaction = readerDb.BeginTransaction(deferred: true);
        using (var cmd = readerDb.CreateCommand()) { cmd.Transaction = transaction; cmd.CommandText = "SELECT * FROM objects"; using var rows = cmd.ExecuteReader(); Assert(rows.Read(), "External reader snapshot established"); }
        using (var writer = Open(state)) Exec(writer, "UPDATE tasks SET reason='synthetic-reader-fault' WHERE id='" + task + "'");
        string[] originalFiles = Directory.GetFiles(state); string tasks, objects;
        using (var current = Open(state)) { tasks = RowsFingerprint(current, "tasks"); objects = RowsFingerprint(current, "objects"); }
        StateCompactionException? failure = null; try { e.CompactState(true); } catch (StateCompactionException ex) { failure = ex; }
        Assert(failure != null && failure.Message == "DatabaseCheckpointBusy" && failure.Stage == "Vacuum" && failure.BackupPath != null && File.Exists(failure.BackupPath), "Checkpoint busy gives StateCompactionException stage and retained backup");
        Assert(originalFiles.All(File.Exists), "Failure retains every original state file including WAL and SHM");
        using (var current = Open(state))
        {
            using var check = current.CreateCommand(); check.CommandText = "PRAGMA quick_check"; Assert((string?)check.ExecuteScalar() == "ok", "Failure source quick_check ok");
            Assert(RowsFingerprint(current, "tasks") == tasks && RowsFingerprint(current, "objects") == objects, "Failure preserves exact source rows");
        }
        using (var backup = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = failure!.BackupPath, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString()))
        {
            backup.Open(); using var check = backup.CreateCommand(); check.CommandText = "PRAGMA quick_check"; Assert((string?)check.ExecuteScalar() == "ok", "Failure backup quick_check ok");
            Assert(RowsFingerprint(backup, "tasks") == tasks && RowsFingerprint(backup, "objects") == objects, "Failure backup exact rows recoverable");
        }
        transaction.Rollback();
    }
    private static void RealWorker(string local)
    {
        string tree = Path.Combine(local, "large-artificial-tree"); Directory.CreateDirectory(tree);
        for (int i = 0; i < 15000; i++) File.WriteAllText(Path.Combine(tree, i.ToString("D5") + ".tmp"), "artificial");
        string state = Path.Combine(local, "real-worker-state"); using var e = new InventoryEngine(state);
        string task = e.CreateInventory(tree);
        Assert(e.ReadTaskHeader(task).State == "Inventory", "Real worker verified Inventory before compaction attempt");
        Assert(!e.GetStorageInfo().CanCompact && e.GetStorageInfo().CompactionReason == "InventoryActive", "Real worker disallows compaction");
        Reject(() => e.CompactState(true), "InventoryActive"); e.Pause(task);
        for (int i = 0; i < 2000 && e.ReadTaskHeader(task).State == "Inventory"; i++) Thread.Sleep(5);
        Assert(e.ReadTaskHeader(task).State == "Paused", "Real worker safely paused without racing completion");
        Assert(Directory.GetFiles(tree).Length == 15000 && Directory.GetFiles(tree).All(p => File.ReadAllText(p) == "artificial"), "Complete artificial worker tree retained");
    }
    private static void Legacy(string root, int version)
    {
        using (var privateState = new PrivateState(root))
        using (var db = Open(root))
        {
            Exec(db, "CREATE TABLE tasks(id TEXT PRIMARY KEY,owner TEXT NOT NULL,root TEXT NOT NULL,identity TEXT NOT NULL,state TEXT NOT NULL,created TEXT NOT NULL,updated TEXT NOT NULL,reason TEXT,revision INTEGER NOT NULL DEFAULT 1);" +
                "CREATE TABLE objects(id INTEGER PRIMARY KEY AUTOINCREMENT,task TEXT NOT NULL,path TEXT NOT NULL,parent INTEGER,kind TEXT NOT NULL,identity TEXT,attributes INTEGER,links INTEGER,logical INTEGER,allocated INTEGER,modified TEXT,observed TEXT NOT NULL,coverage TEXT NOT NULL,reason TEXT,scan TEXT NOT NULL,protection TEXT NOT NULL" + (version == 2 ? ",enumeration_complete INTEGER NULL" : "") + ");" +
                "CREATE INDEX pending ON objects(task,scan,id);CREATE INDEX children ON objects(task,parent,id);CREATE INDEX largefiles ON objects(task,kind,logical DESC,id);PRAGMA user_version=" + version);
            using var c = db.CreateCommand(); c.CommandText = "INSERT INTO tasks(id,owner,root,identity,state,created,updated) VALUES($id,$owner,'E:\\synthetic','legacy','Ready','old','old')";
            string id = Guid.NewGuid().ToString("D"); c.Parameters.AddWithValue("$id", id); c.Parameters.AddWithValue("$owner", privateState.OwnerSid); c.ExecuteNonQuery();
            c.Parameters.Clear(); c.CommandText = "INSERT INTO objects(task,path,kind,observed,coverage,scan,protection) VALUES($id,'E:\\synthetic','Directory','old','Complete','Done','ReadOnly')"; c.Parameters.AddWithValue("$id", id); c.ExecuteNonQuery();
        }
        using (var engine = new InventoryEngine(root))
        {
            var row = Json(engine.ListTasks(null, 64)).GetProperty("Items")[0];
            Assert(row.GetProperty("ScanMode").GetString() == "Legacy", "v" + version + " legacy mode");
            using var db = Open(root);
            Assert(Scalar(db, "PRAGMA user_version") == 4 && Scalar(db, "SELECT COUNT(*) FROM objects WHERE enumeration_complete IS NULL") == 1, "v" + version + " upgrades without invented proof");
        }
    }
    private static void LegacyQuotaRecovery(string local)
    {
        string state = Path.Combine(local, "near-quota-v4-state"), tree = Path.Combine(local, "near-quota-empty-tree");
        Directory.CreateDirectory(tree);
        string task;
        using (var initial = new InventoryEngine(state)) { task = initial.CreateInventory(tree); Wait(initial, task); }
        using (var db = Open(state))
        {
            using (var tx = db.BeginTransaction())
            using (var c = db.CreateCommand())
            {
                c.Transaction = tx;
                c.CommandText = "INSERT INTO objects(task,path,parent,kind,identity,logical,observed,coverage,scan,protection) VALUES($t,$p,(SELECT MIN(id) FROM objects WHERE task=$t),'File',$i,1,'synthetic','Complete','Done','ReadOnlyNoProcessingAuthorization')";
                c.Parameters.AddWithValue("$t", task); c.Parameters.AddWithValue("$p", ""); c.Parameters.AddWithValue("$i", "");
                for (int i = 0; i < 12000; i++)
                {
                    c.Parameters["$p"].Value = Path.Combine(tree, "metadata-" + i + "-" + new string('x', 128) + ".tmp");
                    c.Parameters["$i"].Value = "synthetic-identity-" + i; c.ExecuteNonQuery();
                }
                tx.Commit();
            }
            string batch = Guid.NewGuid().ToString("D");
            using (var c = db.CreateCommand())
            {
                c.CommandText = "INSERT INTO batches(id,owner,scan_mode,state,revision,created,updated) SELECT $b,owner,'AllFixedDisks','Completed',1,created,updated FROM tasks WHERE id=$t;" +
                    "INSERT INTO batch_entries(batch,entry_index,root,identity,task,state,created,updated) SELECT $b,0,root,identity,id,'Ready',created,updated FROM tasks WHERE id=$t;";
                c.Parameters.AddWithValue("$b", batch); c.Parameters.AddWithValue("$t", task); c.ExecuteNonQuery();
            }
            Exec(db, "DROP INDEX task_objects;VACUUM;PRAGMA wal_checkpoint(TRUNCATE)");
        }
        var fingerprints = new Dictionary<string, string>();
        using (var db = Open(state))
            foreach (string table in new[] { "tasks", "objects", "batches", "batch_entries" }) fingerprints.Add(table, RowsFingerprint(db, table));
        long originalBytes = Directory.GetFiles(state).Sum(p => new FileInfo(p).Length), smallLimit = originalBytes + 4096;
        long originalDbBytes = new FileInfo(Path.Combine(state, "inventory.db")).Length;
        void Preserved(string stage)
        {
            using var db = Open(state);
            Assert(fingerprints.All(pair => RowsFingerprint(db, pair.Key) == pair.Value), stage + ": all four table fingerprints unchanged");
            using var check = db.CreateCommand(); check.CommandText = "PRAGMA quick_check";
            Assert((string?)check.ExecuteScalar() == "ok" && Scalar(db, "SELECT COUNT(*) FROM objects") == 12001, stage + ": valid legacy database retains every object");
        }
        using (var recovery = new InventoryEngine(state, new ExplorerLimits(MaxStateBytes: smallLimit)))
        {
            Assert(recovery.ReadTaskHeader(task).State == "Ready" && Json(recovery.ListTasks(null, 64)).GetProperty("Items").GetArrayLength() == 1,
                "STORE-01 near-quota legacy startup retains readable history and task");
            var before = recovery.GetStorageInfo();
            Assert(before.IndexRepairPending && before.MaxStateBytes == smallLimit, "optional index deferred without silently increasing budget");
            Assert(before.DbBytes == originalDbBytes && before.WalBytes == 0 && before.TotalBytes <= originalBytes + 65536,
                "deferred startup performs preflight before index allocation, not a large build followed by rollback");
            using (var db = Open(state)) Assert(Scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE name='task_objects'") == 0,
                "near-quota preflight does not construct a large index");
            Reject(() => recovery.CreateInventory(tree), "IndexQuotaExceededReleaseCompletedTask");
            Reject(() => recovery.ConfigureStorageBudget(512, false), "ExplicitStorageBudgetConfirmationRequired");
            Reject(() => recovery.ConfigureStorageBudget(1, true), "InvalidStorageBudget");
            Assert(recovery.GetStorageInfo().MaxStateBytes == smallLimit && recovery.GetStorageInfo().IndexRepairPending,
                "refused requests cannot change budget or index state");
            Preserved("Deferred startup and refused requests");
            var configured = Json(recovery.ConfigureStorageBudget(512, true));
            Assert(configured.GetProperty("MaxStateBytes").GetInt64() == 512L * 1024 * 1024 && configured.GetProperty("SessionOnly").GetBoolean() &&
                !configured.GetProperty("IndexRepairPending").GetBoolean(), "explicit budget adjustment repairs optional index in same session");
            Assert(!recovery.GetStorageInfo().IndexRepairPending && recovery.GetStorageInfo().TotalBytes <= recovery.GetStorageInfo().MaxStateBytes,
                "repaired index remains within confirmed physical quota");
            using (var db = Open(state)) Assert(Scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE name='task_objects'") == 1, "confirmed recovery installs access path");
            Preserved("Confirmed index-only repair");
        }
        using (var restarted = new InventoryEngine(state, new ExplorerLimits(MaxStateBytes: smallLimit)))
            Assert(restarted.GetStorageInfo().MaxStateBytes == smallLimit && restarted.ReadTaskHeader(task).State == "Ready", "budget adjustment neither persists new authority nor blocks later reads");
        Preserved("Reopened repaired store");
        Console.WriteLine($"LEGACY QUOTA RECOVERY: OriginalBytes={originalBytes}; StartupLimit={smallLimit}; Objects=12001; four-table fingerprints preserved; {state}");
    }
    public static int Main(string[] args)
    {
        string local = TestEvidence.CreateFixture(args[0], "storage-fixture"); Directory.CreateDirectory(local);
        File.WriteAllText(Path.Combine(local, ".sandbox-owner"), WindowsIdentity.GetCurrent().User!.Value + "|" + local);
        try
        {
            Legacy(Path.Combine(local, "v1-state"), 1); Legacy(Path.Combine(local, "v2-state"), 2);
            LegacyQuotaRecovery(local);
            string files = Path.Combine(local, "CaseFilter"); Directory.CreateDirectory(files); File.WriteAllText(Path.Combine(files, "sample.txt"), "retained synthetic source");
            var sourceHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(Path.Combine(files, "sample.txt"))));
            string state = Path.Combine(local, "history-state"); string retained;
            using (var e = new InventoryEngine(state))
            {
                var expected = new HashSet<string>();
                for (int i = 0; i < 65; i++) { string id = e.CreateInventory(files, i % 2 == 0 ? "Selected" : "AllFixedDisks"); Wait(e, id); expected.Add(id); }
                var p1 = Json(e.ListTasks(null, 64, "caseFILTER")); var p2 = Json(e.ListTasks(p1.GetProperty("NextAfterTaskId").GetString(), 64, "CASEfilter"));
                var all = p1.GetProperty("Items").EnumerateArray().Concat(p2.GetProperty("Items").EnumerateArray()).ToArray();
                Assert(all.Length == 65 && all.Select(x => x.GetProperty("TaskId").GetString()!).ToHashSet().SetEquals(expected), "65 filtered stable pages no loss/duplicate");
                Assert(all.All(x => x.GetProperty("RootPath").GetString() == files && x.GetProperty("ObservedObjects").GetInt64() == 2 && x.GetProperty("ObservedLogicalBytes").GetInt64() == 25), "Trusted history path and coverage summaries");
                Assert(Json(e.ListTasks(null, 64, "%' OR 1=1 --")).GetProperty("Items").GetArrayLength() == 0, "Filter is literal substring not SQL or wildcard");
                Reject(() => e.CreateInventory(files, "Scope"), "InvalidScanMode"); Reject(() => e.CompactState(false), "ExplicitCompactionConfirmationRequired");
                string unicode = Path.Combine(local, "Ärea-Évidence"); Directory.CreateDirectory(unicode);
                string unicodeTask = e.CreateInventory(unicode, "Selected"); Wait(e, unicodeTask);
                Assert(Json(e.ListTasks(null, 64, "äREA-éVIDENCE")).GetProperty("Items").EnumerateArray().Single().GetProperty("TaskId").GetString() == unicodeTask, "Unicode ordinal ignore-case history substring filter");
                e.ReleaseTask(unicodeTask);
                retained = expected.First(); foreach (var id in expected.Where(id => id != retained)) e.ReleaseTask(id);
            }
            // Fill a private artificial database without reading or changing any real state.
            using (var db = Open(state)) { Exec(db, "CREATE TABLE artificial_padding(value BLOB);INSERT INTO artificial_padding VALUES(zeroblob(4194304));DROP TABLE artificial_padding;PRAGMA wal_checkpoint(TRUNCATE)"); }
            using (var e = new InventoryEngine(state, new ExplorerLimits(MaxStateBytes: 2097152)))
            {
                Assert(e.GetStorageInfo().TotalBytes > 2097152 && e.GetStorageInfo().ReusableBytes > 0, "Small quota store full with reusable pages");
                Reject(() => e.CreateInventory(files), "IndexQuotaExceededReleaseCompletedTask");
                string taskRows, objectRows;
                using (var original = Open(state)) { taskRows = RowsFingerprint(original, "tasks"); objectRows = RowsFingerprint(original, "objects"); }
                var result = e.CompactState(true);
                using (var original = Open(state)) Assert(RowsFingerprint(original, "tasks") == taskRows && RowsFingerprint(original, "objects") == objectRows, "Compacted source exact row fingerprints preserved");
                using (var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(Path.GetDirectoryName(result.BackupPath)!, "manifest.json"))))
                    Assert(manifest.RootElement.GetProperty("TaskRowsSha256").GetString() == taskRows && manifest.RootElement.GetProperty("ObjectRowsSha256").GetString() == objectRows, "Manifest row fingerprints match independent original");
                using (var backup = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = result.BackupPath, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString()))
                { backup.Open(); Assert(RowsFingerprint(backup, "tasks") == taskRows && RowsFingerprint(backup, "objects") == objectRows, "Backup exact rows not only counts"); }
                string restored = Path.Combine(local, "restored-state"); using (var owned = new PrivateState(restored)) { File.Copy(result.BackupPath, Path.Combine(restored, "inventory.db"), false); }
                using (var recovery = new InventoryEngine(restored))
                {
                    Assert(recovery.ReadTaskHeader(retained).State == "Ready", "Backup opens through actual InventoryEngine in new private restore path");
                    using var recoveryDb = Open(restored); Assert(RowsFingerprint(recoveryDb, "tasks") == taskRows && RowsFingerprint(recoveryDb, "objects") == objectRows, "Recovered state retains same full facts");
                }
                var retainedInfo = e.GetStorageInfo();
                long actualRetainedBytes = Directory.GetFiles(Path.GetDirectoryName(result.BackupPath)!).Sum(p => new FileInfo(p).Length);
                Assert(retainedInfo.RetainedBackupDirectories == 1 && retainedInfo.RetainedBackupBytes == actualRetainedBytes && retainedInfo.RetainedBackupUnavailableEntries == 0, "Retained backup size and count included separately in storage info");
                Assert(result.AfterBytes < result.BeforeBytes && result.TasksPreserved == 1 && result.ObjectsPreserved == 2, "Compaction preserves retained task and evidence");
                Assert(!WindowsFacts.Within(result.BackupPath, state) && File.Exists(Path.Combine(Path.GetDirectoryName(result.BackupPath)!, "manifest.json")), "Private sibling backup and manifest retained");
                using (var copy = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = result.BackupPath, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString()))
                { copy.Open(); Assert(Scalar(copy, "SELECT COUNT(*) FROM tasks") == 1 && Scalar(copy, "SELECT COUNT(*) FROM objects") == 2, "Backup independently opens with consistent counts"); }
                Assert(Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(result.BackupPath))) == result.BackupSha256, "Backup SHA256 matches");
                bool locked = false; try { using var duplicate = new InventoryEngine(state); } catch (IOException) { locked = true; }
                Assert(locked, "PrivateState exclusive lock retained after compaction");
            }
            using (var e = new InventoryEngine(state, new ExplorerLimits(MaxStateBytes: 2097152))) { var id = e.CreateInventory(files); Wait(e, id); Assert(e.ReadTaskHeader(retained).State == "Ready", "Old task survives restart and post-compaction new inventory"); }
            string activeState = Path.Combine(local, "active-state"); using (var e = new InventoryEngine(activeState)) { }
            using (var db = Open(activeState)) { Exec(db, "INSERT INTO tasks(id,owner,root,identity,state,created,updated) VALUES('synthetic-active','none','none','none','Paused','old','old')"); }
            using (var e = new InventoryEngine(activeState))
            {
                using (var db = Open(activeState)) Exec(db, "UPDATE tasks SET state='Inventory'");
                Assert(!e.GetStorageInfo().CanCompact && e.GetStorageInfo().CompactionReason == "InventoryActive", "Inventory state disables compaction");
                Reject(() => e.CompactState(true), "InventoryActive");
            }
            string unknown = Path.Combine(local, "unknown-state"); using (var e = new InventoryEngine(unknown)) { }
            using (var db = Open(unknown)) Exec(db, "PRAGMA user_version=99"); Reject(() => new InventoryEngine(unknown), "UnknownDatabaseSchema");
            RealWorker(local);
            CheckpointFailure(local, files);
            Assert(sourceHash == Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(Path.Combine(files, "sample.txt")))), "Synthetic input unchanged");
            File.WriteAllText(Path.Combine(local, "result.json"), JsonSerializer.Serialize(new { Passed = true, Checks = checks, Fixture = local }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine("STORAGE PASS " + checks.Count + " checks; " + local); return 0;
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(local, "failure.txt"), ex.ToString()); Console.Error.WriteLine(ex); return 1; }
    }
}
