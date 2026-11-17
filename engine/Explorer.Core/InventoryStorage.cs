using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace SafeJunkCleaner.Explorer;

public sealed record StorageInfo(long DbBytes, long WalBytes, long ShmBytes, long LockBytes, long TotalBytes,
    long MaxStateBytes, long PageSize, long PageCount, long FreePages, long ReusableBytes, long Tasks, long Objects,
    bool CanCompact, string? CompactionReason, long EstimatedBackupBytes, long EstimatedVacuumBytes,
    long SafetyReserveBytes, long EstimatedExtraBytes, long AvailableDriveBytes,
    int RetainedBackupDirectories, long RetainedBackupBytes, int RetainedBackupUnavailableEntries, bool IndexRepairPending = false);
public sealed record StateCompactionResult(long BeforeBytes, long AfterBytes, long ReclaimedBytes, string BackupPath,
    long BackupBytes, string BackupSha256, long TasksPreserved, long ObjectsPreserved);
public sealed class StateCompactionException(string code, string stage, string? backupPath, long beforeBytes, long backupBytes, Exception inner)
    : InvalidOperationException(code, inner)
{
    public string Stage { get; } = stage;
    public string? BackupPath { get; } = backupPath;
    public long BeforeBytes { get; } = beforeBytes;
    public long BackupBytes { get; } = backupBytes;
}

