using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace QuickClean.Verification;

internal sealed record OwnedQuickCleanFixture(string Root, string Case, string Run, string Parent, string Nonce)
{
    internal const string Version = "0.17.0";
    internal const string ChildToken = "SJC_TEST_DRIVER_TOKEN";
    private static readonly SecurityIdentifier CurrentUser = WindowsIdentity.GetCurrent().User!;
    private static readonly SecurityIdentifier SystemUser = new(WellKnownSidType.LocalSystemSid, null);
    internal string Files => Path.Combine(Root, "files");
    internal string State => Path.Combine(Root, "state");
    internal string Tasks => Path.Combine(State, "Tasks");

    internal static string CheckAuthorizedParent(string path)
    {
        path = Canonical(path);
        Require(Guid.TryParseExact(Path.GetFileName(path), "D", out _), "Evidence parent must be an existing GUID directory.");
        Require(string.Equals(Path.GetFileName(Path.GetDirectoryName(path)), "SafeJunkCleaner-Work", StringComparison.OrdinalIgnoreCase),
            "Evidence parent must be a direct child of the authorized work directory.");
        Require(new DriveInfo(Path.GetPathRoot(path)!).DriveType == DriveType.Fixed, "Only a fixed local drive is supported.");
        CheckPlain(path);
        return path;
    }

    internal static OwnedQuickCleanFixture Create(string run, string evidenceParent, string @case)
    {
        CheckDirect(run, evidenceParent);
        CheckPrivate(run);
        var root = CreatePrivate(run, Guid.NewGuid().ToString("D"));
        var fixture = new OwnedQuickCleanFixture(root, @case, run, evidenceParent, Guid.NewGuid().ToString("N"));
        WriteNew(Path.Combine(root, ".verification-owner"), Dpapi.Seal(JsonSerializer.Serialize(fixture)));
        CreatePrivate(root, "files");
        CreatePrivate(root, "state");
        CreatePrivate(fixture.State, "Tasks");
        return fixture;
    }

    internal static OwnedQuickCleanFixture OpenForChild(string evidenceParent, string run, string root)
    {
        evidenceParent = CheckAuthorizedParent(evidenceParent);
        CheckDirect(run, evidenceParent);
        CheckDirect(root, run);
        Require(Guid.TryParseExact(Path.GetFileName(run), "D", out _) && Guid.TryParseExact(Path.GetFileName(root), "D", out _), "Child roots must be GUIDs.");
        CheckPrivate(run);
        CheckPrivate(root);
        var ownerPath = Path.Combine(root, ".verification-owner");
        CheckPlain(ownerPath);
        var owner = JsonSerializer.Deserialize<OwnedQuickCleanFixture>(Dpapi.Unseal(File.ReadAllText(ownerPath)))
            ?? throw new InvalidOperationException("Missing fixture descriptor.");
        var token = Environment.GetEnvironmentVariable(ChildToken);
        Require(!string.IsNullOrEmpty(token) && Guid.TryParseExact(token, "N", out _) && owner.Nonce == token &&
            SamePath(owner.Root, root) && SamePath(owner.Run, run) && SamePath(owner.Parent, evidenceParent), "Child lacks a matching launcher/fixture owner.");
        CheckPrivate(owner.Files);
        CheckPrivate(owner.State);
        CheckPrivate(owner.Tasks);
        return owner;
    }

    internal string CreateTask()
    {
        string id = Guid.NewGuid().ToString("D");
        string path = CreatePrivate(Tasks, id);
        var owner = new { Version, SchemaVersion = 1, TaskId = id, Path = path, StateRoot = State, IsTest = true, Nonce = Guid.NewGuid().ToString("N") };
        WriteNew(Path.Combine(path, ".task-owner"), Dpapi.Seal(JsonSerializer.Serialize(owner)));
        return path;
    }

