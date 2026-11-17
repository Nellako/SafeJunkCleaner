using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace SafeJunkCleaner.Explorer.Analysis;

// Standalone metadata gate: no reference/build dependency on the frozen Core.
public static class MetadataAccess
{
    private const uint Unsafe = 0x400 | 0x1000 | 0x40000 | 0x80000 | 0x400000;
    [StructLayout(LayoutKind.Sequential)] private struct Info
    {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint Volume, High, Low, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern uint GetDriveType(string path);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern uint QueryDosDevice(string name, char[] result, int size);
    public static string Canonical(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Length > 1800 || !System.Text.RegularExpressions.Regex.IsMatch(path, @"^[A-Za-z]:[\\/]") || path.Any(c => c < 32) || path[2..].Contains(':')) throw new ArgumentException("UnsupportedPath");
        foreach (var p in path[3..].Replace('/', '\\').Split('\\'))
            if (p is "." or ".." || p.EndsWith('.') || p.EndsWith(' ') || System.Text.RegularExpressions.Regex.IsMatch(p, @"^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)")) throw new ArgumentException("NonCanonicalPath");
        var full = Path.GetFullPath(path).Replace('/', '\\'); return full.Length > 3 ? full.TrimEnd('\\') : full;
    }
    public static bool Within(string path, string root) => path.Equals(root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
    public static InventoryTarget Capture(string objectId, string? parentId, string path, Coverage coverage = Coverage.Complete, bool hardProtected = false)
    {
        path = Canonical(path); using var h = Open(path, false); var i = Read(h);
        return new(objectId, parentId, path, (i.Attributes & 16) != 0 ? TargetKind.Directory : TargetKind.File, Identity(i), (i.Attributes & 16) != 0 ? null : ((long)i.High << 32) | i.Low,
            DateTime.FromFileTimeUtc(((long)i.Write.dwHighDateTime << 32) | (uint)i.Write.dwLowDateTime).Ticks, i.Attributes, i.Links, coverage, hardProtected);
    }
    private static SafeFileHandle Open(string path, bool content)
    {
        var h = CreateFile(path, content ? 0x80000000u : 0, 1, IntPtr.Zero, 3, 0x02300000, IntPtr.Zero);
        if (h.IsInvalid) { h.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); } return h;
    }
    private static Info Read(SafeFileHandle h) { if (!GetFileInformationByHandle(h, out var i)) throw new Win32Exception(Marshal.GetLastWin32Error()); return i; }
    private static string Identity(Info i) => $"{i.Volume:X8}:{i.IndexHigh:X8}{i.IndexLow:X8}:{i.Creation.dwHighDateTime:X8}{i.Creation.dwLowDateTime:X8}";
    private static void Matches(Info i, InventoryTarget t)
    {
        var ticks = DateTime.FromFileTimeUtc(((long)i.Write.dwHighDateTime << 32) | (uint)i.Write.dwLowDateTime).Ticks;
        if ((i.Attributes & Unsafe) != 0 || Identity(i) != t.FileIdentity || (t.Kind == TargetKind.File && ((((long)i.High << 32) | i.Low) != t.LogicalBytes || ticks != t.ModifiedUtcTicks || i.Links != t.LinkCount)) || ((i.Attributes & 16) != 0) != (t.Kind == TargetKind.Directory)) throw new IOException("InventoryChangedOrUnsafe");
    }
    internal static IDisposable Guard(InventoryEvidenceSnapshot snapshot, InventoryTarget target, InventoryIndex? index = null, BudgetMeter? meter = null)
    {
        var root = Path.GetPathRoot(target.Path)!; var dos = new char[2048];
        if (GetDriveType(root) != 3 || QueryDosDevice(root[..2], dos, dos.Length) == 0 || !new string(dos).StartsWith(@"\Device\HarddiskVolume", StringComparison.OrdinalIgnoreCase)) throw new IOException("UnsupportedVolume");
        var handles = new List<SafeFileHandle>();
        try
        {
            var ancestors = new Stack<string>(); for (string? p = target.Kind == TargetKind.Directory ? target.Path : Path.GetDirectoryName(target.Path); p != null; p = Path.GetDirectoryName(p)) ancestors.Push(p);
            while (ancestors.TryPop(out var p))
            {
                meter?.Metadata();
                var h = Open(p, false); handles.Add(h); var info = Read(h);
                if ((info.Attributes & Unsafe) != 0 || (info.Attributes & 16) == 0) throw new IOException("UnsafeAncestor");
                // No per-open full inventory dictionary construction. The exploration index is built once.
                var t = index?.AtPath(p);
                if (t == null && index == null)
                {
                    for (InventoryTarget? current = target; current != null; current = current.ParentId != null ? snapshot.Targets[current.ParentId] : null)
                        if (string.Equals(current.Path, p, StringComparison.OrdinalIgnoreCase)) { t = current; break; }
                }
                if (t != null) Matches(info, t);
            }
            return new GuardHandles(handles);
        }
        catch { foreach (var h in handles) h.Dispose(); throw; }
    }
    internal static void Validate(InventoryEvidenceSnapshot snapshot, InventoryTarget target, InventoryIndex? index = null, BudgetMeter? meter = null)
    {
        using var guard = Guard(snapshot, target, index, meter); meter?.Metadata(); using var h = Open(target.Path, false); Matches(Read(h), target);
    }
    internal static FileStream ReadContent(InventoryEvidenceSnapshot snapshot, InventoryTarget target, BudgetMeter? meter = null)
    {
        // Caller retains Guard for the entire read; this handle also denies writes/deletes.
        meter?.Metadata(); var h = Open(target.Path, true);
        try { Matches(Read(h), target); return new FileStream(h, FileAccess.Read); }
        catch { h.Dispose(); throw; }
    }
    internal static bool OwnedByCurrentUser(InventoryTarget t)
    {
        var owner = t.Kind == TargetKind.Directory ? new DirectoryInfo(t.Path).GetAccessControl().GetOwner(typeof(SecurityIdentifier)) : new FileInfo(t.Path).GetAccessControl().GetOwner(typeof(SecurityIdentifier));
        return owner?.Value == WindowsIdentity.GetCurrent().User?.Value;
    }
    private sealed class GuardHandles(List<SafeFileHandle> handles) : IDisposable { public void Dispose() { foreach (var h in handles) h.Dispose(); } }
}
