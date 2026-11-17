using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace SafeJunkCleaner.Explorer.Execution;

// Private, current-user protected artifacts; no package or machine-wide configuration is required.
public sealed partial class WindowsApprovalStore : IApprovalStore, IDisposable
{
    private readonly string root;
    private readonly string sid = WindowsIdentity.GetCurrent().User!.Value;
    private readonly IDisposable guard;
    private readonly FileStream ownerLock;
    public WindowsApprovalStore(string directory)
    {
        root = WindowsFacts.Canonical(directory); WindowsFacts.LocalVolume(root);
        using var parent = WindowsFacts.Guard(Path.GetDirectoryName(root)!);
        if (!Directory.Exists(root))
        {
            var acl = new DirectorySecurity(); var owner = new SecurityIdentifier(sid);
            acl.SetOwner(owner); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new(owner, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            FileSystemAclExtensions.CreateDirectory(acl, root);
        }
        CheckAcl(new DirectoryInfo(root));
        guard = WindowsFacts.Guard(root, WindowsFacts.Read(root).Identity);
        try
        {
            var lockPath = Path.Combine(root, "execution.lock");
            if (File.Exists(lockPath)) CheckFile(lockPath);
            ownerLock = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            CheckAcl(new FileInfo(lockPath));
        }
        catch { try { ownerLock?.Dispose(); } finally { guard.Dispose(); } throw; }
    }
    public void PutDraft(ApprovalDraft draft) => Put(draft.DraftId, "draft", draft);
    public ApprovalDraft ReadDraft(string id) => Get<ApprovalDraft>(id, "draft");
    public void PutSeal(ApprovalSeal seal) => Put(seal.ApprovalId, "seal", seal);
    public ApprovalSeal ReadSeal(string id) => Get<ApprovalSeal>(id, "seal");
    public IDisposable Claim(string approvalId)
    {
        lock (maintenanceGate)
        {
            var path = Artifact(approvalId, "claim");
            if (reservedExecution != null && reservedExecution != approvalId) throw new InvalidOperationException("ExecutionEvidenceReservationActive");
            CheckNewArtifactCapacity(4096, "claim");
            var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough);
            try { CheckFile(path); stream.Write(Dpapi.Protect(Encoding.UTF8.GetBytes(sid))); stream.Flush(true); return stream; }
            catch { stream.Dispose(); throw; }
        }
    }
    public void Append(string approvalId, ExecutionEntry entry)
    {
        lock (maintenanceGate)
        {
            if (reservedExecution != null && reservedExecution != approvalId) throw new InvalidOperationException("ExecutionEvidenceReservationActive");
            var path = Artifact(approvalId, "ledger");
            if (File.Exists(path)) CheckFile(path);
            var bounded = entry with { Reason = entry.Reason.Length <= 400 ? entry.Reason : entry.Reason[..370] + "[ReasonTruncated]", Status = entry.Status.Length <= 40 ? entry.Status : "UnknownOrFailed" };
            var payload = Encoding.ASCII.GetBytes(Convert.ToBase64String(Dpapi.Protect(JsonSerializer.SerializeToUtf8Bytes(bounded, Wire.Json))) + "\n");
            if (reservedExecution == approvalId)
            {
                if (payload.Length > reservedLedgerBytes) throw new InvalidOperationException("ExecutionLedgerBudgetExceeded");
            }
            else CheckNewArtifactCapacity(payload.Length, "ledger");
            using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough);
            CheckFile(path); stream.Write(payload); stream.Flush(true);
            if (reservedExecution == approvalId) reservedLedgerBytes -= payload.Length;
        }
    }
    public ExecutionEntry[] ReadLedger(string approvalId)
    {
        var path = Artifact(approvalId, "ledger");
        if (!File.Exists(path)) return [];
        CheckFile(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        Wire.Require(stream.Length <= 64 * 1024 * 1024, "LedgerTooLarge");
        using var reader = new StreamReader(stream, Encoding.ASCII);
        var result = new List<ExecutionEntry>(); string? line;
        while ((line = reader.ReadLine()) != null)
        {
            // A torn final record is a failure, never evidence that an attempt is safe to retry.
            result.Add(JsonSerializer.Deserialize<ExecutionEntry>(Dpapi.Unprotect(Convert.FromBase64String(line)), Wire.Json) ?? throw new InvalidDataException("InvalidLedger"));
        }
        return result.ToArray();
    }
    private string Artifact(string id, string kind) { Wire.Id(id); return Path.Combine(root, id + "." + kind); }
    private void Put<T>(string id, string kind, T value)
    {
        lock (maintenanceGate)
        {
            if (reservedExecution != null) throw new InvalidOperationException("ExecutionEvidenceReservationActive");
            var path = Artifact(id, kind);
            var data = Dpapi.Protect(JsonSerializer.SerializeToUtf8Bytes(value, Wire.Json));
            Wire.Require(data.Length <= 16 * 1024 * 1024, "ArtifactTooLarge");
            CheckNewArtifactCapacity(data.Length, kind);
            using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough);
            CheckFile(path); stream.Write(data); stream.Flush(true);
        }
    }
    private T Get<T>(string id, string kind)
    {
        var path = Artifact(id, kind); CheckFile(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        Wire.Require(stream.Length is > 0 and <= 16 * 1024 * 1024, "InvalidArtifactSize");
        var data = new byte[checked((int)stream.Length)]; stream.ReadExactly(data);
        return JsonSerializer.Deserialize<T>(Dpapi.Unprotect(data), Wire.Json) ?? throw new InvalidDataException("InvalidArtifact");
    }
    private void CheckFile(string path)
    {
        var f = WindowsFacts.Read(path);
        Wire.Require((f.Attributes & (WindowsFacts.UnsafeAttributes | 16)) == 0 && f.Links == 1, "UnsafeArtifact");
        CheckAcl(new FileInfo(path));
    }
    private void CheckAcl(FileSystemInfo file)
    {
        var acl = file is DirectoryInfo d ? (FileSystemSecurity)d.GetAccessControl() : ((FileInfo)file).GetAccessControl();
        Wire.Require(acl.GetOwner(typeof(SecurityIdentifier))?.Value == sid, "ArtifactOwnerMismatch");
        Wire.Require(file is not DirectoryInfo || acl.AreAccessRulesProtected, "InheritedStateAcl");
        var allow = false;
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            if (rule.AccessControlType == AccessControlType.Allow)
            {
                Wire.Require(rule.IdentityReference.Value == sid, "ArtifactAclNotPrivate");
                allow = true;
            }
        Wire.Require(allow, "MissingOwnerAcl");
    }
    public void Dispose() { ownerLock.Dispose(); guard.Dispose(); }
}

