using System.Runtime.InteropServices;

namespace SafeJunkCleaner.Explorer.Execution;

public enum NativeRecycleMode { Disabled, VetoBeforeDelete, RecycleOnly }
public sealed record NativeRecycleOutcome(int HResult, bool Aborted, bool PostDeleteSeen, int DeleteHResult, bool RecycleItemPresent, bool PreDeleteSeen = false);
public interface IWindowsRecycleApi
{
    NativeRecycleOutcome DeleteOne(string path, uint operationFlags, Func<uint, string, int> preDelete);
}

public sealed class WindowsRecycleOnly(IExecutionFacts facts, NativeRecycleMode mode = NativeRecycleMode.Disabled, IWindowsRecycleApi? api = null) : IRecycleOnly
{
    // Microsoft SetOperationFlags: RECYCLEONDELETE (Windows 8+), EARLYFAILURE + NOERRORUI.
    // Do not use NOCONFIRMATION (Yes to All), ALLOWUNDO as a guarantee, or any elevation flag.
    public const uint RecycleOnDelete = 0x00080000, EarlyFailure = 0x00100000, NoErrorUi = 0x0400,
        Silent = 0x0004, NoConnectedElements = 0x2000, NoRecursion = 0x1000;
    public const uint OperationFlags = RecycleOnDelete | EarlyFailure | NoErrorUi | Silent | NoConnectedElements | NoRecursion;
    public const uint RecycleIfPossible = 0x80;
    public const int Abort = unchecked((int)0x80004004);
    private readonly IWindowsRecycleApi native = api ?? new ShellRecycleApi();
    public bool IsAvailable => OperatingSystem.IsWindowsVersionAtLeast(6, 2) && mode != NativeRecycleMode.Disabled;
    public string UnavailableReason => "NativeRecycleDisabledUntilExplicitHostEnablement";
    public RecycleResult Recycle(FileSnapshot expected, CancellationToken cancellationToken)
    {
        if (!IsAvailable) return new(false, UnavailableReason);
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA) return new(false, "NativeRecycleRequiresSTA");
        cancellationToken.ThrowIfCancellationRequested();
        facts.ValidateLocalPath(expected.Path);
        if (facts.HardProtection(expected.Path) != null) return new(false, "HardProtectedPath");
        using var guard = facts.GuardAncestors(expected.Path, facts.Ancestors(expected.Path));
        CheckCurrent(expected);
        bool vetoed = false, permitted = false;
        var outcome = native.DeleteOne(expected.Path, OperationFlags, (flags, path) =>
        {
            try
            {
                if (cancellationToken.IsCancellationRequested || mode == NativeRecycleMode.VetoBeforeDelete || permitted
                    || !path.Equals(expected.Path, StringComparison.OrdinalIgnoreCase) || (flags & RecycleIfPossible) == 0)
                { vetoed = true; return Abort; }
                CheckCurrent(expected);
                permitted = true;
                return 0;
            }
            catch { vetoed = true; return Abort; }
        });
        if (mode == NativeRecycleMode.VetoBeforeDelete) return new(false, vetoed && outcome.PreDeleteSeen ? "PreDeleteVetoObserved" : "PreDeleteVetoNotObserved");
        if (vetoed || !permitted) return new(false, "PreDeleteVetoed");
        if (outcome.HResult < 0 || outcome.Aborted || !outcome.PostDeleteSeen || outcome.DeleteHResult < 0)
            return new(false, "NativeFailureOrUnknownOutcome_NoRetry");
        // PostDeleteItem documents non-null as the item now in the Recycle Bin.
        if (!outcome.RecycleItemPresent) throw new InvalidOperationException("RecycleContractViolation_OutcomeUnknown_NoRetry");
        return new(true, "ShellConfirmedRecycleItem_LogicalBytesNotFreedBytes");
    }
    private void CheckCurrent(FileSnapshot expected)
    {
        var now = facts.Read(expected.Path, expected.ContentSha256 != null);
        Wire.Require(!now.IsDirectory && !now.ReadOnly && !now.Unsafe && !now.Occupied && now.Links == 1 && now.Snapshot.Identity == expected.Identity
            && now.Snapshot.Size == expected.Size && now.Snapshot.ModifiedUtc == expected.ModifiedUtc
            && (expected.ContentSha256 == null || now.Snapshot.ContentSha256 == expected.ContentSha256), "ChangedBeforeNativeRecycle");
    }
}

