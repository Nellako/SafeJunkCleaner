using Microsoft.Data.Sqlite;

namespace SafeJunkCleaner.Explorer;

// MaxTasks=0 leaves history count unlimited; disk and per-inventory budgets still apply.
public sealed record ExplorerLimits(int MaxTasks = 0, int MaxObjectsPerTask = 0, long MaxStateBytes = 536870912, int PageSize = 64, bool PrioritizeLayouts = true);
public sealed partial class InventoryEngine : IDisposable
{
    private readonly PrivateState state;
    private readonly ScopePolicy policy;
    private ExplorerLimits limits;
    private readonly SqliteConnection db;
    private readonly object gate = new();
    private Task? worker;
    private CancellationTokenSource? stop;
    private string? active;
    private string stopState = "Paused";
    public InventoryEngine(string stateRoot, ExplorerLimits? limits = null)
    {
        this.limits = limits ?? new();
        if (this.limits.MaxTasks < 0 || this.limits.MaxObjectsPerTask < 0 || this.limits.MaxStateBytes < 1 || this.limits.PageSize is < 1 or > 64)
            throw new ArgumentOutOfRangeException(nameof(limits));
        state = new(stateRoot);
        try
        {
        policy = new(state.Root);
        db = new(new SqliteConnectionStringBuilder { DataSource = Path.Combine(state.Root, "inventory.db"), Pooling = false }.ToString());
        db.Open();
        db.CreateFunction<string?, string?, long>("sjc_contains", (value, filter) => filter == null || (value?.Contains(filter, StringComparison.OrdinalIgnoreCase) ?? false) ? 1L : 0L, isDeterministic: true);
        Exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-4096; PRAGMA wal_autocheckpoint=128; PRAGMA journal_size_limit=8388608;");
        var version = Convert.ToInt32(Scalar("PRAGMA user_version"));
        if (version is not (0 or 1 or 2 or 3 or 4)) throw new InvalidOperationException("UnknownDatabaseSchema");
        if (version < 4)
        {
            // All schema changes, including the full v1/v2/v3 -> v4 chain, commit together.
            using var tx = db.BeginTransaction();
            if (version == 0)
            {
                if (Convert.ToInt64(Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")) != 0) throw new InvalidOperationException("UnknownDatabase");
                Exec("""
                    CREATE TABLE tasks(id TEXT PRIMARY KEY,owner TEXT NOT NULL,root TEXT NOT NULL,identity TEXT NOT NULL,state TEXT NOT NULL,created TEXT NOT NULL,updated TEXT NOT NULL,reason TEXT,revision INTEGER NOT NULL DEFAULT 1,scan_mode TEXT NULL CHECK(scan_mode IN ('Selected','AllFixedDisks')));
                    CREATE TABLE objects(id INTEGER PRIMARY KEY AUTOINCREMENT,task TEXT NOT NULL,path TEXT NOT NULL,parent INTEGER,kind TEXT NOT NULL,identity TEXT,attributes INTEGER,links INTEGER,logical INTEGER,allocated INTEGER,modified TEXT,observed TEXT NOT NULL,coverage TEXT NOT NULL,reason TEXT,scan TEXT NOT NULL,protection TEXT NOT NULL,enumeration_complete INTEGER NULL, UNIQUE(task,path));
                    CREATE INDEX pending ON objects(task,scan,id);
                    CREATE INDEX children ON objects(task,parent,id);
                    CREATE INDEX largefiles ON objects(task,kind,logical DESC,id);
                    """);
            }
            else
            {
                // Legacy rows never acquire enumeration proof, a guessed mode or a fabricated batch.
                if (version == 1) Exec("ALTER TABLE objects ADD COLUMN enumeration_complete INTEGER NULL;");
                if (version is 1 or 2) Exec("ALTER TABLE tasks ADD COLUMN scan_mode TEXT NULL CHECK(scan_mode IN ('Selected','AllFixedDisks'));");
            }
            CreateBatchSchema();
            Exec("PRAGMA user_version=4");
            tx.Commit();
        }
        // Optional access path only: a near-quota legacy store must still open so
        // history and the explicit budget/recovery controls remain reachable.
        TryRepairObjectIndex();
        InterruptBatchesOnStartup();
        state.ValidateFiles();
        }
        catch
        {
            try { db?.Dispose(); } finally { state.Dispose(); }
            throw;
        }
    }
    private SqliteCommand Command(string sql, params object?[] values)
    {
        var cmd = db.CreateCommand(); cmd.CommandText = sql;
        for (int i = 0; i < values.Length; i++) cmd.Parameters.AddWithValue("@p" + i, values[i] ?? DBNull.Value);
        return cmd;
    }
    private void Exec(string sql, params object?[] values) { using var c = Command(sql, values); c.ExecuteNonQuery(); }
    private object? Scalar(string sql, params object?[] values) { using var c = Command(sql, values); return c.ExecuteScalar(); }
    private List<Dictionary<string, object?>> Rows(string sql, params object?[] values)
    {
        using var c = Command(sql, values); using var reader = c.ExecuteReader(); var result = new List<Dictionary<string, object?>>();
        long queryAllowance = Math.Max(64L * 1024 * 1024, Math.Min(4L * 1024 * 1024 * 1024, GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 8));
        while (reader.Read())
        {
            if (result.Count > 0 && (result.Count & 4095) == 0 && GC.GetTotalMemory(false) > queryAllowance)
                throw new InvalidOperationException("AnalysisMemoryPressure");
            var row = new Dictionary<string, object?>();
            for (int i = 0; i < reader.FieldCount; i++) row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            result.Add(row);
        }
        return result;
    }
    private void Owned(string id)
    {
        state.ValidateFiles();
        if (Scalar("SELECT owner FROM tasks WHERE id=@p0", id) as string != state.OwnerSid) throw new InvalidOperationException("TaskNotOwnedOrMissing");
    }
    private long StateBytes() => Directory.EnumerateFiles(state.Root).Sum(p => new FileInfo(p).Length);
    private void ReserveGeneration(string root)
    {
        // Reserve the root row, indexes, WAL frames and start/terminal metadata before
        // accepting a generation. A near-full store must not accept then overrun it.
        long reservation = checked(Convert.ToInt64(Scalar("PRAGMA page_size")) * 128L + 16L * System.Text.Encoding.UTF8.GetByteCount(root));
        if (reservation > limits.MaxStateBytes || StateBytes() > limits.MaxStateBytes - reservation)
            throw new InvalidOperationException("IndexQuotaExceededReleaseCompletedTask");
    }
    public string CreateInventory(string selectedPath) => CreateInventory(selectedPath, "Selected");
    public string CreateInventory(string selectedPath, string scanMode)
    {
        if (scanMode is not ("Selected" or "AllFixedDisks")) throw new InvalidOperationException("InvalidScanMode");
        lock (gate)
        {
            state.ValidateFiles();
            if (HasActiveBatch) throw new InvalidOperationException("BatchActive");
            AssertInventoryIdle();
            if ((limits.MaxTasks > 0 && Convert.ToInt64(Scalar("SELECT COUNT(*) FROM tasks")) >= limits.MaxTasks) || StateBytes() >= limits.MaxStateBytes) throw new InvalidOperationException("IndexQuotaExceededReleaseCompletedTask");
            var root = policy.Validate(selectedPath); var f = WindowsFacts.Read(root); var id = Guid.NewGuid().ToString("D");
            ReserveGeneration(root);
            using var tx = db.BeginTransaction();
            Exec("INSERT INTO tasks(id,owner,root,identity,state,created,updated,scan_mode) VALUES(@p0,@p1,@p2,@p3,'Paused',@p4,@p4,@p5)", id, state.OwnerSid, root, f.Identity, DateTime.UtcNow.ToString("O"), scanMode);
            Observe(id, root, null, f, "Directory", null); tx.Commit(); Start(id); return id;
        }
    }
    private SqliteCommand ObservationCommand()
    {
        var cmd = Command("""
            INSERT INTO objects(task,path,parent,kind,identity,attributes,links,logical,allocated,modified,observed,coverage,reason,scan,protection)
            VALUES(@p0,@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,@p9,@p10,@p11,@p12,@p13,@p14)
            ON CONFLICT(task,path) DO NOTHING
            """);
        for (int i = 0; i < 15; i++) cmd.Parameters.AddWithValue("@p" + i, DBNull.Value);
        cmd.Prepare();
        return cmd;
    }
    private int Observe(string task, string path, long? parent, FileFact? fact, string kind, string? reason)
    {
        using var cmd = ObservationCommand();
        return Observe(cmd, task, path, parent, fact, kind, reason);
    }
    private int Observe(SqliteCommand cmd, string task, string path, long? parent, FileFact? fact, string kind, string? reason)
    {
        object?[] values = [task, path, parent, kind, fact?.Identity, fact?.Attributes, fact?.Links,
            kind == "File" && reason == null ? fact?.LogicalBytes : null, kind == "File" && reason == null ? fact?.AllocatedBytes : null, fact?.ModifiedUtc, DateTime.UtcNow.ToString("O"),
            reason != null ? "NotCovered" : kind == "Directory" ? "Pending" : "Complete", reason,
            kind == "Directory" ? reason == null ? "Pending" : "Failed" : "Done", ScopePolicy.DisplayProtection(path)];
        for (int i = 0; i < values.Length; i++) cmd.Parameters[i].Value = values[i] ?? DBNull.Value;
        return cmd.ExecuteNonQuery();
    }
    private void Start(string id)
    {
        Owned(id);
        if (worker is { IsCompleted: false }) throw new InvalidOperationException("WorkerBusy");
        var status = Scalar("SELECT state FROM tasks WHERE id=@p0", id) as string;
        if (status != "Paused") throw new InvalidOperationException("StageMismatch");
        var r = Rows("SELECT root,identity FROM tasks WHERE id=@p0", id)[0];
        var root = policy.Validate((string)r["root"]!);
        using var guard = WindowsFacts.Guard(root, (string)r["identity"]!);
        using (var tx = db.BeginTransaction())
        {
            Exec("UPDATE tasks SET state='Inventory',reason=NULL,updated=@p1 WHERE id=@p0", id, DateTime.UtcNow.ToString("O"));
            SyncBatchTask(id, "Inventory", null); tx.Commit();
        }
        LaunchWorker(id);
    }
    private void LaunchWorker(string id)
    {
        ResetProgressGeneration();
        stop?.Dispose(); stop = new(); active = id; stopState = "Paused";
        var token = stop.Token;
        worker = Task.Run(() => Scan(id, token));
    }
    private const int ScanBatchObjects = 128;
    private const int ScanBatchMilliseconds = 25;
    private sealed record ScanObservation(string Path, FileFact? Fact, string Kind, string? Reason);
    private sealed class ScanQuotaException : Exception { }
    private sealed class ScanGenerationChangedException : Exception { }
    private static bool DirectoryFailure(Exception ex) => ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or InvalidOperationException;
    private ScanObservation ReadObservation(string entry)
    {
        string? reason = null; FileFact? fact = null; string kind = "Unknown";
        try
        {
            var full = WindowsFacts.Canonical(entry); reason = policy.Exclusion(full);
            if (reason == null)
            {
                fact = WindowsFacts.Read(full); kind = (fact.Attributes & 16) != 0 ? "Directory" : "File";
                if ((fact.Attributes & WindowsFacts.UnsafeAttributes) != 0) reason = "ReparseOfflineOrCloudPlaceholder";
            }
        }
        catch (Exception ex) when (DirectoryFailure(ex)) { reason = "MetadataUnavailable:" + ex.GetType().Name; }
        return new(entry, fact, kind, reason);
    }
    private void Scan(string task, CancellationToken token)
    {
        long observedCount = 0, revision = 0, pageBytes = 4096;
        SqliteCommand? insert = null;
        SqliteCommand? current = null, advance = null, completedDirectory = null;
        var pendingDirectories = new InventoryScanQueue(limits.PrioritizeLayouts);
        var elapsed = System.Diagnostics.Stopwatch.StartNew();
        long directorySelections = 0, prioritySelections = 0, fairSelections = 0, queueQueries = 0, batches = 0, committedObjects = 0;
        double metadataMilliseconds = 0, commitMilliseconds = 0;
        void PublishMetrics() => scanMetrics[task] = new(directorySelections, prioritySelections, fairSelections, queueQueries, batches, committedObjects, metadataMilliseconds, commitMilliseconds, elapsed.Elapsed.TotalMilliseconds);
        bool Current()
        {
            current ??= Command("SELECT COUNT(*) FROM tasks WHERE id=@p0 AND state='Inventory' AND revision=@p1", task, revision);
            current.Parameters[1].Value = revision;
            return Convert.ToInt64(current.ExecuteScalar()) == 1;
        }
        void CheckCurrent()
        {
            Owned(task); token.ThrowIfCancellationRequested();
            if (!Current()) throw new ScanGenerationChangedException();
        }
        void CheckQuota(long reservation)
        {
            // Force a fresh physical measurement for every batch, including its WAL.
            // Reservation covers rows, index/page splits, WAL frames and final status writes;
            // it is deliberately conservative, not a promise of exact SQLite file growth.
            if (reservation > limits.MaxStateBytes || StateBytes() > limits.MaxStateBytes - reservation || AvailableDriveBytes() < reservation + 256L * 1024 * 1024) throw new ScanQuotaException();
        }
        void CommitBatch(long directory, List<ScanObservation> batch, bool complete = false, string? failure = null)
        {
            int offset = 0;
            while (offset < batch.Count || complete || failure != null)
            {
                lock (gate)
                {
                    CheckCurrent();
                    int count = batch.Count - offset;
                    if (limits.MaxObjectsPerTask > 0)
                    {
                        if (count > 0 && observedCount >= limits.MaxObjectsPerTask) throw new ScanQuotaException();
                        count = (int)Math.Min(count, Math.Max(0L, (long)limits.MaxObjectsPerTask - observedCount));
                    }
                    long reservation = checked(pageBytes * (32L + 32L * count));
                    for (int i = offset; i < offset + count; i++)
                    {
                        var row = batch[i];
                        reservation = checked(reservation + 8L * System.Text.Encoding.UTF8.GetByteCount(task + row.Path + row.Fact?.Identity + row.Fact?.ModifiedUtc + row.Reason));
                    }
                    CheckQuota(reservation);
                    using var tx = db.BeginTransaction();
                    insert!.Transaction = tx;
                    try
                    {
                    var clock = System.Diagnostics.Stopwatch.StartNew();
                    int consumed = 0, inserted = 0;
                    var committedProgress = new List<ScanObservation>(count);
                    while (consumed < count && (consumed == 0 || clock.ElapsedMilliseconds < ScanBatchMilliseconds))
                    {
                        token.ThrowIfCancellationRequested();
                        var row = batch[offset + consumed];
                        int changed = Observe(insert!, task, row.Path, directory, row.Fact, row.Kind, row.Reason);
                        inserted += changed;
                        if (changed != 0) committedProgress.Add(row);
                        consumed++;
                    }
                    // Completion is committed only after ALL staged entries, never after a
                    // timed/count-limited prefix or an interrupted MoveNext.
                    bool terminal = offset + consumed == batch.Count && (complete || failure != null);
                    if (terminal)
                    {
                        // Cache prepared SQL only, never cache identity, quota or revision decisions.
                        if (failure == null)
                        {
                            completedDirectory ??= Command("UPDATE objects SET scan='Done',enumeration_complete=1,reason=NULL,coverage=CASE WHEN EXISTS(SELECT 1 FROM objects c WHERE c.task=@p1 AND c.parent=@p0 AND c.coverage='NotCovered') THEN 'Partial' ELSE 'Complete' END WHERE id=@p0 AND task=@p1 AND scan='Pending'", directory, task);
                            completedDirectory.Transaction = tx;
                            completedDirectory.Parameters[0].Value = directory;
                            if (completedDirectory.ExecuteNonQuery() != 1) throw new ScanGenerationChangedException();
                        }
                        else
                        {
                            using var update = Command("UPDATE objects SET scan='Failed',enumeration_complete=0,coverage='NotCovered',reason=@p2 WHERE id=@p0 AND task=@p1 AND scan='Pending'", directory, task, failure);
                            if (update.ExecuteNonQuery() != 1) throw new ScanGenerationChangedException();
                        }
                    }
                    // The gate prevents a local generation change; retain the CAS as a
                    // fail-closed contract for metadata collected while the gate was free.
                    token.ThrowIfCancellationRequested();
                    advance ??= Command("UPDATE tasks SET revision=revision+1,updated=@p2 WHERE id=@p0 AND state='Inventory' AND revision=@p1", task, revision, DateTime.UtcNow.ToString("O"));
                    advance.Transaction = tx;
                    advance.Parameters[1].Value = revision;
                    advance.Parameters[2].Value = DateTime.UtcNow.ToString("O");
                    if (advance.ExecuteNonQuery() != 1) throw new ScanGenerationChangedException();
                    CheckQuota(reservation); // Overflow throws before Commit; disposal rolls back the whole batch.
                    token.ThrowIfCancellationRequested();
                    tx.Commit();
                    observedCount += inserted; revision++; batches++; committedObjects += inserted;
                    try { AddCommittedProgress(task, revision, committedProgress, terminal, failure != null); }
                    catch { InvalidateProgress(task); } // Committed SQL remains authoritative; rebuild display metadata on demand.
                    for (int i = offset; i < offset + consumed; i++)
                    {
                        var row = batch[i];
                        if (row.Kind != "Directory" || row.Reason != null || row.Fact == null) continue;
                        long childId = Convert.ToInt64(Scalar("SELECT id FROM objects WHERE task=@p0 AND path=@p1 AND scan='Pending'", task, row.Path));
                        pendingDirectories.Add(new(childId, row.Path, row.Fact.Identity));
                    }
                    offset += consumed; commitMilliseconds += clock.Elapsed.TotalMilliseconds; PublishMetrics();
                    if (terminal) { complete = false; failure = null; }
                    }
                    finally
                    {
                        insert.Transaction = null;
                        if (advance != null) advance.Transaction = null;
                        if (completedDirectory != null) completedDirectory.Transaction = null;
                    }
                }
                // Release the gate between timed transaction prefixes, even for a huge directory.
            }
            batch.Clear();
        }
        void FinishCurrent(string status, string? reason)
        {
            lock (gate)
            {
                Owned(task);
                if (!Current()) return;
                if (token.IsCancellationRequested) { status = stopState; reason = "Explicit" + stopState; }
                using var tx = db.BeginTransaction();
                Finish(task, status, reason); tx.Commit(); revision++; PublishMetrics();
            }
        }
        try
        {
            lock (gate)
            {
                Owned(task);
                var value = Scalar("SELECT revision FROM tasks WHERE id=@p0 AND state='Inventory'", task);
                if (value == null) return;
                revision = Convert.ToInt64(value);
                observedCount = Convert.ToInt64(Scalar("SELECT COUNT(*) FROM objects WHERE task=@p0", task));
                pageBytes = Convert.ToInt64(Scalar("PRAGMA page_size"));
                insert = ObservationCommand();
                foreach (var row in Rows("SELECT id,path,identity FROM objects WHERE task=@p0 AND scan='Pending' ORDER BY id", task))
                    pendingDirectories.Add(new((long)row["id"]!, (string)row["path"]!, (string)row["identity"]!));
                queueQueries++; PublishMetrics();
            }
            while (true)
            {
                Dictionary<string, object?>? next;
                lock (gate)
                {
                    CheckCurrent();
                    var queued = pendingDirectories.Take();
                    if (queued.Directory == null)
                    {
                        var remaining = Rows("SELECT id,path,identity FROM objects WHERE task=@p0 AND scan='Pending' ORDER BY id", task); queueQueries++;
                        foreach (var row in remaining) pendingDirectories.Add(new((long)row["id"]!, (string)row["path"]!, (string)row["identity"]!));
                        queued = pendingDirectories.Take();
                    }
                    next = queued.Directory == null ? null : new() { ["id"] = queued.Directory.Id, ["path"] = queued.Directory.Path, ["identity"] = queued.Directory.Identity };
                    if (next != null)
                    {
                        directorySelections++;
                        if (queued.Preferred) prioritySelections++; else fairSelections++;
                    }
                    PublishMetrics();
                    if (next == null)
                    {
                        var partial = Convert.ToInt64(Scalar("SELECT COUNT(*) FROM objects WHERE task=@p0 AND coverage!='Complete'", task)) > 0;
                        FinishCurrent(partial ? "Partial" : "Ready", partial ? "SkippedOrUncoveredObjects" : null); return;
                    }
                }
                long id = (long)next["id"]!; string path = (string)next["path"]!;
                IDisposable? guard = null; IEnumerator<string>? entries = null; string? failure = null;
                try
                {
                    guard = WindowsFacts.Guard(path, (string)next["identity"]!);
                    entries = Directory.EnumerateFileSystemEntries(path).GetEnumerator();
                }
                catch (Exception ex) when (DirectoryFailure(ex)) { failure = "DirectoryUnavailable:" + ex.GetType().Name; }
                using (guard)
                using (entries)
                {
                    var batch = new List<ScanObservation>(ScanBatchObjects);
                    var clock = System.Diagnostics.Stopwatch.StartNew();
                    bool complete = false;
                    while (failure == null)
                    {
                        token.ThrowIfCancellationRequested();
                        string? entry = null;
                        try
                        {
                            if (!entries!.MoveNext()) complete = true;
                            else entry = entries.Current;
                        }
                        catch (Exception ex) when (DirectoryFailure(ex)) { failure = "DirectoryUnavailable:" + ex.GetType().Name; }
                        if (complete || failure != null) break;
                        var metadataClock = System.Diagnostics.Stopwatch.StartNew();
                        batch.Add(ReadObservation(entry!)); // Metadata/ACL policy checks run outside gate, under directory Guard.
                        metadataMilliseconds += metadataClock.Elapsed.TotalMilliseconds;
                        if (batch.Count >= ScanBatchObjects || clock.ElapsedMilliseconds >= ScanBatchMilliseconds)
                        {
                            CommitBatch(id, batch); clock.Restart();
                        }
                    }
                    token.ThrowIfCancellationRequested();
                    CommitBatch(id, batch, complete, failure);
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { FinishCurrent(stopState, "Explicit" + stopState); }
        catch (ScanQuotaException) { FinishCurrent("Partial", "IndexQuotaExceeded"); }
        catch (ScanGenerationChangedException) { /* Never overwrite another task state/evidence generation. */ }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Inventory failed: " + ex.GetType().Name + " " + ex.Message);
            FinishCurrent("Failed", ex.GetType().Name);
        }
        finally { lock (gate) { PublishMetrics(); insert?.Dispose(); current?.Dispose(); advance?.Dispose(); completedDirectory?.Dispose(); } }
    }
    private void Finish(string task, string status, string? reason)
    {
        // Final recursive coverage propagation is SQL-authoritative, not an accumulator delta.
        InvalidateProgress(task);
        if (status is "Ready" or "Partial")
            Exec("""
                WITH RECURSIVE incomplete(id,parent) AS (
                    SELECT id,parent FROM objects WHERE task=@p0 AND coverage IN ('NotCovered','Partial','Pending')
                    UNION SELECT p.id,p.parent FROM objects p JOIN incomplete c ON p.id=c.parent WHERE p.task=@p0)
                UPDATE objects SET coverage='Partial' WHERE task=@p0 AND kind='Directory' AND coverage='Complete' AND id IN (SELECT id FROM incomplete)
                """, task);
        Exec("UPDATE tasks SET state=@p1,reason=@p2,updated=@p3,revision=revision+1 WHERE id=@p0", task, status, reason, DateTime.UtcNow.ToString("O"));
        SyncBatchTask(task, status, reason);
    }
    public object GetProgress(string task)
    {
        lock (gate)
        {
            Owned(task);
            var header = Rows("SELECT id AS TaskId,root AS RootPath,substr(root,1,3) AS Drive,COALESCE(scan_mode,'Legacy') AS ScanMode,state AS State,reason AS Reason,revision AS EvidenceRevision,created AS CreatedUtc,updated AS UpdatedUtc FROM tasks WHERE id=@p0", task)[0];
            return new { Task = header,
                Coverage = ReadProgressCoverage(task, (string)header["State"]!, (long)header["EvidenceRevision"]!),
                Metrics = ReadScanMetrics(task),
                SkippedReasons = ReadCoverageReasons(task, (string)header["State"]!, (long)header["EvidenceRevision"]!),
                Semantics = "Observed metadata only; null means unavailable; not reclaimable bytes; progress totals deduplicate FileIdentity; no snapshot guarantee" };
        }
    }
    public object QueryEvidence(string task, long after, int size, long? parent)
    {
        lock (gate)
        {
            Owned(task); Page(after, size);
            var rows = Rows("SELECT id AS EvidenceId,parent AS ParentId,path AS Path,kind AS Kind,identity AS FileIdentity,attributes AS Attributes,links AS LinkCount,logical AS LogicalBytes,allocated AS AllocatedBytes,modified AS ModifiedUtc,observed AS ObservedUtc,coverage AS Coverage,reason AS SkippedReason,protection AS Protection,'metadata-v1' AS DetectorVersion FROM objects WHERE task=@p0 AND id>@p1 AND (@p2 IS NULL OR parent=@p2) ORDER BY id LIMIT @p3", task, after, parent, size);
            return new { Items = rows, NextAfter = rows.Count == size ? (long?)rows[^1]["EvidenceId"] : null };
        }
    }
    public object QueryGroups(string task, long after, int size)
    {
        lock (gate)
        {
            Owned(task); Page(after, size);
            var rows = Rows("""
                WITH page AS MATERIALIZED (
                    SELECT id,path,coverage,reason,protection FROM objects
                    WHERE task=@p0 AND kind='Directory' AND id>@p1 ORDER BY id LIMIT @p2
                ), totals AS (
                    SELECT page.id,COUNT(c.id) AS children,SUM(c.logical) AS logical,SUM(c.allocated) AS allocated
                    FROM page LEFT JOIN objects c ON c.task=@p0 AND c.parent=page.id GROUP BY page.id
                )
                SELECT o.id AS GroupId,o.path AS Path,o.coverage AS Coverage,o.reason AS Reason,
                totals.children AS ObservedDirectChildren,totals.logical AS DirectLogicalBytes,totals.allocated AS DirectAllocatedBytes,
                'DirectoryLayout' AS FactType,'Undetermined' AS Classification,'None' AS SuggestedAction,
                o.protection AS Protection FROM page o JOIN totals ON totals.id=o.id ORDER BY o.id
                """, task, after, size);
            return new { Items = rows, NextAfter = rows.Count == size ? (long?)rows[^1]["GroupId"] : null, Semantics = "Direct observed children only; direct byte sums may repeat hard links; null means unavailable; no recursive totals; names are not cache evidence" };
        }
    }
    private void Page(long after, int size) { if (after < 0 || size < 1 || size > limits.PageSize) throw new InvalidOperationException("InvalidPage"); }
    public void Resume(string task)
    {
        lock (gate)
        {
            Owned(task); AssertTaskNotBatchResume(task);
            if (HasActiveBatch) throw new InvalidOperationException("BatchActive");
            ResumeCore(task);
        }
    }
    private void ResumeCore(string task)
    {
        AssertInventoryIdle();
        if (Scalar("SELECT state FROM tasks WHERE id=@p0", task) as string != "Paused") throw new InvalidOperationException("StageMismatch");
        var scope = Rows("SELECT root,identity FROM tasks WHERE id=@p0", task)[0];
        var root = policy.Validate((string)scope["root"]!);
        using var guard = WindowsFacts.Guard(root, (string)scope["identity"]!);
        // Resume rebuilds the whole observed generation, retaining the original task identity.
        ReserveGeneration(root);
        using (var tx = db.BeginTransaction())
        {
            Exec("DELETE FROM objects WHERE task=@p0", task);
            Observe(task, root, null, WindowsFacts.Read(root), "Directory", null);
            Exec("UPDATE tasks SET revision=revision+1,state='Inventory',reason=NULL,updated=@p1 WHERE id=@p0", task, DateTime.UtcNow.ToString("O"));
            SyncBatchTask(task, "Inventory", null);
            tx.Commit();
        }
        LaunchWorker(task);
    }
    public void Pause(string task) => Stop(task, false);
    public void Cancel(string task) => Stop(task, true);
    private void Stop(string task, bool cancel)
    {
        lock (gate)
        {
            Owned(task); var status = Scalar("SELECT state FROM tasks WHERE id=@p0", task) as string;
            if (status == "Inventory" && active == task && worker is { IsCompleted: false } && stop is { IsCancellationRequested: false })
            {
                using (var tx = db.BeginTransaction()) { StopBoundBatchFromLegacy(task, cancel); tx.Commit(); }
                stopState = cancel ? "Cancelled" : "Paused"; stop.Cancel();
            }
            else if (cancel && status == "Paused")
            {
                using var tx = db.BeginTransaction(); StopBoundBatchFromLegacy(task, true); Finish(task, "Cancelled", "ExplicitCancelled"); tx.Commit();
            }
            else throw new InvalidOperationException("StageMismatch");
        }
    }
    public object ListTasks(string? afterTaskId, int size) => ListTasks(afterTaskId, size, null);
    public object ListTasks(string? afterTaskId, int size, string? pathFilter)
    {
        lock (gate)
        {
            state.ValidateFiles();
            if (size is < 1 or > 64 || afterTaskId != null && (!Guid.TryParseExact(afterTaskId, "D", out var cursor) || cursor == Guid.Empty)) throw new InvalidOperationException("InvalidPage");
            if (pathFilter is { Length: > 1800 } || pathFilter?.Any(c => c < 32) == true) throw new InvalidOperationException("InvalidPathFilter");
            var items = Rows("""
                SELECT t.id AS TaskId,t.root AS RootPath,substr(t.root,1,3) AS Drive,COALESCE(t.scan_mode,'Legacy') AS ScanMode,
                t.state AS State,t.reason AS Reason,t.revision AS EvidenceRevision,t.created AS CreatedUtc,t.updated AS UpdatedUtc,
                (SELECT COUNT(*) FROM objects o WHERE o.task=t.id) AS ObservedObjects,
                (SELECT COUNT(*) FROM objects o WHERE o.task=t.id AND o.coverage='NotCovered') AS SkippedObjects,
                (SELECT SUM(logical) FROM (SELECT MAX(logical) AS logical FROM objects o WHERE o.task=t.id AND o.kind='File' AND o.logical IS NOT NULL GROUP BY o.identity)) AS ObservedLogicalBytes
                FROM tasks t WHERE t.owner=@p0 AND (@p1 IS NULL OR t.id>@p1)
                AND sjc_contains(t.root,@p3)=1 ORDER BY t.id LIMIT @p2
                """, state.OwnerSid, afterTaskId, size, pathFilter);
            return new { Items = items, NextAfterTaskId = items.Count == size ? items[^1]["TaskId"] : null };
        }
    }
    public void ReleaseTask(string task)
    {
        lock (gate)
        {
            Owned(task); var status = Scalar("SELECT state FROM tasks WHERE id=@p0", task) as string;
            if (status is not ("Ready" or "Partial" or "Cancelled" or "Failed") || active == task && worker is { IsCompleted: false }) throw new InvalidOperationException("TaskActiveOrNotCompleted");
            if (activeBatch != null && Scalar("SELECT batch FROM batch_entries WHERE task=@p0", task) as string == activeBatch) throw new InvalidOperationException("BatchActive");
            using var tx = db.BeginTransaction();
            SyncBatchTask(task, "Released", "TaskReleased");
            Exec("DELETE FROM objects WHERE task=@p0", task); Exec("DELETE FROM tasks WHERE id=@p0", task); tx.Commit();
            InvalidateProgress(task);
            Exec("PRAGMA wal_checkpoint(TRUNCATE)"); spaceCache.Remove(task); scanMetrics.Remove(task);
        }
    }
    public void Dispose()
    {
        lock (gate) { if (stop?.IsCancellationRequested != true) stopState = "Paused"; stop?.Cancel(); }
        worker?.GetAwaiter().GetResult(); stop?.Dispose(); db.Dispose(); state.Dispose();
    }
}
