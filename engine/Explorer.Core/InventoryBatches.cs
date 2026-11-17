namespace SafeJunkCleaner.Explorer;

public sealed record BatchSummary(string BatchId, string ScanMode, string State, string? Reason, long Revision,
    string CreatedUtc, string UpdatedUtc, int EntryCount);
public sealed record BatchEntrySnapshot(int EntryIndex, string RootPath, string? TaskId, string State, string? Reason);
public sealed record BatchSnapshot(string BatchId, string ScanMode, string State, string? Reason, long Revision,
    string CreatedUtc, string UpdatedUtc, int EntryCount, IReadOnlyList<BatchEntrySnapshot> Entries, bool CanContinue);
public sealed record BatchPage(IReadOnlyList<BatchSummary> Items, string? NextAfterBatchId);
public sealed record BatchEntryStartResult(string BatchId, long Revision, int EntryIndex, string? TaskId, string State, string? Reason);

public sealed partial class InventoryEngine
{
    // Neither the active batch nor permission to rebuild a paused task is persisted.
    private string? activeBatch;
    private bool batchRunIntent;
    private bool HasActiveBatch => activeBatch != null;
    private void CreateBatchSchema() => Exec("""
        CREATE TABLE batches(id TEXT PRIMARY KEY,owner TEXT NOT NULL,scan_mode TEXT NOT NULL CHECK(scan_mode='AllFixedDisks'),
            state TEXT NOT NULL CHECK(state IN ('Running','Paused','Cancelled','Stopped','Interrupted','Completed')),
            reason TEXT,revision INTEGER NOT NULL CHECK(revision>0),created TEXT NOT NULL,updated TEXT NOT NULL);
        CREATE TABLE batch_entries(batch TEXT NOT NULL,entry_index INTEGER NOT NULL CHECK(entry_index>=0 AND entry_index<26),
            root TEXT NOT NULL,identity TEXT,task TEXT UNIQUE,state TEXT NOT NULL CHECK(state IN ('Pending','Inventory','Paused','Ready','Partial','Cancelled','Failed','Released')),
            reason TEXT,created TEXT NOT NULL,updated TEXT NOT NULL,PRIMARY KEY(batch,entry_index),UNIQUE(batch,root COLLATE NOCASE),
            CHECK(state!='Pending' OR (identity IS NOT NULL AND task IS NULL)),CHECK(state!='Released' OR task IS NOT NULL));
        """);
    private void InterruptBatchesOnStartup()
    {
        using var tx = db.BeginTransaction();
        string now = DateTime.UtcNow.ToString("O");
        Exec("UPDATE tasks SET state='Paused',reason='ProcessInterrupted',revision=revision+1,updated=@p0 WHERE state='Inventory'", now);
        Exec("""
            UPDATE batch_entries SET state=(SELECT state FROM tasks WHERE tasks.id=batch_entries.task),
                reason=(SELECT reason FROM tasks WHERE tasks.id=batch_entries.task),updated=@p0
            WHERE task IS NOT NULL AND state!='Released' AND EXISTS(SELECT 1 FROM tasks WHERE tasks.id=batch_entries.task)
                AND (state!=(SELECT state FROM tasks WHERE tasks.id=batch_entries.task) OR reason IS NOT (SELECT reason FROM tasks WHERE tasks.id=batch_entries.task));
            UPDATE batches SET state='Interrupted',reason='ProcessInterrupted',revision=revision+1,updated=@p0 WHERE state IN ('Running','Paused');
            """, now);
        tx.Commit();
    }
    private static string BatchId(string value)
    {
        if (!Guid.TryParseExact(value, "D", out var id) || id == Guid.Empty) throw new InvalidOperationException("InvalidBatchId");
        return id.ToString("D");
    }
    private Dictionary<string, object?> OwnedBatch(string id)
    {
        state.ValidateFiles();
        var rows = Rows("SELECT * FROM batches WHERE id=@p0 AND owner=@p1", id, state.OwnerSid);
        if (rows.Count != 1) throw new InvalidOperationException("BatchNotOwnedOrMissing");
        return rows[0];
    }
    private Dictionary<string, object?> CurrentBatch(string id, long expectedRevision)
    {
        var row = OwnedBatch(id);
        if (expectedRevision < 1 || (long)row["revision"]! != expectedRevision) throw new InvalidOperationException("BatchRevisionChanged");
        return row;
    }
    private void AssertInventoryIdle()
    {
        if (worker is { IsCompleted: false } || Convert.ToInt64(Scalar("SELECT COUNT(*) FROM tasks WHERE state='Inventory'")) != 0)
            throw new InvalidOperationException("WorkerBusy");
    }
    private void ReserveBatchMetadata(IEnumerable<string> roots)
    {
        long reservation = checked(Convert.ToInt64(Scalar("PRAGMA page_size")) * 128L);
        foreach (var root in roots) reservation = checked(reservation + 65536L + 32L * System.Text.Encoding.UTF8.GetByteCount(root));
        if (reservation > limits.MaxStateBytes || StateBytes() > limits.MaxStateBytes - reservation)
            throw new InvalidOperationException("IndexQuotaExceededReleaseCompletedTask");
    }
    private BatchSnapshot Snapshot(Dictionary<string, object?> row)
    {
        string id = (string)row["id"]!;
        var entries = Rows("SELECT entry_index,root,task,state,reason FROM batch_entries WHERE batch=@p0 ORDER BY entry_index", id)
            .Select(e => new BatchEntrySnapshot(checked((int)(long)e["entry_index"]!), (string)e["root"]!, (string?)e["task"], (string)e["state"]!, (string?)e["reason"])).ToArray();
        string status = (string)row["state"]!;
        return new(id, "AllFixedDisks", status, (string?)row["reason"], (long)row["revision"]!, (string)row["created"]!, (string)row["updated"]!, entries.Length, entries,
            status != "Running" && entries.Any(e => e.State is "Pending" or "Paused"));
    }
    public BatchSnapshot CreateBatch(string batchId, string[] roots)
    {
        batchId = BatchId(batchId);
        if (roots == null || roots.Length is < 1 or > 26) throw new InvalidOperationException("InvalidBatchRoots");
        // Validate the entire input before any observation or write. Keep the original order.
        var normalized = new List<string>(); var unique = new HashSet<string>(StringComparer.OrdinalIgnoreCase); long inputBytes = 0;
        foreach (var input in roots)
        {
            if (input == null) throw new InvalidOperationException("InvalidBatchRoots");
            inputBytes = checked(inputBytes + System.Text.Encoding.UTF8.GetByteCount(input));
            if (inputBytes > 24000 || input.IndexOfAny(['*', '?', '<', '>', '"', '|']) >= 0) throw new InvalidOperationException("InvalidBatchRoots");
            string root = WindowsFacts.Canonical(input);
            if (unique.Add(root)) normalized.Add(root);
        }
        lock (gate)
        {
            state.ValidateFiles(); AssertInventoryIdle();
            if (HasActiveBatch) throw new InvalidOperationException("BatchActive");
            if (Scalar("SELECT id FROM batches WHERE id=@p0", batchId) != null) throw new InvalidOperationException("BatchAlreadyExists");
            var snapshots = new List<(string Root, string? Identity, string? Reason)>();
            foreach (var root in normalized)
            {
                WindowsFacts.LocalVolume(root);
                if (policy.Exclusion(root) is string excluded) throw new InvalidOperationException(excluded);
                try
                {
                    using var guard = WindowsFacts.Guard(root);
                    var fact = WindowsFacts.Read(root);
                    snapshots.Add((root, fact.Identity, null));
                }
                catch (Exception ex) when (DirectoryFailure(ex)) { snapshots.Add((root, null, "SnapshotRootUnavailable:" + ex.GetType().Name)); }
            }
            ReserveBatchMetadata(normalized);
            using var tx = db.BeginTransaction();
            string now = DateTime.UtcNow.ToString("O");
            bool runnable = snapshots.Any(item => item.Identity != null);
            Exec("INSERT INTO batches(id,owner,scan_mode,state,reason,revision,created,updated) VALUES(@p0,@p1,'AllFixedDisks',@p2,@p3,1,@p4,@p4)",
                batchId, state.OwnerSid, runnable ? "Running" : "Completed", runnable ? null : "NoAvailableBatchRoots", now);
            for (int i = 0; i < snapshots.Count; i++)
            {
                var item = snapshots[i];
                Exec("INSERT INTO batch_entries(batch,entry_index,root,identity,state,reason,created,updated) VALUES(@p0,@p1,@p2,@p3,@p4,@p5,@p6,@p6)",
                    batchId, i, item.Root, item.Identity, item.Reason == null ? "Pending" : "Failed", item.Reason, now);
            }
            tx.Commit();
            if (runnable) { activeBatch = batchId; batchRunIntent = true; }
            return Snapshot(OwnedBatch(batchId));
        }
    }
    public BatchPage ListBatches(string? afterBatchId, int pageSize)
    {
        if (pageSize is < 1 or > 64) throw new InvalidOperationException("InvalidPage");
        if (afterBatchId != null) afterBatchId = BatchId(afterBatchId);
        lock (gate)
        {
            state.ValidateFiles();
            var items = Rows("""
                SELECT b.*,(SELECT COUNT(*) FROM batch_entries e WHERE e.batch=b.id) AS entry_count FROM batches b
                WHERE owner=@p0 AND (@p1 IS NULL OR id>@p1) ORDER BY id LIMIT @p2
                """, state.OwnerSid, afterBatchId, pageSize + 1)
                .Select(r => new BatchSummary((string)r["id"]!, "AllFixedDisks", (string)r["state"]!, (string?)r["reason"], (long)r["revision"]!,
                    (string)r["created"]!, (string)r["updated"]!, checked((int)(long)r["entry_count"]!))).ToArray();
            var page = items.Take(pageSize).ToArray();
            return new(page, items.Length > pageSize ? page[^1].BatchId : null);
        }
    }
    public BatchSnapshot GetBatch(string batchId)
    {
        batchId = BatchId(batchId);
        lock (gate) return Snapshot(OwnedBatch(batchId));
    }
    public BatchSnapshot ContinueBatch(string batchId, long expectedRevision, bool confirmed)
    {
        batchId = BatchId(batchId);
        if (!confirmed) throw new InvalidOperationException("ExplicitBatchContinuationRequired");
        lock (gate)
        {
            var current = CurrentBatch(batchId, expectedRevision); AssertInventoryIdle();
            if (HasActiveBatch && activeBatch != batchId) throw new InvalidOperationException("BatchActive");
            if ((string)current["state"]! == "Running") throw new InvalidOperationException("BatchStageMismatch");
            if (Convert.ToInt64(Scalar("SELECT COUNT(*) FROM batch_entries WHERE batch=@p0 AND state IN ('Pending','Paused')", batchId)) == 0)
                throw new InvalidOperationException("BatchNothingToContinue");
            ReserveBatchMetadata([]);
            using var tx = db.BeginTransaction();
            AdvanceBatch(batchId, "Running", "ExplicitContinue"); tx.Commit();
            activeBatch = batchId; batchRunIntent = true;
            return Snapshot(OwnedBatch(batchId));
        }
    }
    private void AdvanceBatch(string id, string status, string? reason) => Exec("UPDATE batches SET state=@p1,reason=@p2,revision=revision+1,updated=@p3 WHERE id=@p0", id, status, reason, DateTime.UtcNow.ToString("O"));
    // Called inside the same SQL transaction as the corresponding task state transition.
    private void SyncBatchTask(string task, string status, string? reason)
    {
        var batch = Scalar("SELECT batch FROM batch_entries WHERE task=@p0 AND state!='Released'", task) as string;
        if (batch == null) return;
        Exec("UPDATE batch_entries SET state=@p1,reason=@p2,updated=@p3 WHERE task=@p0 AND state!='Released'", task, status, reason, DateTime.UtcNow.ToString("O"));
        bool running = Scalar("SELECT state FROM batches WHERE id=@p0", batch) as string == "Running";
        if (running && status is "Paused" or "Cancelled")
        {
            AdvanceBatch(batch, status, "Task" + status); batchRunIntent = false;
            if (status == "Cancelled") activeBatch = null;
        }
            else if (running && (reason == "IndexQuotaExceeded" || status == "Failed"))
            {
                AdvanceBatch(batch, "Stopped", reason ?? "InventoryFailed");
                if (activeBatch == batch) { activeBatch = null; batchRunIntent = false; }
            }
            else if (running && Convert.ToInt64(Scalar("SELECT COUNT(*) FROM batch_entries WHERE batch=@p0 AND state IN ('Pending','Paused','Inventory')", batch)) == 0)

        {
            AdvanceBatch(batch, "Completed", null);
            if (activeBatch == batch) { activeBatch = null; batchRunIntent = false; }
        }
        else Exec("UPDATE batches SET revision=revision+1,updated=@p1 WHERE id=@p0", batch, DateTime.UtcNow.ToString("O"));
    }
    public BatchEntryStartResult StartBatchEntry(string batchId, int entryIndex, long expectedRevision)
    {
        batchId = BatchId(batchId);
        lock (gate)
        {
            var batch = CurrentBatch(batchId, expectedRevision);
            if (activeBatch != batchId || !batchRunIntent) throw new InvalidOperationException("BatchContinuationRequired");
            if ((string)batch["state"]! != "Running") throw new InvalidOperationException("BatchStageMismatch");
            AssertInventoryIdle();
            var entries = Rows("SELECT * FROM batch_entries WHERE batch=@p0 AND state IN ('Pending','Paused') ORDER BY entry_index LIMIT 1", batchId);
            if (entries.Count == 0) throw new InvalidOperationException("BatchNothingToStart");
            var entry = entries[0];
            if (entryIndex < 0 || (long)entry["entry_index"]! != entryIndex) throw new InvalidOperationException("BatchEntryOutOfOrder");
            string root = (string)entry["root"]!;
            IDisposable guard;
            try
            {
                policy.Validate(root); guard = WindowsFacts.Guard(root, (string)entry["identity"]!);
            }
            catch (Exception ex) when (DirectoryFailure(ex))
            {
                using var tx = db.BeginTransaction();
                string reason = "SnapshotRootChangedOrUnavailable:" + ex.GetType().Name;
                if (entry["task"] is string bound) Finish(bound, "Failed", reason);
                else
                {
                    Exec("UPDATE batch_entries SET state='Failed',reason=@p2,updated=@p3 WHERE batch=@p0 AND entry_index=@p1", batchId, entryIndex, reason, DateTime.UtcNow.ToString("O"));
                    AdvanceBatch(batchId, "Stopped", reason);
                }
                // Identity failure is not an authorization to advance to another disk.
                if (Scalar("SELECT state FROM batches WHERE id=@p0", batchId) as string != "Stopped") AdvanceBatch(batchId, "Stopped", reason);
                tx.Commit(); activeBatch = null; batchRunIntent = false;
                throw new InvalidOperationException("SnapshotRootChangedOrUnavailable");
            }
            using (guard)
            {
                string task;
                if (entry["task"] is string bound)
                {
                    Owned(bound);
                    if ((string)entry["state"]! != "Paused" || Scalar("SELECT state FROM tasks WHERE id=@p0", bound) as string != "Paused") throw new InvalidOperationException("BatchTaskStateChanged");
                    ResumeCore(bound); task = bound;
                }
                else
                {
                    if ((string)entry["state"]! != "Pending") throw new InvalidOperationException("BatchEntryAlreadyStarted");
                    if (limits.MaxTasks > 0 && Convert.ToInt64(Scalar("SELECT COUNT(*) FROM tasks")) >= limits.MaxTasks) throw new InvalidOperationException("IndexQuotaExceededReleaseCompletedTask");
                    ReserveGeneration(root); ReserveBatchMetadata([]);
                    var fact = WindowsFacts.Read(root);
                    task = Guid.NewGuid().ToString("D"); string now = DateTime.UtcNow.ToString("O");
                    using var tx = db.BeginTransaction();
                    Exec("INSERT INTO tasks(id,owner,root,identity,state,created,updated,scan_mode) VALUES(@p0,@p1,@p2,@p3,'Inventory',@p4,@p4,'AllFixedDisks')", task, state.OwnerSid, root, fact.Identity, now);
                    Observe(task, root, null, fact, "Directory", null);
                    Exec("UPDATE batch_entries SET task=@p2,state='Inventory',reason=NULL,updated=@p3 WHERE batch=@p0 AND entry_index=@p1 AND task IS NULL AND state='Pending'", batchId, entryIndex, task, now);
                    AdvanceBatch(batchId, "Running", null);
                    tx.Commit();
                    LaunchWorker(task);
                }
                return EntryStartResult(batchId, entryIndex);
            }
        }
    }
    private BatchEntryStartResult EntryStartResult(string batch, int index)
    {
        var entry = Rows("SELECT task,state,reason FROM batch_entries WHERE batch=@p0 AND entry_index=@p1", batch, index)[0];
        return new(batch, Convert.ToInt64(Scalar("SELECT revision FROM batches WHERE id=@p0", batch)), index, (string?)entry["task"], (string)entry["state"]!, (string?)entry["reason"]);
    }
    public BatchSnapshot PauseBatch(string batchId, long expectedRevision) => ControlBatch(batchId, expectedRevision, "Paused");
    public BatchSnapshot CancelBatch(string batchId, long expectedRevision) => ControlBatch(batchId, expectedRevision, "Cancelled");
    public BatchSnapshot StopBatch(string batchId, long expectedRevision) => ControlBatch(batchId, expectedRevision, "Stopped");
    private BatchSnapshot ControlBatch(string batchId, long expectedRevision, string target)
    {
        batchId = BatchId(batchId);
        lock (gate)
        {
            var batch = CurrentBatch(batchId, expectedRevision);
            if (HasActiveBatch && activeBatch != batchId) throw new InvalidOperationException("BatchActive");
            string status = (string)batch["state"]!;
            if (status == "Completed" || target == "Paused" && status != "Running" || target == status) throw new InvalidOperationException("BatchStageMismatch");
            var current = Rows("SELECT task,state FROM batch_entries WHERE batch=@p0 AND state IN ('Inventory','Paused') ORDER BY entry_index", batchId);
            if (current.Count > 1) throw new InvalidOperationException("BatchTaskStateChanged");
            string? task = current.Count == 1 ? current[0]["task"] as string : null;
            string? taskState = task == null ? null : Scalar("SELECT state FROM tasks WHERE id=@p0", task) as string;
            if (current.Count == 1 && (task == null || taskState != (string)current[0]["state"]!)) throw new InvalidOperationException("BatchTaskStateChanged");
            if (taskState == "Inventory" && (active != task || worker is not { IsCompleted: false } || stop == null || stop.IsCancellationRequested)) throw new InvalidOperationException("BatchTaskControlRace");
            // Admission reserves terminal metadata; withdrawing intent must not require another admission budget.
            using var tx = db.BeginTransaction();
            AdvanceBatch(batchId, target, "Explicit" + target);
            if (target == "Cancelled" && taskState == "Paused") Finish(task!, "Cancelled", "ExplicitCancelled");
            tx.Commit();
            batchRunIntent = false;
            if (target == "Paused") activeBatch = batchId; else if (activeBatch == batchId) activeBatch = null;
            if (taskState == "Inventory") { stopState = target == "Cancelled" ? "Cancelled" : "Paused"; stop!.Cancel(); }
            return Snapshot(OwnedBatch(batchId));
        }
    }
    private void AssertTaskNotBatchResume(string task)
    {
        if (Scalar("SELECT batch FROM batch_entries WHERE task=@p0", task) != null) throw new InvalidOperationException("BatchEntryStartRequired");
    }
    private void StopBoundBatchFromLegacy(string task, bool cancel)
    {
        var batch = Scalar("SELECT batch FROM batch_entries WHERE task=@p0 AND state!='Released'", task) as string;
        if (batch == null) return;
        AdvanceBatch(batch, cancel ? "Cancelled" : "Paused", "Explicit" + (cancel ? "Cancelled" : "Paused"));
        batchRunIntent = false;
        if (cancel) { if (activeBatch == batch) activeBatch = null; }
        else activeBatch = batch;
    }
}