public sealed class ShellRecycleApi : IWindowsRecycleApi
{
    internal ShellRecycleApi() { }
    public NativeRecycleOutcome DeleteOne(string path, uint operationFlags, Func<uint, string, int> preDelete)
    {
        IFileOperation? operation = null; IShellItem? item = null;
        var sink = new Sink(preDelete);
        try
        {
            operation = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(new("3ad05575-8857-4850-9277-11b85bdb8e09"), true)!)!;
            var iid = typeof(IShellItem).GUID;
            Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item));
            operation.SetOperationFlags(operationFlags);
            operation.DeleteItem(item, sink);
            var result = operation.PerformOperations();
            operation.GetAnyOperationsAborted(out var aborted);
            return new(result, aborted, sink.PostSeen, sink.DeleteResult, sink.Recycled, sink.PreSeen);
        }
        finally
        {
            GC.KeepAlive(sink);
            if (item != null) Marshal.FinalReleaseComObject(item);
            if (operation != null) Marshal.FinalReleaseComObject(operation);
        }
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem
    {
        void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint kind, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }
    [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOperation
    {
        void Advise(IFileOperationProgressSink sink, out uint cookie);
        void Unadvise(uint cookie);
        void SetOperationFlags(uint flags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        void SetProgressDialog(IntPtr dialog);
        void SetProperties(IntPtr properties);
        void SetOwnerWindow(IntPtr window);
        void ApplyPropertiesToItem(IShellItem item);
        void ApplyPropertiesToItems([MarshalAs(UnmanagedType.IUnknown)] object items);
        void RenameItem(IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, IFileOperationProgressSink sink);
        void RenameItems([MarshalAs(UnmanagedType.IUnknown)] object items, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void MoveItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, IFileOperationProgressSink sink);
        void MoveItems([MarshalAs(UnmanagedType.IUnknown)] object items, IShellItem destination);
        void CopyItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, IFileOperationProgressSink sink);
        void CopyItems([MarshalAs(UnmanagedType.IUnknown)] object items, IShellItem destination);
        void DeleteItem(IShellItem item, IFileOperationProgressSink sink);
        void DeleteItems([MarshalAs(UnmanagedType.IUnknown)] object items);
        void NewItem(IShellItem destination, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string template, IFileOperationProgressSink sink);
        [PreserveSig] int PerformOperations();
        void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }
    [ComVisible(true), Guid("04b0f1a7-9490-44bc-96e1-4296a31252e2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFileOperationProgressSink
    {
        [PreserveSig] int StartOperations();
        [PreserveSig] int FinishOperations(int result);
        [PreserveSig] int PreRenameItem(uint flags, IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostRenameItem(uint flags, IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem? created);
        [PreserveSig] int PreMoveItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostMoveItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem? created);
        [PreserveSig] int PreCopyItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostCopyItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem? created);
        [PreserveSig] int PreDeleteItem(uint flags, IShellItem item);
        [PreserveSig] int PostDeleteItem(uint flags, IShellItem item, int result, IShellItem? created);
        [PreserveSig] int PreNewItem(uint flags, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostNewItem(uint flags, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string template, uint attributes, int result, IShellItem? created);
        [PreserveSig] int UpdateProgress(uint total, uint done);
        [PreserveSig] int ResetTimer();
        [PreserveSig] int PauseTimer();
        [PreserveSig] int ResumeTimer();
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class Sink(Func<uint, string, int> preDelete) : IFileOperationProgressSink
    {
        internal bool PreSeen, PostSeen, Recycled; internal int DeleteResult = WindowsRecycleOnly.Abort;
        public int PreDeleteItem(uint flags, IShellItem item)
        {
            PreSeen = true;
            IntPtr name = IntPtr.Zero;
            try { item.GetDisplayName(0x80058000, out name); return preDelete(flags, Marshal.PtrToStringUni(name) ?? ""); }
            catch { return WindowsRecycleOnly.Abort; }
            finally { if (name != IntPtr.Zero) Marshal.FreeCoTaskMem(name); }
        }
        public int PostDeleteItem(uint flags, IShellItem item, int result, IShellItem? created)
        {
            try { PostSeen = true; DeleteResult = result; Recycled = created != null && (flags & WindowsRecycleOnly.RecycleIfPossible) != 0; return Recycled && result >= 0 ? 0 : WindowsRecycleOnly.Abort; }
            finally { if (created != null && Marshal.IsComObject(created)) Marshal.ReleaseComObject(created); }
        }
        public int StartOperations() => 0;
        public int FinishOperations(int result) => 0;
        public int PreRenameItem(uint f, IShellItem i, string n) => WindowsRecycleOnly.Abort;
        public int PostRenameItem(uint f, IShellItem i, string n, int r, IShellItem? c) => WindowsRecycleOnly.Abort;
        public int PreMoveItem(uint f, IShellItem i, IShellItem d, string n) => WindowsRecycleOnly.Abort;
        public int PostMoveItem(uint f, IShellItem i, IShellItem d, string n, int r, IShellItem? c) => WindowsRecycleOnly.Abort;
        public int PreCopyItem(uint f, IShellItem i, IShellItem d, string n) => WindowsRecycleOnly.Abort;
        public int PostCopyItem(uint f, IShellItem i, IShellItem d, string n, int r, IShellItem? c) => WindowsRecycleOnly.Abort;
        public int PreNewItem(uint f, IShellItem d, string n) => WindowsRecycleOnly.Abort;
        public int PostNewItem(uint f, IShellItem d, string n, string t, uint a, int r, IShellItem? c) => WindowsRecycleOnly.Abort;
        public int UpdateProgress(uint t, uint d) => 0;
        public int ResetTimer() => 0;
        public int PauseTimer() => 0;
        public int ResumeTimer() => 0;
    }
}