    internal string FixtureFile(string leaf, string content, bool old = true, bool outside = false)
    {
        var dir = outside ? Root : Files;
        CheckPrivate(dir);
        var path = Path.Combine(dir, leaf);
        CheckDirect(path, dir);
        WriteNew(path, content);
        if (old) File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddDays(-7));
        return path;
    }

    internal static string CreatePrivate(string parent, string leaf)
    {
        var path = Path.Combine(parent, leaf);
        CheckDirect(path, parent);
        CheckPlain(parent);
        Require(!Path.Exists(path), "New directory already exists: " + path);
        var security = new DirectorySecurity();
        security.SetOwner(CurrentUser);
        security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { CurrentUser, SystemUser })
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).Create(security);
        CheckPrivate(path);
        return path;
    }

    internal static void CheckPrivate(string directory)
    {
        CheckPlain(directory);
        var security = new DirectoryInfo(directory).GetAccessControl();
        Require(security.AreAccessRulesProtected && CurrentUser.Equals(security.GetOwner(typeof(SecurityIdentifier))),
            "Private directory owner/ACL protection mismatch: " + directory);
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            Require(rule.AccessControlType != AccessControlType.Allow || rule.IdentityReference.Equals(CurrentUser) || rule.IdentityReference.Equals(SystemUser),
                "Unexpected ACL entry in " + directory);
    }

    internal static void CheckFileOwner(string file)
    {
        CheckPlain(file);
        Require(CurrentUser.Equals(new FileInfo(file).GetAccessControl().GetOwner(typeof(SecurityIdentifier))), "File is not owned by current user: " + file);
    }

    internal static void WriteNew(string path, string content)
    {
        CheckPlain(Path.GetDirectoryName(path)!);
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        output.Write(Encoding.UTF8.GetBytes(content));
        output.Flush(flushToDisk: true);
    }

    internal static string Canonical(string path)
    {
        Require(path.Length > 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] == '\\' &&
            !path.AsSpan(2).Contains(':') && !path.Any(char.IsControl), "Expected local absolute path: " + path);
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
    }

    internal static bool SamePath(string a, string b) => string.Equals(Canonical(a), Canonical(b), StringComparison.OrdinalIgnoreCase);

    internal static void CheckDirect(string path, string parent)
    {
        Require(SamePath(Path.GetDirectoryName(Canonical(path))!, parent), "Not a direct child: " + path);
    }

    internal static void CheckPlain(string path)
    {
        for (string? current = Canonical(path); current is not null; current = Path.GetDirectoryName(current))
            Require((File.GetAttributes(current) & (FileAttributes.ReparsePoint | FileAttributes.Offline)) == 0, "Links, reparse points and offline paths forbidden: " + current);
    }

    internal static void Require(bool ok, string text)
    {
        if (!ok) throw new InvalidOperationException(text);
    }

    private static class Dpapi
    {
        [StructLayout(LayoutKind.Sequential)] private struct Blob { internal int Length; internal IntPtr Bytes; }
        [DllImport("crypt32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CryptProtectData(ref Blob input, IntPtr description, ref Blob entropy,
            IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
        [DllImport("crypt32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, ref Blob entropy,
            IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);

        internal static string Seal(string text) => Convert.ToBase64String(Transform(Encoding.UTF8.GetBytes(text), true));
        internal static string Unseal(string text) => Encoding.UTF8.GetString(Transform(Convert.FromBase64String(text), false));
        private static byte[] Transform(byte[] source, bool seal)
        {
            var input = Allocate(source);
            var entropy = Allocate("SafeJunkCleaner-v3-seal"u8.ToArray());
            try
            {
                // UI forbidden; machine scope is deliberately absent (DPAPI CurrentUser).
                bool ok = seal ? CryptProtectData(ref input, 0, ref entropy, 0, 0, 1, out var output)
                               : CryptUnprotectData(ref input, 0, ref entropy, 0, 0, 1, out output);
                if (!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    var bytes = new byte[output.Length];
                    Marshal.Copy(output.Bytes, bytes, 0, bytes.Length);
                    return bytes;
                }
                finally { LocalFree(output.Bytes); }
            }
            finally
            {
                Marshal.FreeHGlobal(input.Bytes);
                Marshal.FreeHGlobal(entropy.Bytes);
                CryptographicOperations.ZeroMemory(source);
            }
        }

        private static Blob Allocate(byte[] data)
        {
            var bytes = Marshal.AllocHGlobal(data.Length);
            Marshal.Copy(data, 0, bytes, data.Length);
            return new Blob { Length = data.Length, Bytes = bytes };
        }
    }
}