internal static class Dpapi
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Size; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptProtectData(ref Blob input, string description, ref Blob entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, ref Blob entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    internal static byte[] Protect(byte[] bytes) => Transform(bytes, true);
    internal static byte[] Unprotect(byte[] bytes) => Transform(bytes, false);
    private static byte[] Transform(byte[] data, bool protect)
    {
        var entropyBytes = Encoding.UTF8.GetBytes("SafeJunkCleaner.Explorer.Execution/v1");
        var pin = GCHandle.Alloc(data, GCHandleType.Pinned); var entropyPin = GCHandle.Alloc(entropyBytes, GCHandleType.Pinned);
        var output = new Blob();
        try
        {
            var input = new Blob { Size = data.Length, Data = pin.AddrOfPinnedObject() };
            var entropy = new Blob { Size = entropyBytes.Length, Data = entropyPin.AddrOfPinnedObject() };
            // CRYPTPROTECT_UI_FORBIDDEN; never CRYPTPROTECT_LOCAL_MACHINE.
            var ok = protect ? CryptProtectData(ref input, "Explorer approval v1", ref entropy, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, ref entropy, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
            var result = new byte[output.Size]; Marshal.Copy(output.Data, result, 0, output.Size); return result;
        }
        finally { if (output.Data != IntPtr.Zero) LocalFree(output.Data); pin.Free(); entropyPin.Free(); }
    }
}
