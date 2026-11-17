using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;

namespace SafeJunkCleaner.Explorer.Execution;

public sealed record ApprovalStorageInfo(long Bytes, int Files, int Drafts, int Seals, int Claims, int Ledgers,
    long MaxBytes, int MaxFiles, int ReclaimableDrafts, long ReclaimableBytes, bool CanPrepare, string? LimitReason,
    int RetainedArchiveDirectories, long RetainedArchiveBytes, int RetainedArchiveUnavailableEntries);
public sealed record ApprovalArchiveResult(int DraftsArchived, long BytesArchived, string ArchivePath, string ManifestSha256);
public sealed class ApprovalArchiveException(string archivePath, string[] movedFiles, Exception inner) : InvalidOperationException("ApprovalArchivePartial", inner)
{
    public string ArchivePath { get; } = archivePath;
    public string[] MovedFiles { get; } = movedFiles;
}
public interface IApprovalMaintenance
{
    ApprovalStorageInfo GetStorageInfo(IReadOnlySet<string> activeDrafts);
    ApprovalArchiveResult ArchiveUnconfirmed(IReadOnlySet<string> activeDrafts, bool confirmed);
    bool IsClaimed(string id);
    void RequireExecutionCapacity(int itemCount);
    IDisposable ReserveExecution(string approvalId, int itemCount);
}

