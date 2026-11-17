using SafeJunkCleaner.Explorer;
using SafeJunkCleaner.Explorer.Host;
using SafeJunkCleaner.Explorer.Application;
using SafeJunkCleaner.Explorer.Execution;
using System.Security.Principal;

if (!OperatingSystem.IsWindows()) { Console.Error.WriteLine("Windows required."); return 2; }
if (args.Length != 0 && (args.Length != 2 || args[0] != "--state-root")) { Console.Error.WriteLine("Usage: sjc-explorer [--state-root <private-local-directory>]"); return 2; }
try
{
    string stateRoot;
    if (args.Length == 0)
    {
        var parent = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SafeJunkCleaner");
        Directory.CreateDirectory(parent);
        stateRoot = Path.Combine(parent, "explorer");
    }
    else stateRoot = args[1];
    stateRoot = WindowsFacts.Canonical(stateRoot);
    using var engine = new InventoryEngine(stateRoot);
    var rows = new HostInventoryRows(engine);
    // Approval artifacts are a private sibling, never an unknown entry inside the Inventory DB root.
    var approvalRoot = Path.Combine(Path.GetDirectoryName(stateRoot)!, Path.GetFileName(stateRoot) + "-approvals");
    using var store = new WindowsApprovalStore(approvalRoot);
    ExplorerCoordinator? coordinator = null;
    var baseFacts = new WindowsExecutionFacts(stateRoot);
    var buildProvider = new HostBuildArtifactProvider(rows, () => coordinator ?? throw new InvalidOperationException("CoordinatorNotReady"));
    var facts = new WindowsExecutionFacts(stateRoot, buildProvider);
    var recycler = new WindowsRecycleOnly(facts, NativeRecycleMode.RecycleOnly);
    using var ownedCoordinator = coordinator = new ExplorerCoordinator(rows, WindowsIdentity.GetCurrent().User!.Value, store, facts, recycler,
        snapshots => { var source = new ApprovalSourceAdapter(rows, snapshots, baseFacts, buildProvider.BindCandidateHash); buildProvider.Bind(source); return source; }, buildProvider.Register);
    await HostProtocol.RunAsync(engine, coordinator, engine.ListTasks, Console.OpenStandardInput(), Console.Out);
    return 0;
}
catch (Exception ex) { Console.Error.WriteLine("Explorer startup/shutdown failed: " + ex.GetType().Name + " " + ex.Message); return 1; }
