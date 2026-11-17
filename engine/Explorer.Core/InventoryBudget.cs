namespace SafeJunkCleaner.Explorer;

public sealed partial class InventoryEngine
{
    private bool ObjectIndexRepairPending() => Convert.ToInt64(Scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='task_objects'")) == 0;
    private bool TryRepairObjectIndex()
    {
        if (!ObjectIndexRepairPending()) return true;
        long pageSize = Convert.ToInt64(Scalar("PRAGMA page_size"));
        // Inspect only existing metadata before allocating the index. Reserve for
        // keys, b-tree/overflow pages, WAL copies and fixed SQLite overhead. Do not
        // first build an arbitrarily large index merely to discover the quota.
        long payload = Convert.ToInt64(Scalar("SELECT COALESCE(SUM(length(CAST(task AS BLOB))+64),0) FROM objects"));
        long reservation = checked(4L * payload + 128L * pageSize);
        long used = StateBytes();
        if (reservation > limits.MaxStateBytes || used > limits.MaxStateBytes - reservation ||
            AvailableDriveBytes() < reservation + 256L * 1024 * 1024) return false;
        using var transaction = db.BeginTransaction();
        Exec("CREATE INDEX task_objects ON objects(task,id)");
        long indexedBytes = checked(Convert.ToInt64(Scalar("PRAGMA page_count")) * pageSize);
        // Retain the physical quota check as well as the conservative preflight.
        // Disposal rolls back only this optional index, never any stored facts.
        if (indexedBytes > limits.MaxStateBytes || StateBytes() > limits.MaxStateBytes) return false;
        transaction.Commit(); return true;
    }

    // Explicit session setting. Existing private records never change their scope or
    // deletion authority. The value is not silently persisted as a new authorization.
    public object ConfigureStorageBudget(int mebibytes, bool confirmed)
    {
        lock (gate)
        {
            state.ValidateFiles();
            if (!confirmed) throw new InvalidOperationException("ExplicitStorageBudgetConfirmationRequired");
            if (InventoryBusy()) throw new InvalidOperationException("InventoryActive");
            if (mebibytes is < 512 or > 16384) throw new InvalidOperationException("InvalidStorageBudget");
            long bytes = checked((long)mebibytes * 1024 * 1024);
            if (bytes < StateBytes()) throw new InvalidOperationException("StorageBudgetBelowExistingUsage");
            var previous = limits;
            limits = limits with { MaxStateBytes = bytes };
            try { TryRepairObjectIndex(); }
            catch { limits = previous; throw; }
            return new { MaxStateBytes = bytes, SessionOnly = true, ObjectCountLimited = limits.MaxObjectsPerTask > 0, MinimumFreeDriveBytes = 256L * 1024 * 1024,
                IndexRepairPending = ObjectIndexRepairPending() };
        }
    }
}
