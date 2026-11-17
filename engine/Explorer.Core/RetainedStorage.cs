using System.Security.AccessControl;
using System.Security.Principal;

namespace SafeJunkCleaner.Explorer;

public sealed record RetainedStorageInfo(int Directories, long Bytes, int UnavailableEntries);
public static class RetainedStorage
{
    // Only the application's GUID-named private sibling retention directories, no links or unknown roots.
    public static RetainedStorageInfo Measure(string activeRoot, string suffix, string owner)
    {
        string parent = Path.GetDirectoryName(activeRoot)!, prefix = Path.GetFileName(activeRoot) + suffix;
        int directories = 0, unavailable = 0; long bytes = 0;
        using var parentGuard = WindowsFacts.Guard(parent);
        foreach (var candidate in Directory.EnumerateDirectories(parent, prefix + "*", SearchOption.TopDirectoryOnly))
        {
            string name = Path.GetFileName(candidate);
            if (!name.StartsWith(prefix, StringComparison.Ordinal) || !Guid.TryParseExact(name[prefix.Length..], "D", out _)) continue;
            try
            {
                using var guard = WindowsFacts.Guard(candidate); var acl = new DirectoryInfo(candidate).GetAccessControl();
                if (!acl.AreAccessRulesProtected || acl.GetOwner(typeof(SecurityIdentifier))?.Value != owner) throw new InvalidOperationException("RetainedOwnerMismatch");
                foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                    if (rule.AccessControlType == AccessControlType.Allow && rule.IdentityReference.Value != owner && rule.IdentityReference.Value != "S-1-5-18") throw new InvalidOperationException("RetainedAclNotPrivate");
                directories++;
                foreach (var file in Directory.EnumerateFileSystemEntries(candidate, "*", SearchOption.TopDirectoryOnly))
                {
                    var fact = WindowsFacts.Read(file);
                    if ((fact.Attributes & (WindowsFacts.UnsafeAttributes | 16)) != 0 || fact.Links != 1) { unavailable++; continue; }
                    var fileAcl = new FileInfo(file).GetAccessControl();
                    if (fileAcl.GetOwner(typeof(SecurityIdentifier))?.Value != owner) { unavailable++; continue; }
                    bytes = checked(bytes + new FileInfo(file).Length);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception) { unavailable++; }
        }
        return new(directories, bytes, unavailable);
    }
}