public sealed partial class WindowsApprovalStore : IApprovalMaintenance
{
    private readonly object maintenanceGate = new();
    private const long MaxStoreBytes = 268435456;
    private const int MaxStoreFiles = 4096;
    private const long ExecutionReserveBytes = 67108864;
    private string? reservedExecution;
    private long reservedLedgerBytes;
    public IDisposable ReserveExecution(string approvalId, int itemCount)
    {
        lock (maintenanceGate)
        {
            Wire.Id(approvalId);
            if (reservedExecution != null) throw new InvalidOperationException("ExecutionEvidenceReservationActive");
            RequireExecutionCapacity(itemCount);
            reservedExecution = approvalId; reservedLedgerBytes = checked(4096L * itemCount);
            return new EvidenceLease(this, approvalId);
        }
    }
    private sealed class EvidenceLease(WindowsApprovalStore store, string id) : IDisposable
    {
        public void Dispose()
        {
            lock (store.maintenanceGate)
            {
                if (store.reservedExecution == id) { store.reservedExecution = null; store.reservedLedgerBytes = 0; }
            }
        }
    }
    private IEnumerable<FileInfo> CheckedArtifacts()
    {
        CheckAcl(new DirectoryInfo(root));
        foreach (var path in Directory.EnumerateFileSystemEntries(root))
        {
            if (Path.GetFileName(path) == "execution.lock") continue;
            CheckFile(path);
            var file = new FileInfo(path);
            if (file.Extension is not (".draft" or ".seal" or ".claim" or ".ledger") || !Guid.TryParseExact(Path.GetFileNameWithoutExtension(path), "D", out _))
                throw new InvalidOperationException("UnknownApprovalArtifact");
            yield return file;
        }
    }
    public bool IsClaimed(string id)
    {
        lock (maintenanceGate)
        {
            var path = Artifact(id, "claim");
            if (!File.Exists(path)) return false;
            CheckFile(path); return true;
        }
    }
    private HashSet<string> ReferencedDrafts(IEnumerable<FileInfo> files)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        foreach (var file in files.Where(f => f.Extension == ".seal")) result.Add(ReadSeal(Path.GetFileNameWithoutExtension(file.Name)).Draft.DraftId);
        return result;
    }
    public ApprovalStorageInfo GetStorageInfo(IReadOnlySet<string> activeDrafts)
    {
        lock (maintenanceGate)
        {
            var files = CheckedArtifacts().ToArray(); var references = ReferencedDrafts(files);
            var eligible = files.Where(f => f.Extension == ".draft" && !activeDrafts.Contains(Path.GetFileNameWithoutExtension(f.Name)) &&
                !references.Contains(Path.GetFileNameWithoutExtension(f.Name)) && !File.Exists(Artifact(Path.GetFileNameWithoutExtension(f.Name), "claim"))).ToArray();
            long bytes = files.Sum(f => f.Length);
            var retained = RetainedStorage.Measure(root, "-retained-", sid);
            string? reason = files.Length >= MaxStoreFiles - 16 ? "ApprovalFileQuota" : bytes > MaxStoreBytes - ExecutionReserveBytes ? "ApprovalStorageQuota" : null;
            return new(bytes, files.Length, files.Count(f => f.Extension == ".draft"), files.Count(f => f.Extension == ".seal"), files.Count(f => f.Extension == ".claim"),
                files.Count(f => f.Extension == ".ledger"), MaxStoreBytes, MaxStoreFiles, eligible.Length, eligible.Sum(f => f.Length), reason == null, reason, retained.Directories, retained.Bytes, retained.UnavailableEntries);
        }
    }
    public void RequireExecutionCapacity(int itemCount)
    {
        lock (maintenanceGate)
        {
            if (itemCount is < 1 or > 100000) throw new InvalidOperationException("InvalidCandidateCount");
            long needed = checked(4096L + 4096L * itemCount);
            if (needed > 64L * 1024 * 1024) throw new InvalidOperationException("ExecutionLedgerBudgetExceeded");
            var files = CheckedArtifacts().ToArray();
            if (files.Length > MaxStoreFiles - 2) throw new InvalidOperationException("ApprovalExecutionFileReserve");
            CheckNewArtifactCapacity(needed, "execution");
            if (new DriveInfo(Path.GetPathRoot(root)!).AvailableFreeSpace < needed + 16777216L) throw new InvalidOperationException("ExecutionLedgerDriveSpace");
        }
    }
    private void CheckNewArtifactCapacity(long bytes, string kind)
    {
        var files = CheckedArtifacts().ToArray(); long used = files.Sum(f => f.Length);
        long reserve = kind == "draft" ? ExecutionReserveBytes : 0;
        if (files.Length >= MaxStoreFiles || bytes > MaxStoreBytes - reserve || used > MaxStoreBytes - reserve - bytes)
            throw new InvalidOperationException(kind == "draft" ? "ApprovalStorageQuota" : "ApprovalWriteCapacityExceeded");
    }
    public ApprovalArchiveResult ArchiveUnconfirmed(IReadOnlySet<string> activeDrafts, bool confirmed)
    {
        lock (maintenanceGate)
        {
            if (!confirmed) throw new InvalidOperationException("ExplicitApprovalArchiveConfirmationRequired");
            if (reservedExecution != null) throw new InvalidOperationException("ExecutionEvidenceReservationActive");
            var files = CheckedArtifacts().ToArray(); var references = ReferencedDrafts(files);
            var eligible = files.Where(f => f.Extension == ".draft" && !activeDrafts.Contains(Path.GetFileNameWithoutExtension(f.Name)) &&
                !references.Contains(Path.GetFileNameWithoutExtension(f.Name)) && !File.Exists(Artifact(Path.GetFileNameWithoutExtension(f.Name), "claim"))).ToArray();
            if (eligible.Length == 0) throw new InvalidOperationException("NoUnconfirmedDraftsToArchive");
            var parent = Path.GetDirectoryName(root)!; using var parentGuard = WindowsFacts.Guard(parent);
            var archive = Path.Combine(parent, Path.GetFileName(root) + "-retained-" + Guid.NewGuid().ToString("D"));
            if (Directory.Exists(archive) || File.Exists(archive)) throw new InvalidOperationException("ArchiveAlreadyExists");
            var security = new DirectorySecurity(); var owner = new SecurityIdentifier(sid);
            security.SetOwner(owner); security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new(owner, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            FileSystemAclExtensions.CreateDirectory(security, archive); using var archiveGuard = WindowsFacts.Guard(archive);
            var records = eligible.Select(f => new { File = f.Name, Bytes = f.Length, Identity = WindowsFacts.Read(f.FullName).Identity }).ToArray();
            var manifestPath = Path.Combine(archive, "manifest.json");
            using (var stream = new FileStream(manifestPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
            { JsonSerializer.Serialize(stream, new { CreatedUtc = DateTime.UtcNow, Status = "Pending", Reversible = true, Policy = "OnlyUnconfirmedUnreferencedDrafts;ClaimsSealsLedgersRetained", Files = records }); stream.Flush(true); }
            var moved = new List<string>();
            try
            {
            foreach (var record in records)
            {
                string path = Path.Combine(root, record.File); CheckFile(path);
                string id = Path.GetFileNameWithoutExtension(record.File);
                if (activeDrafts.Contains(id) || File.Exists(Artifact(id, "claim")) || WindowsFacts.Read(path).Identity != record.Identity || new FileInfo(path).Length != record.Bytes) throw new InvalidOperationException("DraftChangedBeforeArchive");
                _ = ReadDraft(id); // Authenticate DPAPI before any displacement; locked/tampered drafts fail here.
                string hash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
                using (var intent = new FileStream(Path.Combine(archive, id + ".move.json"), FileMode.CreateNew, FileAccess.Write, FileShare.Read))
                { JsonSerializer.Serialize(intent, new { record.File, record.Bytes, record.Identity, Sha256 = hash, Status = "Pending" }); intent.Flush(true); }
                CheckFile(path);
                if (WindowsFacts.Read(path).Identity != record.Identity || Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))) != hash) throw new InvalidOperationException("DraftChangedBeforeArchive");
                File.Move(path, Path.Combine(archive, record.File), false); moved.Add(record.File);
            }
            using (var complete = new FileStream(Path.Combine(archive, "completed.json"), FileMode.CreateNew, FileAccess.Write, FileShare.Read))
            { JsonSerializer.Serialize(complete, new { Status = "Completed", MovedFiles = moved, ManifestSha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(manifestPath))) }); complete.Flush(true); }
            return new(records.Length, records.Sum(r => r.Bytes), archive, Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(manifestPath))));
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                try
                {
                    using var failure = new FileStream(Path.Combine(archive, "partial.json"), FileMode.CreateNew, FileAccess.Write, FileShare.Read);
                    JsonSerializer.Serialize(failure, new { Status = "Partial", MovedFiles = moved, ErrorType = ex.GetType().Name }); failure.Flush(true);
                }
                catch (Exception reportFailure) when (reportFailure is not OutOfMemoryException)
                { ex.Data["FailureReportError"] = reportFailure.GetType().Name; }
                // Never let failure-report I/O hide the original recovery location and moved set.
                throw new ApprovalArchiveException(archive, moved.ToArray(), ex);
            }
        }
    }
}