public sealed partial class InventoryEngine
{
    private long FileBytes(string name) { var path = Path.Combine(state.Root, name); return File.Exists(path) ? new FileInfo(path).Length : 0; }
    private long AvailableDriveBytes() => new DriveInfo(Path.GetPathRoot(state.Root)!).AvailableFreeSpace;
    private bool InventoryBusy() => HasActiveBatch || worker is { IsCompleted: false } || Convert.ToInt64(Scalar("SELECT COUNT(*) FROM tasks WHERE state='Inventory'")) != 0;
    public StorageInfo GetStorageInfo()
    {
        lock (gate)
        {
            state.ValidateFiles();
            long pageSize = Convert.ToInt64(Scalar("PRAGMA page_size")), pages = Convert.ToInt64(Scalar("PRAGMA page_count")), free = Convert.ToInt64(Scalar("PRAGMA freelist_count"));
            long dbBytes = FileBytes("inventory.db"), wal = FileBytes("inventory.db-wal"), shm = FileBytes("inventory.db-shm"), processLock = FileBytes("engine.lock");
            long backup = Math.Max(dbBytes, checked(pageSize * pages));
            // A full logical backup, VACUUM's temporary image and WAL growth plus an explicit reserve.
            // This is an estimate of additional disk space, NOT permission to grow normal inventories beyond quota.
            long vacuum = checked(backup * 2), reserve = Math.Max(16777216L, backup / 10), extra = checked(backup + vacuum + reserve);
            long available = AvailableDriveBytes();
            var retained = RetainedStorage.Measure(state.Root, "-backup-", state.OwnerSid);
            string? reason = InventoryBusy() ? "InventoryActive" : available < extra ? "InsufficientDriveSpace" : null;
            return new(dbBytes, wal, shm, processLock, checked(dbBytes + wal + shm + processLock), limits.MaxStateBytes,
                pageSize, pages, free, checked(pageSize * free), Convert.ToInt64(Scalar("SELECT COUNT(*) FROM tasks")),
                Convert.ToInt64(Scalar("SELECT COUNT(*) FROM objects")), reason == null, reason, backup, vacuum, reserve, extra, available, retained.Directories, retained.Bytes, retained.UnavailableEntries, ObjectIndexRepairPending());
        }
    }
    private static void QuickCheck(SqliteConnection connection)
    {
        using var cmd = connection.CreateCommand(); cmd.CommandText = "PRAGMA quick_check"; using var reader = cmd.ExecuteReader();
        if (!reader.Read() || reader.GetString(0) != "ok" || reader.Read()) throw new InvalidOperationException("DatabaseQuickCheckFailed");
    }
    private string TaskFingerprint() => Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(Rows("SELECT * FROM tasks ORDER BY id"))));
    private static string DatabaseFingerprint(SqliteConnection connection, string table)
    {
        if (table is not ("tasks" or "objects" or "batches" or "batch_entries")) throw new ArgumentException(nameof(table));
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        using var command = connection.CreateCommand(); command.CommandText = "SELECT * FROM " + table + (table == "batch_entries" ? " ORDER BY batch,entry_index" : " ORDER BY id");
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var values = new object?[reader.FieldCount];
            for (int i = 0; i < values.Length; i++) values[i] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            var row = JsonSerializer.SerializeToUtf8Bytes(values);
            hash.AppendData(BitConverter.GetBytes(row.Length)); hash.AppendData(row);
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }
    private static void ValidateBackupEntry(string path, string owner)
    {
        var fact = WindowsFacts.Read(path);
        if ((fact.Attributes & (WindowsFacts.UnsafeAttributes | 16)) != 0 || fact.Links != 1) throw new InvalidOperationException("UnsafeBackupFile");
        var acl = new FileInfo(path).GetAccessControl();
        if (acl.GetOwner(typeof(SecurityIdentifier))?.Value != owner) throw new InvalidOperationException("BackupOwnerMismatch");
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            if (rule.AccessControlType == AccessControlType.Allow && rule.IdentityReference.Value != owner && rule.IdentityReference.Value != "S-1-5-18") throw new InvalidOperationException("BackupAclNotPrivate");
    }
    private static void WriteBackupManifest(string path, object manifest)
    {
        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        file.Write(JsonSerializer.SerializeToUtf8Bytes(manifest, new JsonSerializerOptions { WriteIndented = true })); file.Flush(true);
    }
    private void Checkpoint()
    {
        var result = Rows("PRAGMA wal_checkpoint(TRUNCATE)");
        if (result.Count != 1 || Convert.ToInt64(result[0].Values.First()) != 0) throw new InvalidOperationException("DatabaseCheckpointBusy");
    }
    public StateCompactionResult CompactState(bool confirmed)
    {
        lock (gate)
        {
            if (!confirmed) throw new InvalidOperationException("ExplicitCompactionConfirmationRequired");
            state.ValidateFiles();
            if (InventoryBusy()) throw new InvalidOperationException("InventoryActive");
            string stage = "Preflight"; string? backupPath = null; long before = 0, backupBytes = 0;
            try
            {
                var info = GetStorageInfo(); before = info.TotalBytes;
                if (!info.CanCompact) throw new InvalidOperationException(info.CompactionReason!);
                var sourceIdentity = WindowsFacts.Read(Path.Combine(state.Root, "inventory.db")).Identity;
                QuickCheck(db);
                string fingerprint = TaskFingerprint(), taskRows = DatabaseFingerprint(db, "tasks"), objectRows = DatabaseFingerprint(db, "objects"),
                    batchRows = DatabaseFingerprint(db, "batches"), entryRows = DatabaseFingerprint(db, "batch_entries");
                long tasks = info.Tasks, objects = info.Objects, batches = Convert.ToInt64(Scalar("SELECT COUNT(*) FROM batches")), entries = Convert.ToInt64(Scalar("SELECT COUNT(*) FROM batch_entries"));
                // The original PrivateState, its exclusive process lock and pinned ancestor guard remain held.
                string parent = Path.GetDirectoryName(state.Root)!;
                using var parentGuard = WindowsFacts.Guard(parent);
                string backupDirectory = Path.Combine(parent, Path.GetFileName(state.Root) + "-backup-" + Guid.NewGuid().ToString("D"));
                if (Directory.Exists(backupDirectory) || File.Exists(backupDirectory)) throw new InvalidOperationException("BackupDestinationExists");
                var security = new DirectorySecurity(); var owner = new SecurityIdentifier(state.OwnerSid);
                security.SetOwner(owner); security.SetAccessRuleProtection(true, false);
                foreach (var sid in new[] { owner, new SecurityIdentifier("S-1-5-18") })
                    security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                FileSystemAclExtensions.CreateDirectory(security, backupDirectory);
                using var backupGuard = WindowsFacts.Guard(backupDirectory);
                backupPath = Path.Combine(backupDirectory, "inventory.db");
                stage = "Backup";
                using (var copy = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = backupPath, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = false }.ToString()))
                {
                    copy.Open(); db.BackupDatabase(copy); QuickCheck(copy);
                    using var cmd = copy.CreateCommand(); cmd.CommandText = "SELECT COUNT(*) FROM tasks";
                    if (Convert.ToInt64(cmd.ExecuteScalar()) != tasks) throw new InvalidOperationException("BackupTaskCountMismatch");
                    cmd.CommandText = "SELECT COUNT(*) FROM objects";
                    if (Convert.ToInt64(cmd.ExecuteScalar()) != objects) throw new InvalidOperationException("BackupObjectCountMismatch");
                    cmd.CommandText = "PRAGMA user_version";
                    if (Convert.ToInt64(cmd.ExecuteScalar()) != 4) throw new InvalidOperationException("BackupSchemaMismatch");
                    cmd.CommandText = "SELECT COUNT(*) FROM batches";
                    if (Convert.ToInt64(cmd.ExecuteScalar()) != batches) throw new InvalidOperationException("BackupBatchCountMismatch");
                    cmd.CommandText = "SELECT COUNT(*) FROM batch_entries";
                    if (Convert.ToInt64(cmd.ExecuteScalar()) != entries) throw new InvalidOperationException("BackupEntryCountMismatch");
                    if (DatabaseFingerprint(copy, "tasks") != taskRows || DatabaseFingerprint(copy, "objects") != objectRows ||
                        DatabaseFingerprint(copy, "batches") != batchRows || DatabaseFingerprint(copy, "batch_entries") != entryRows) throw new InvalidOperationException("BackupRowsMismatch");
                }
                ValidateBackupEntry(backupPath, state.OwnerSid);
                string hash;
                using (var copy = new FileStream(backupPath, FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
                { copy.Flush(true); backupBytes = copy.Length; hash = Convert.ToHexString(SHA256.HashData(copy)); }
                string manifest = Path.Combine(backupDirectory, "manifest.json");
                WriteBackupManifest(manifest, new { SchemaVersion = 4, CreatedUtc = DateTime.UtcNow.ToString("O"), OwnerSid = state.OwnerSid,
                    SourceRoot = state.Root, SourceIdentity = sourceIdentity, Tasks = tasks, Objects = objects, Batches = batches, BatchEntries = entries, TaskFingerprintSha256 = fingerprint,
                    TaskRowsSha256 = taskRows, ObjectRowsSha256 = objectRows, BatchRowsSha256 = batchRows, BatchEntryRowsSha256 = entryRows,
                    File = "inventory.db", Bytes = backupBytes, Sha256 = hash, QuickCheck = "ok", RestorePolicy = "RetainedForManualRecoveryNeverAutomaticallyOverwriteState" });
                ValidateBackupEntry(manifest, state.OwnerSid);
                stage = "VacuumPreflight";
                state.ValidateFiles();
                if (AvailableDriveBytes() < checked(info.EstimatedVacuumBytes + info.SafetyReserveBytes)) throw new InvalidOperationException("InsufficientDriveSpace");
                stage = "Vacuum";
                Checkpoint(); Exec("VACUUM"); Checkpoint(); QuickCheck(db);
                stage = "Validate";
                state.ValidateFiles();
                if (WindowsFacts.Read(Path.Combine(state.Root, "inventory.db")).Identity != sourceIdentity) throw new InvalidOperationException("DatabaseIdentityChanged");
                if (TaskFingerprint() != fingerprint || DatabaseFingerprint(db, "tasks") != taskRows || DatabaseFingerprint(db, "objects") != objectRows ||
                    DatabaseFingerprint(db, "batches") != batchRows || DatabaseFingerprint(db, "batch_entries") != entryRows ||
                    Convert.ToInt64(Scalar("PRAGMA user_version")) != 4 || Convert.ToInt64(Scalar("SELECT COUNT(*) FROM objects")) != objects ||
                    Convert.ToInt64(Scalar("SELECT COUNT(*) FROM batches")) != batches || Convert.ToInt64(Scalar("SELECT COUNT(*) FROM batch_entries")) != entries)
                    throw new InvalidOperationException("CompactionEvidenceMismatch");
                long after = StateBytes();
                return new(before, after, Math.Max(0, before - after), backupPath, backupBytes, hash, tasks, objects);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                // No file replacement, restore, WAL deletion or recursive cleanup on either path.
                throw new StateCompactionException(ex is InvalidOperationException ? ex.Message : "StateCompactionFailed", stage, backupPath, before, backupBytes, ex);
            }
        }
    }
}
