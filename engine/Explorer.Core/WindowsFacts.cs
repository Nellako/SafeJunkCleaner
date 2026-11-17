using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SafeJunkCleaner.Explorer;

public sealed record FileFact(string Identity, uint Attributes, uint Links, long LogicalBytes, long? AllocatedBytes, string ModifiedUtc);

public static class WindowsFacts
{
    public const uint UnsafeAttributes = 0x400 | 0x1000 | 0x40000 | 0x80000 | 0x400000;
    [StructLayout(LayoutKind.Sequential)] private struct Info
    {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)] private struct StandardInfo
    {
        public long AllocationSize, EndOfFile; public uint Links; public byte DeletePending, Directory;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out StandardInfo info, uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern uint GetDriveType(string root);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint QueryDosDevice(string name, char[] target, int size);

    public static string Canonical(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Length > 1800 || !System.Text.RegularExpressions.Regex.IsMatch(path, @"^[A-Za-z]:[\\/]" ) || path.Any(c => c < 32) || path[2..].Contains(':'))
            throw new InvalidOperationException("UnsupportedPath");
        var parts = path[3..].Replace('/', '\\').Split('\\');
        if (parts.Any(p => p is "." or ".." || p.EndsWith(' ') || p.EndsWith('.') || System.Text.RegularExpressions.Regex.IsMatch(p, @"^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)")))
            throw new InvalidOperationException("NonCanonicalPath");
        var full = Path.GetFullPath(path).Replace('/', '\\');
        return full.Length > 3 ? full.TrimEnd('\\') : full;
    }
    public static bool Within(string path, string root) => path.Equals(root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
    public static void LocalVolume(string path)
    {
        var root = Path.GetPathRoot(path)!;
        var target = new char[2048];
        if (GetDriveType(root) != 3 || QueryDosDevice(root[..2], target, target.Length) == 0 || !new string(target).StartsWith(@"\Device\HarddiskVolume", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("UnsupportedOrNetworkVolume");
        var format = new DriveInfo(root).DriveFormat;
        if (format is not ("NTFS" or "ReFS")) throw new InvalidOperationException("UnsupportedFileSystem");
    }
    public static FileFact Read(string path)
    {
        using var handle = Open(path);
        return Read(handle);
    }
    private static SafeFileHandle Open(string path)
    {
        // Metadata only; no content reads, no reparse traversal, no delete sharing.
        var canonical = Canonical(path);
        var h = CreateFile(@"\\?\" + canonical, 0, 3, IntPtr.Zero, 3, 0x02300000, IntPtr.Zero);
        if (h.IsInvalid) { int error = Marshal.GetLastWin32Error(); h.Dispose(); throw new Win32Exception(error); }
        return h;
    }
    private static FileFact Read(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var i)) throw new Win32Exception(Marshal.GetLastWin32Error());
        long? allocation = GetFileInformationByHandleEx(handle, 1, out var s, (uint)Marshal.SizeOf<StandardInfo>()) ? s.AllocationSize : null;
        long write = ((long)i.Write.dwHighDateTime << 32) | (uint)i.Write.dwLowDateTime;
        return new($"{i.Volume:X8}:{i.IndexHigh:X8}{i.IndexLow:X8}:{i.Creation.dwHighDateTime:X8}{i.Creation.dwLowDateTime:X8}", i.Attributes, i.Links,
            ((long)i.SizeHigh << 32) | i.SizeLow, allocation, DateTime.FromFileTimeUtc(write).ToString("O"));
    }
    public static IDisposable Guard(string path, string? expected = null)
    {
        var handles = new List<SafeFileHandle>();
        try
        {
            var chain = new Stack<string>();
            for (string? p = path; p != null; p = Path.GetDirectoryName(p)) chain.Push(p);
            while (chain.TryPop(out var p))
            {
                var h = Open(p); handles.Add(h); var fact = Read(h);
                if ((fact.Attributes & UnsafeAttributes) != 0 || (fact.Attributes & 16) == 0) throw new InvalidOperationException("UnsafeAncestor");
                if (p == path && expected != null && fact.Identity != expected) throw new InvalidOperationException("DirectoryIdentityChanged");
            }
            return new Handles(handles);
        }
        catch { foreach (var h in handles) h.Dispose(); throw; }
    }
    private sealed class Handles(List<SafeFileHandle> handles) : IDisposable
    {
        public void Dispose() { foreach (var h in handles) h.Dispose(); }
    }
}
