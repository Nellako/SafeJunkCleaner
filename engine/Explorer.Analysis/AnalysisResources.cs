using System.Runtime.InteropServices;

namespace SafeJunkCleaner.Explorer.Analysis;

/// <summary>A per-operation resource allowance, not a file-count limit.</summary>
public sealed class AnalysisResources
{
    public long ManagedLimitBytes { get; }
    private AnalysisResources(long bytes) => ManagedLimitBytes = bytes;
    public static AnalysisResources Capture()
    {
        long total = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;
        long available = total;
        if (OperatingSystem.IsWindows())
        {
            var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
            if (GlobalMemoryStatusEx(ref memory))
            { total = (long)Math.Min((ulong)long.MaxValue, memory.TotalPhysical); available = (long)Math.Min((ulong)long.MaxValue, memory.AvailablePhysical); }
        }
        return new(ChooseLimit(total, available));
    }
    // Bound to both physical capacity and presently available memory. Allow at most
    // one eighth of installed RAM and half of free RAM, never more than 4 GiB.
    // This is a checked managed working allowance, not a peak process-memory promise.
    public static long ChooseLimit(long physicalBytes, long availableBytes) =>
        Math.Max(64L * 1024 * 1024, Math.Min(4L * 1024 * 1024 * 1024,
            Math.Min(Math.Max(0, physicalBytes) / 8, Math.Max(0, availableBytes) / 2)));
    public bool Exceeded => GC.GetTotalMemory(false) > ManagedLimitBytes;
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length, MemoryLoad;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile,
            TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
}
