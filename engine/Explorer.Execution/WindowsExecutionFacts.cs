using System.Security.Cryptography;
using System.Security.Principal;

namespace SafeJunkCleaner.Explorer.Execution;

public sealed class WindowsExecutionFacts : IExecutionFacts
{
    public string OwnerSid => WindowsIdentity.GetCurrent().User!.Value;
    private readonly ScopePolicy policy;
    private readonly string[] protectedRoots;
    private readonly ITrustedBuildArtifactAuthorizations? buildArtifacts;
    private static readonly HashSet<string> ProtectedExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".pdf", ".odt", ".ods", ".rtf",
        ".jpg", ".jpeg", ".png", ".heic", ".raw", ".cr2", ".nef", ".dng", ".tif", ".tiff", ".psd",
        ".bak", ".backup", ".vhd", ".vhdx", ".pst", ".ost", ".sqlite", ".db", ".sys", ".dll", ".exe",
        ".cs", ".fs", ".vb", ".csproj", ".fsproj", ".vbproj", ".sln", ".py", ".ps1", ".sh", ".c", ".h", ".cpp", ".rs", ".go", ".java", ".ts", ".tsx", ".jsx", ".vue",
        ".config", ".ini", ".reg", ".key", ".pem", ".pfx", ".p12", ".env"
    };
    public WindowsExecutionFacts(string applicationStateRoot, ITrustedBuildArtifactAuthorizations? buildArtifacts = null)
    {
        this.buildArtifacts = buildArtifacts;
        policy = new ScopePolicy(WindowsFacts.Canonical(applicationStateRoot));
        protectedRoots = new[] { Environment.SpecialFolder.MyDocuments, Environment.SpecialFolder.MyPictures,
            Environment.SpecialFolder.MyVideos, Environment.SpecialFolder.MyMusic, Environment.SpecialFolder.DesktopDirectory,
            Environment.SpecialFolder.Windows, Environment.SpecialFolder.CommonApplicationData,
            Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.CommonProgramFiles, Environment.SpecialFolder.CommonProgramFilesX86 }
            .Select(Environment.GetFolderPath).Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"))
            .Where(p => !string.IsNullOrWhiteSpace(p)).Select(WindowsFacts.Canonical).ToArray();
    }
    public void ValidateLocalPath(string path)
    {
        Wire.Require(WindowsFacts.Canonical(path).Equals(path, StringComparison.OrdinalIgnoreCase), "NonCanonicalPath");
        WindowsFacts.LocalVolume(path);
    }
    public string? HardProtection(string path)
    {
        ValidateLocalPath(path);
        if (policy.Exclusion(path) is { } reason) return reason;
        if (protectedRoots.Any(r => WindowsFacts.Within(path, r))) return "ProtectedUserOrSystemRoot";
        var segments = path[3..].Split('\\');
        if (segments.Any(p => p.Equals("Backup", StringComparison.OrdinalIgnoreCase) || p.Equals("Backups", StringComparison.OrdinalIgnoreCase)
            || p.Equals("Documents", StringComparison.OrdinalIgnoreCase) || p.Equals("Photos", StringComparison.OrdinalIgnoreCase)
            || p.Equals("Pictures", StringComparison.OrdinalIgnoreCase) || p.Equals("OneDrive", StringComparison.OrdinalIgnoreCase))) return "ProtectedUserDataSegment";
        if (segments.Any(p => p.Equals("Program Files", StringComparison.OrdinalIgnoreCase) || p.Equals("Program Files (x86)", StringComparison.OrdinalIgnoreCase)
            || p.Equals("WindowsApps", StringComparison.OrdinalIgnoreCase))) return "ProtectedInstalledProgram";
        if (ProtectedExtensions.Contains(Path.GetExtension(path)) && !BuildArtifactDllException.Allows(path, OwnerSid, buildArtifacts)) return "ProtectedDocumentPhotoBackupOrProgram";
        return null;
    }
    public AncestorSnapshot[] Ancestors(string path)
    {
        var result = new List<AncestorSnapshot>();
        for (var parent = Path.GetDirectoryName(path); parent != null; parent = Path.GetDirectoryName(parent))
        {
            var fact = WindowsFacts.Read(parent);
            Wire.Require((fact.Attributes & (WindowsFacts.UnsafeAttributes | 16)) == 16, "UnsafeAncestor");
            result.Add(new(parent, fact.Identity));
        }
        return result.ToArray();
    }
    public IDisposable GuardAncestors(string path, AncestorSnapshot[] expected)
    {
        var guard = WindowsFacts.Guard(Path.GetDirectoryName(path)!);
        try
        {
            Wire.Require(Wire.Hash(Ancestors(path)) == Wire.Hash(expected), "AncestorChanged");
            return guard;
        }
        catch { guard.Dispose(); throw; }
    }
    public IDisposable GuardRetainedCopy(FileSnapshot expected)
    {
        // Keep the verified retained content readable but neither writable nor replaceable until recycle returns.
        var stream = new FileStream(expected.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
        try
        {
            var before = WindowsFacts.Read(expected.Path);
            var hash = Convert.ToHexString(SHA256.HashData(stream));
            var after = WindowsFacts.Read(expected.Path);
            Wire.Require(before == after && before.Identity == expected.Identity && before.LogicalBytes == expected.Size
                && before.ModifiedUtc == expected.ModifiedUtc && hash == expected.ContentSha256, "RetainedCopyChanged");
            return stream;
        }
        catch { stream.Dispose(); throw; }
    }
    public CurrentFile Read(string path, bool verifyContent)
    {
        ValidateLocalPath(path);
        var first = WindowsFacts.Read(path);
        var unsafeFile = (first.Attributes & (WindowsFacts.UnsafeAttributes | 0x200)) != 0;
        var readOnly = (first.Attributes & 1) != 0; var directory = (first.Attributes & 16) != 0;
        string? hash = null; bool occupied = false;
        if (!unsafeFile && !directory && (!readOnly || verifyContent))
        {
            try
            {
                // Retained copies may be read-only; never change their attributes.
                using var stream = new FileStream(path, FileMode.Open, readOnly ? FileAccess.Read : FileAccess.ReadWrite, FileShare.None);
                if (verifyContent) hash = Convert.ToHexString(SHA256.HashData(stream));
            }
            catch (IOException) { occupied = true; }
            catch (UnauthorizedAccessException) { occupied = true; }
        }
        var last = WindowsFacts.Read(path);
        Wire.Require(first == last, "FileChangedDuringProbe");
        return new(new("", path, first.Identity, first.LogicalBytes, first.ModifiedUtc, hash), directory, readOnly, first.Links, unsafeFile, occupied);
    }
}

public sealed class UnavailableWindowsRecycler : IRecycleOnly
{
    public bool IsAvailable => false;
    public string UnavailableReason => "NativeRecycleOnlyNotVerified";
    public RecycleResult Recycle(FileSnapshot expected, CancellationToken cancellationToken) => new(false, UnavailableReason);
}
