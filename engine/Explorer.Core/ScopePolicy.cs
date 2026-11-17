using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32;

namespace SafeJunkCleaner.Explorer;

public sealed class ScopePolicy
{
    private readonly string stateRoot;
    private readonly List<string> excluded = [];
    private readonly string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public ScopePolicy(string stateRoot)
    {
        this.stateRoot = stateRoot;
        foreach (var folder in new[] { Environment.SpecialFolder.Windows })
        {
            var p = Environment.GetFolderPath(folder); if (p.Length > 0) excluded.Add(WindowsFacts.Canonical(p));
        }
        excluded.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SafeJunkCleaner"));
        using var profiles = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList");
        if (profiles != null)
            foreach (var key in profiles.GetSubKeyNames())
            {
                using var entry = profiles.OpenSubKey(key);
                if (entry?.GetValue("ProfileImagePath") is string p)
                {
                    p = WindowsFacts.Canonical(Environment.ExpandEnvironmentVariables(p));
                    if (!p.Equals(profile, StringComparison.OrdinalIgnoreCase)) excluded.Add(p);
                }
            }
    }
    public string? Exclusion(string path)
    {
        if (WindowsFacts.Within(path, stateRoot)) return "ApplicationState";
        if (excluded.Any(root => WindowsFacts.Within(path, root))) return "ProtectedSystemOrOtherAccount";
        var users = Path.Combine(Path.GetPathRoot(Environment.SystemDirectory)!, "Users");
        if (WindowsFacts.Within(path, users) && !WindowsFacts.Within(path, profile) && !path.Equals(users, StringComparison.OrdinalIgnoreCase)) return "OtherAccount";
        var parts = path[3..].Split('\\');
        if (parts.Any(p => p.StartsWith('$') || p.Equals("System Volume Information", StringComparison.OrdinalIgnoreCase) || p.Equals("Recovery", StringComparison.OrdinalIgnoreCase) || p.Equals("Config.Msi", StringComparison.OrdinalIgnoreCase))) return "ProtectedVolumeInternal";
        return null;
    }
    public string Validate(string path)
    {
        path = WindowsFacts.Canonical(path); WindowsFacts.LocalVolume(path);
        if (Exclusion(path) is string reason) throw new InvalidOperationException(reason);
        using var guard = WindowsFacts.Guard(path);
        return path;
    }
    public static string DisplayProtection(string path) => "ReadOnlyNoProcessingAuthorization";
}

public sealed class PrivateState : IDisposable
{
    public string Root { get; }
    public string OwnerSid { get; } = WindowsIdentity.GetCurrent().User!.Value;
    public string Identity { get; }
    private readonly IDisposable guard;
    private readonly FileStream processLock;
    public PrivateState(string path)
    {
        Root = WindowsFacts.Canonical(path); WindowsFacts.LocalVolume(Root);
        if (!Directory.Exists(Root))
        {
            using var parent = WindowsFacts.Guard(Path.GetDirectoryName(Root)!);
            var security = new DirectorySecurity(); var sid = new SecurityIdentifier(OwnerSid);
            security.SetOwner(sid); security.SetAccessRuleProtection(true, false);
            foreach (var id in new[] { sid, new SecurityIdentifier("S-1-5-18") })
                security.AddAccessRule(new FileSystemAccessRule(id, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            FileSystemAclExtensions.CreateDirectory(security, Root);
        }
        AssertAcl(new DirectoryInfo(Root));
        Identity = WindowsFacts.Read(Root).Identity;
        guard = WindowsFacts.Guard(Root, Identity);
        try
        {
            ValidateFiles();
            var lockPath = Path.Combine(Root, "engine.lock");
            if (File.Exists(lockPath)) ValidateFile(lockPath);
            processLock = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            processLock.SetLength(0);
            processLock.Write(System.Text.Encoding.UTF8.GetBytes("SafeJunkCleaner.Explorer private state lock v1\n"));
            processLock.Flush(true);
            AssertAcl(new FileInfo(lockPath));
            Environment.SetEnvironmentVariable("SQLITE_TMPDIR", Root);
        }
        catch { try { processLock?.Dispose(); } finally { guard.Dispose(); } throw; }
    }
    private void AssertAcl(FileSystemInfo file)
    {
        var acl = file is DirectoryInfo d ? (FileSystemSecurity)d.GetAccessControl() : ((FileInfo)file).GetAccessControl();
        if (acl.GetOwner(typeof(SecurityIdentifier))?.Value != OwnerSid) throw new InvalidOperationException("StateOwnerMismatch");
        if (file is DirectoryInfo && !acl.AreAccessRulesProtected) throw new InvalidOperationException("StateAclInheritance");
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            if (rule.AccessControlType == AccessControlType.Allow && rule.IdentityReference.Value != OwnerSid && rule.IdentityReference.Value != "S-1-5-18") throw new InvalidOperationException("StateAclNotPrivate");
    }
    private void ValidateFile(string path)
    {
        var f = WindowsFacts.Read(path);
        if ((f.Attributes & (WindowsFacts.UnsafeAttributes | 16)) != 0 || f.Links != 1) throw new InvalidOperationException("UnsafeStateFile");
        AssertAcl(new FileInfo(path));
    }
    public void ValidateFiles()
    {
        AssertAcl(new DirectoryInfo(Root));
        if (WindowsFacts.Read(Root).Identity != Identity && Identity != null) throw new InvalidOperationException("StateRootChanged");
        foreach (var p in Directory.EnumerateFileSystemEntries(Root))
        {
            if (Path.GetFileName(p) == "engine.lock") continue;
            if (Path.GetFileName(p) is not ("inventory.db" or "inventory.db-wal" or "inventory.db-shm")) throw new InvalidOperationException("UnknownStateEntry");
            ValidateFile(p);
        }
    }
    public void Dispose() { processLock.Dispose(); guard.Dispose(); }
}
