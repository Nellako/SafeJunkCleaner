using SafeJunkCleaner.Explorer;
using SafeJunkCleaner.Explorer.Execution;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

// Independent verification cases for engine/Explorer.Execution.
// Every destructive action stays inside this process's own GUID sandbox. The only
// native recycle calls are fake IWindowsRecycleApi implementations; no real Shell
// recycle is performed here; real COM coverage is explicitly not executed.

var sandbox = new OwnedSandbox(args.Single());
var facts = new WindowsExecutionFacts(Path.Combine(sandbox.Root, "state"));
int assertions = 0, totalCases = 0, failedCases = 0;
var failures = new List<string>();

void Check(bool value, string reason)
{
    assertions++;
    if (!value) throw new Exception(reason);
}
Exception? Capture(Action action)
{
    try { action(); return null; } catch (Exception ex) { return ex; }
}
void Throws(Action action, string reason, string? fragment = null)
{
    var ex = Capture(action);
    Check(ex != null, reason + ": expected exception, none thrown");
    if (fragment != null) Check(ex!.Message.Contains(fragment, StringComparison.Ordinal), reason + ": unexpected message " + ex.Message);
}
void Case(string name, Action body)
{
    totalCases++;
    var before = assertions;
    try
    {
        body();
        Console.WriteLine($"CASE {name}: PASS ({assertions - before} assertions)");
    }
    catch (Exception ex)
    {
        failedCases++;
        failures.Add(name + " :: " + ex.Message);
        Console.WriteLine($"CASE {name}: FAIL ({assertions - before} assertions) :: {ex.Message}");
    }
}
FileSnapshot Snapshot(string path, bool hash)
{
    var snapshot = facts.Read(path, hash).Snapshot;
    return snapshot with { ObjectId = Guid.NewGuid().ToString("D") };
}
ApprovalSource SourceFor(string root, SuggestionSnapshot suggestion, string? taskId = null) => new(
    taskId ?? Guid.NewGuid().ToString("D"), Guid.NewGuid().ToString("D"), "scope-v1", "suggestion-v1", "policy-v1",
    facts.OwnerSid, [root], [suggestion]);
SuggestionSnapshot Suggestion(string group, ProcessingClass classification, FileSnapshot[] files, FileSnapshot[]? keepers = null) =>
    new(group, classification, false, "Only explicitly displayed temporary files are moved; no storage recovery claim",
        [Guid.NewGuid().ToString("D")], files, keepers ?? []);
Fixture Build(ApprovalSource value, SandboxRecycler? recycler = null, string storeName = "approvals")
{
    var source = new MutableSource(value);
    var storePath = Path.Combine(value.Roots[0], storeName);
    var store = new WindowsApprovalStore(storePath);
    var actualRecycler = recycler ?? new SandboxRecycler(sandbox, facts);
    var executor = new ApprovalExecutor(source, facts, store, actualRecycler);
    return new Fixture(source, store, actualRecycler, executor, value.Suggestions.SelectMany(s => s.Files).ToArray(),
        value.Suggestions[0].SuggestionId, storePath);
}
Fixture Create(int count = 1, ProcessingClass classification = ProcessingClass.VerifiedCache, bool duplicate = false,
    bool candidateHash = true, bool keeperHash = true)
{
    var dir = sandbox.NewDirectory();
    var files = Enumerable.Range(0, count).Select(n =>
    {
        var path = Path.Combine(dir, $"item-{n}.tmp"); sandbox.Write(path, "owned-verification-content"); return Snapshot(path, candidateHash);
    }).ToArray();
    FileSnapshot[] keepers = [];
    if (duplicate)
    {
        var keeper = Path.Combine(dir, "keeper.tmp"); sandbox.Write(keeper, "owned-verification-content");
        keepers = [Snapshot(keeper, keeperHash)];
    }
    var group = Guid.NewGuid().ToString("D");
    return Build(SourceFor(dir, Suggestion(group, classification, files, keepers)));
}
void RunSta(Action body)
{
    Exception? failure = null;
    var thread = new Thread(() => { try { body(); } catch (Exception ex) { failure = ex; } });
    thread.SetApartmentState(ApartmentState.STA); thread.Start(); thread.Join();
    if (failure != null) throw failure;
}
void RunMta(Action body)
{
    Exception? failure = null;
    var thread = new Thread(() => { try { body(); } catch (Exception ex) { failure = ex; } });
    thread.SetApartmentState(ApartmentState.MTA); thread.Start(); thread.Join();
    if (failure != null) throw failure;
}

Case("V01 seal artifact tamper rejected before any claim/effect", () =>
{
    using var f = Create();
    var draft = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var approval = f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash);
    var sealPath = Path.Combine(f.StorePath, approval + ".seal");
    var bytes = File.ReadAllBytes(sealPath); bytes[^1] ^= 0x5A; File.WriteAllBytes(sealPath, bytes);
    Throws(() => f.Executor.ExecuteApproved(approval), "tampered seal rejected");
    Check(!File.Exists(Path.Combine(f.StorePath, approval + ".claim")), "tampered seal rejected before claim file creation");
    Check(f.Recycler.Calls == 0, "tampered seal has no recycle effect");
    Check(f.Files.All(s => File.Exists(s.Path)), "tampered seal preserves candidates");
});

Case("V02 seal cannot be transplanted to another approval id", () =>
{
    using var f = Create();
    var d1 = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var a1 = f.Executor.ConfirmApproval(d1.DraftId, d1.DisplayHash);
    var d2 = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var a2 = f.Executor.ConfirmApproval(d2.DraftId, d2.DisplayHash);
    File.Copy(Path.Combine(f.StorePath, a2 + ".seal"), Path.Combine(f.StorePath, a1 + ".seal"), true);
    Throws(() => f.Executor.ExecuteApproved(a1), "transplanted seal rejected", "InvalidSeal");
    Check(f.Recycler.Calls == 0, "transplanted seal has no recycle effect");
});

Case("V03 protected ledger rejects byte tamper and plaintext injection", () =>
{
    using var f = Create(count: 2);
    var draft = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var approval = f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash);
    Check(f.Executor.ExecuteApproved(approval).Status == "Completed", "ledger fixture completed");
    var ledgerPath = Path.Combine(f.StorePath, approval + ".ledger");
    var original = File.ReadAllBytes(ledgerPath);
    Check(original.Length > 4, "ledger has protected records");
    var tampered = (byte[])original.Clone(); tampered[tampered.Length - 2] ^= 0x01; File.WriteAllBytes(ledgerPath, tampered);
    Throws(() => f.Executor.GetExecutionResult(approval), "ledger byte tamper rejected");
    File.WriteAllBytes(ledgerPath, original);
    File.AppendAllText(ledgerPath, "{\"ObjectId\":\"forged\",\"Status\":\"Recycled\"}\n", Encoding.ASCII);
    Throws(() => f.Executor.GetExecutionResult(approval), "unprotected ledger line rejected");
});

Case("V04 injected recycler failure is PartialOrInterrupted and never Success", () =>
{
    using var f = Create(count: 2);
    var draft = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var approval = f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash);
    var failing = new FailingRecycler(failAt: 2, f.Recycler);
    var executor = new ApprovalExecutor(f.Source, facts, f.Store, failing);
    var result = executor.ExecuteApproved(approval);
    Check(result.Status == "PartialOrInterrupted", "exceptions cannot report Completed");
    Check(result.Entries.Any(e => e.Status == "Recycled") && result.Entries.Any(e => e.Status == "UnknownOrFailed"), "ledger keeps both outcomes");
    Check(result.RecycledLogicalBytes > 0 && result.RecycledLogicalBytes < f.Files.Sum(s => s.Size), "only confirmed recycle bytes counted");
    Check(f.Files.Count(s => File.Exists(s.Path)) == 1, "exactly one candidate remains");
    Check(failing.Calls == 2 && f.Recycler.Calls == 1, "one effect then one failed attempt");
    Throws(() => executor.ExecuteApproved(approval), "failed approval is not replayable");
});

Case("V05 revision/root/classification/owner changes invalidate approval; Unknown has no permission", () =>
{
    using var unknown = Create(classification: ProcessingClass.Unknown);
    Throws(() => unknown.Executor.PrepareApproval(unknown.Source.Value.TaskId, [unknown.Group]),
        "Unknown classification cannot be prepared", "HardProtectedSuggestion");
    Check(unknown.Recycler.Calls == 0, "Unknown has no side effect");

    using var f = Create();
    var draft = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var original = f.Source.Value;
    f.Source.Value = original with { ScopeRevision = "scope-v2" };
    Throws(() => f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash), "scope revision change invalidates draft", "ApprovalRevisionChanged");
    f.Source.Value = original with { Roots = [sandbox.NewDirectory()] };
    Throws(() => f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash), "root change invalidates draft", "ApprovalRevisionChanged");
    f.Source.Value = original with { Suggestions = [original.Suggestions[0] with { Classification = ProcessingClass.Unknown }] };
    Throws(() => f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash), "classification change invalidates draft", "SuggestionsChanged");
    f.Source.Value = original with { OwnerSid = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null).Value };
    Throws(() => f.Executor.PrepareApproval(original.TaskId, [f.Group]), "foreign owner task rejected", "TaskOwnerMismatch");
    f.Source.Value = original;
});

Case("V06 candidate outside approved roots rejected at prepare", () =>
{
    var root = sandbox.NewDirectory();
    var outside = sandbox.NewDirectory();
    var outsideFile = Path.Combine(outside, "outside.tmp"); sandbox.Write(outsideFile, "outside-root-content");
    var group = Guid.NewGuid().ToString("D");
    using var f = Build(SourceFor(root, Suggestion(group, ProcessingClass.VerifiedCache, [Snapshot(outsideFile, true)])), storeName: "approvals-scope");
    Throws(() => f.Executor.PrepareApproval(f.Source.Value.TaskId, [group]), "outside-root file rejected", "OutsideScopeOrRoot");
    Check(File.Exists(outsideFile), "outside-root file untouched");
    Check(f.Recycler.Calls == 0, "outside-root has no side effect");
});

Case("V07 hardlink candidate rejected; directory candidate rejected", () =>
{
    // This run uses only a retained fixture beneath the caller evidence parent.
    var localTemp = sandbox.NewDirectory();
    Directory.CreateDirectory(localTemp);
    try
    {
        var target = Path.Combine(localTemp, "target.tmp");
        File.WriteAllText(target, "hardlink-content");
        var link = Path.Combine(localTemp, "link.tmp");
        if (!NativeLinks.CreateHardLink(link, target, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateHardLink failed");
        Check(facts.Read(link, false).Links == 2, "fixture really has two hard links");
        var group = Guid.NewGuid().ToString("D");
        using var f = Build(SourceFor(localTemp, Suggestion(group, ProcessingClass.VerifiedCache, [Snapshot(link, true)])), storeName: "approvals-link");
        Throws(() => f.Executor.PrepareApproval(f.Source.Value.TaskId, [group]), "hardlinked candidate rejected", "UnsafeOrOccupiedFile");
        Check(File.Exists(target) && File.Exists(link), "hardlinks untouched");
        Check(f.Recycler.Calls == 0, "hardlink has no side effect");
    }
    finally
    {
        Console.WriteLine($"Retained hardlink fixture: {localTemp}; no cleanup performed");
    }

    var parent = sandbox.NewDirectory();
    var directory = Path.Combine(parent, "directory-candidate");
    Directory.CreateDirectory(directory);
    sandbox.AssertOwned(Path.Combine(directory, "child.tmp"));
    var directorySnapshot = facts.Read(directory, false).Snapshot with { ObjectId = Guid.NewGuid().ToString("D") };
    var directoryGroup = Guid.NewGuid().ToString("D");
    using var d = Build(SourceFor(parent, Suggestion(directoryGroup, ProcessingClass.VerifiedCache, [directorySnapshot])), storeName: "approvals-directory");
    Throws(() => d.Executor.PrepareApproval(d.Source.Value.TaskId, [directoryGroup]), "directory candidate rejected", "UnsafeOrOccupiedFile");
    Check(Directory.Exists(directory) && d.Recycler.Calls == 0, "directory candidate untouched");
});

Case("V08 missing or unverified retained keeper blocks execution", () =>
{
    using var missing = Create(duplicate: true);
    var draft = missing.Executor.PrepareApproval(missing.Source.Value.TaskId, [missing.Group]);
    var approval = missing.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash);
    var keeper = missing.Source.Value.Suggestions[0].RetainedCopies[0];
    sandbox.AssertOwned(keeper.Path); sandbox.Move(keeper.Path, Path.Combine(sandbox.NewDirectory(), "retained-keeper.tmp"));
    var result = missing.Executor.ExecuteApproved(approval);
    Check(result.Status == "Rejected", "missing keeper rejects whole approval");
    Check(missing.Recycler.Calls == 0, "missing keeper has no recycle effect");
    Check(missing.Files.All(s => File.Exists(s.Path)), "missing keeper preserves candidates");

    var dir = sandbox.NewDirectory();
    var candidate = Path.Combine(dir, "candidate.tmp"); sandbox.Write(candidate, "duplicate-content");
    var keeperPath = Path.Combine(dir, "keeper.tmp"); sandbox.Write(keeperPath, "duplicate-content");
    var group = Guid.NewGuid().ToString("D");
    using var unverified = Build(SourceFor(dir, Suggestion(group, ProcessingClass.VerifiedCache,
        [Snapshot(candidate, false)], [Snapshot(keeperPath, true)])), storeName: "approvals-unverified");
    Throws(() => unverified.Executor.PrepareApproval(unverified.Source.Value.TaskId, [group]),
        "retained duplicate without content hash rejected", "UnverifiedDuplicate");
    Check(unverified.Recycler.Calls == 0, "unverified duplicate has no side effect");
});

Case("V09 read-only candidate is rejected, not silently cleaned", () =>
{
    using var f = Create();
    var draft = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var approval = f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash);
    var candidate = f.Files[0].Path; sandbox.AssertOwned(candidate);
    var before = File.GetAttributes(candidate); File.SetAttributes(candidate, before | FileAttributes.ReadOnly);
    var result = f.Executor.ExecuteApproved(approval);
    Check(result.Status == "Rejected", "read-only candidate rejects approval");
    Check(result.Entries.Any(e => e.Reason.Contains("UnsafeOrOccupiedFile", StringComparison.Ordinal)), "read-only reason recorded");
    Check(f.Recycler.Calls == 0 && File.Exists(candidate), "read-only candidate remains");
    Check((File.GetAttributes(candidate) & FileAttributes.ReadOnly) != 0, "read-only attribute unchanged");
    File.SetAttributes(candidate, before);
});

Case("V10 store ACL private and DPAPI hides draft content; inherited ACL store rejected", () =>
{
    using var f = Create();
    var draft = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var directoryAcl = new DirectoryInfo(f.StorePath).GetAccessControl();
    Check(directoryAcl.AreAccessRulesProtected, "store ACL is protected from inheritance");
    Check(directoryAcl.GetOwner(typeof(SecurityIdentifier))?.Value == facts.OwnerSid, "store owned by current user");
    var onlyCurrentUser = true;
    foreach (FileSystemAccessRule rule in directoryAcl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        if (rule.AccessControlType == AccessControlType.Allow && rule.IdentityReference.Value != facts.OwnerSid) onlyCurrentUser = false;
    Check(onlyCurrentUser, "store ACL allows only the current user");
    var draftPath = Path.Combine(f.StorePath, draft.DraftId + ".draft");
    var draftText = Encoding.UTF8.GetString(File.ReadAllBytes(draftPath));
    Check(!draftText.Contains("SuggestionId", StringComparison.Ordinal) && !draftText.Contains(f.Files[0].Path, StringComparison.Ordinal)
        && !draftText.Contains("DisplayHash", StringComparison.Ordinal), "draft content is DPAPI-protected, not plaintext");
    var inherited = sandbox.NewDirectory();
    Throws(() => { using var store = new WindowsApprovalStore(inherited); }, "pre-created inherited ACL directory rejected", "InheritedStateAcl");
});

Case("V11 native recycler default-disabled, flags exact, STA required", () =>
{
    var dir = sandbox.NewDirectory();
    var path = Path.Combine(dir, "native.tmp"); sandbox.Write(path, "native-content");
    var expected = Snapshot(path, true);
    var fake = new FakeNative();
    var disabled = new WindowsRecycleOnly(facts, NativeRecycleMode.Disabled, fake);
    Check(!disabled.IsAvailable, "native recycler defaults disabled");
    var disabledResult = disabled.Recycle(expected, default);
    Check(!disabledResult.Recycled && disabledResult.Reason == "NativeRecycleDisabledUntilExplicitHostEnablement", "disabled recycler cannot succeed");
    Check(fake.Calls == 0, "disabled recycler never calls native API");
    Check(WindowsRecycleOnly.OperationFlags == 0x00183404u, "operation flags exact RecycleOnDelete|EarlyFailure|NoErrorUI|Silent|NoConnectedElements|NoRecursion");
    Check((WindowsRecycleOnly.OperationFlags & 0x10u) == 0 && (WindowsRecycleOnly.OperationFlags & 0x40u) == 0, "no YesToAll/NOCONFIRMATION and no ALLOWUNDO fallback flag");
    RunMta(() =>
    {
        Check(Thread.CurrentThread.GetApartmentState() == ApartmentState.MTA, "boundary thread is MTA");
        var recycler = new WindowsRecycleOnly(facts, NativeRecycleMode.RecycleOnly, fake);
        var result = recycler.Recycle(expected, default);
        Check(!result.Recycled && result.Reason == "NativeRecycleRequiresSTA", "MTA call rejected before native API");
        Check(fake.Calls == 0, "MTA call never reaches native API");
    });
});

Case("V12 native outcome without confirmed recycle item is never Success", () =>
{
    var dir = sandbox.NewDirectory();
    var path = Path.Combine(dir, "native-outcome.tmp"); sandbox.Write(path, "native-outcome-content");
    var expected = Snapshot(path, true);
    RunSta(() =>
    {
        Check(Thread.CurrentThread.GetApartmentState() == ApartmentState.STA, "native test thread is STA");
        var successFake = new FakeNative();
        var success = new WindowsRecycleOnly(facts, NativeRecycleMode.RecycleOnly, successFake);
        var successResult = success.Recycle(expected, default);
        Check(successResult.Recycled && successResult.Reason == "ShellConfirmedRecycleItem_LogicalBytesNotFreedBytes", "confirmed recycle item accepted");
        Check((successFake.OperationFlags & WindowsRecycleOnly.RecycleOnDelete) != 0
            && (successFake.OperationFlags & WindowsRecycleOnly.EarlyFailure) != 0, "native call receives recycle-only flags");
        void ExpectFailure(string label, Action<FakeNative> setup)
        {
            var fake = new FakeNative(); setup(fake);
            var result = new WindowsRecycleOnly(facts, NativeRecycleMode.RecycleOnly, fake).Recycle(expected, default);
            Check(!result.Recycled && result.Reason == "NativeFailureOrUnknownOutcome_NoRetry", label);
        }
        ExpectFailure("negative HRESULT rejected", x => x.HResult = -1);
        ExpectFailure("aborted operation rejected", x => x.Aborted = true);
        ExpectFailure("missing PostDelete rejected", x => x.PostDeleteSeen = false);
        ExpectFailure("negative delete HRESULT rejected", x => x.DeleteHResult = -1);
        var missingItem = new FakeNative { NewItem = false };
        Throws(() => new WindowsRecycleOnly(facts, NativeRecycleMode.RecycleOnly, missingItem).Recycle(expected, default),
            "missing recycle item is contract violation", "RecycleContractViolation_OutcomeUnknown_NoRetry");
        Check(File.Exists(path), "fake native calls never touch the file");
    });
});

Case("V13 concurrent execution has a single claim and one effect set", () =>
{
    using var f = Create(count: 2);
    var draft = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var approval = f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash);
    using var start = new ManualResetEventSlim(false);
    var results = new ExecutionResult?[2]; var errors = new Exception?[2];
    var threads = Enumerable.Range(0, 2).Select(i => new Thread(() =>
    {
        start.Wait();
        try { results[i] = f.Executor.ExecuteApproved(approval); } catch (Exception ex) { errors[i] = ex; }
    }) { IsBackground = true }).ToArray();
    foreach (var thread in threads) thread.Start();
    start.Set();
    foreach (var thread in threads) Check(thread.Join(TimeSpan.FromSeconds(60)), "concurrent worker completed");
    Check(results.Count(r => r != null) == 1 && errors.Count(e => e != null) == 1, "exactly one claim wins");
    var winner = results.First(r => r != null)!;
    var loser = errors.First(e => e != null)!;
    Console.WriteLine($"V13 winner={winner.Status} recycled={winner.Entries.Count(e => e.Status == "Recycled")}; loser={loser.GetType().Name}:{loser.Message}");
    Check(winner.Status == "Completed" && winner.Entries.Count(e => e.Status == "Recycled") == 2, "winner executes exactly two items");
    Check(f.Recycler.Calls == 2, "no duplicated recycle calls");
    Check(f.Files.All(s => !File.Exists(s.Path)), "candidates recycled once");
});

Case("V14 file added after prepare is not inherited by approval", () =>
{
    using var f = Create();
    var draft = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var added = Path.Combine(f.Source.Value.Roots[0], "added-after-prepare.tmp"); sandbox.Write(added, "added-later");
    var approval = f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash);
    var result = f.Executor.ExecuteApproved(approval);
    Check(result.Status == "Completed" && result.Entries.Count(e => e.Status == "Recycled") == 1, "approval still executes only displayed item");
    Check(File.Exists(added), "post-prepare file survives");
    Check(f.Files.All(s => !File.Exists(s.Path)), "displayed candidate moved");
});

Console.WriteLine($"VERIFICATION {assertions} assertions; cases={totalCases}; failed={failedCases}; Sandbox={sandbox.Root}");
foreach (var failure in failures) Console.WriteLine("FAILED " + failure);
Environment.ExitCode = failedCases == 0 ? 0 : 1;

sealed class MutableSource(ApprovalSource value) : IApprovalSource
{
    public ApprovalSource Value { get; set; } = value;
    public ApprovalSource Read(string taskId) => taskId == Value.TaskId ? Value : throw new InvalidOperationException("UnknownTask");
}
sealed record Fixture(MutableSource Source, WindowsApprovalStore Store, SandboxRecycler Recycler, ApprovalExecutor Executor,
    FileSnapshot[] Files, string Group, string StorePath) : IDisposable
{
    public void Dispose() => Store.Dispose();
}
sealed class FakeNative : IWindowsRecycleApi
{
    public uint CallbackFlags = WindowsRecycleOnly.RecycleIfPossible;
    public int HResult;
    public bool Aborted;
    public bool PostDeleteSeen = true;
    public int DeleteHResult;
    public bool NewItem = true;
    public uint OperationFlags;
    public int Calls;
    public bool Vetoed;
    public NativeRecycleOutcome DeleteOne(string path, uint operationFlags, Func<uint, string, int> preDelete)
    {
        Calls++; OperationFlags = operationFlags;
        var callback = preDelete(CallbackFlags, path);
        if (callback < 0)
        {
            Vetoed = true;
            return new(WindowsRecycleOnly.Abort, true, false, WindowsRecycleOnly.Abort, false, true);
        }
        return new(HResult, Aborted, PostDeleteSeen, DeleteHResult, NewItem, true);
    }
}
sealed class OwnedSandbox
{
    private static readonly HashSet<string> Registered = new(StringComparer.OrdinalIgnoreCase);
    private readonly string marker;
    public string Root { get; }
    public OwnedSandbox(string parent)
    {
        Directory.CreateDirectory(parent);
        Root = TestEvidence.CreateFixture(parent, "execution-verification-fixture");
        Directory.CreateDirectory(Root);
        marker = $"{Environment.ProcessId}:{Guid.NewGuid():D}";
        File.WriteAllText(Path.Combine(Root, ".execution-verification-owner"), marker);
        Registered.Add(Root);
    }
    public void AssertOwned(string path)
    {
        if (!Registered.Contains(Root) || File.ReadAllText(Path.Combine(Root, ".execution-verification-owner")) != marker
            || !WindowsFacts.Within(WindowsFacts.Canonical(path), Root) || path == Root)
            throw new InvalidOperationException("NotCurrentProcessOwnedSandbox");
        using var guard = WindowsFacts.Guard(Path.GetDirectoryName(path)!);
    }
    public string NewDirectory()
    {
        var dir = Path.Combine(Root, Guid.NewGuid().ToString("D"));
        Directory.CreateDirectory(dir);
        return dir;
    }
    public void Write(string path, string text)
    {
        AssertOwned(path);
        File.WriteAllText(path, text);
    }
    public void Move(string source, string destination)
    {
        AssertOwned(source); AssertOwned(destination);
        TestEvidence.MoveWithManifest(Root, source, destination);
    }
}
sealed class SandboxRecycler(OwnedSandbox sandbox, WindowsExecutionFacts facts) : IRecycleOnly
{
    private int calls;
    public bool IsAvailable => true;
    public string UnavailableReason => "";
    public int Calls => Volatile.Read(ref calls);
    public RecycleResult Recycle(FileSnapshot expected, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        sandbox.AssertOwned(expected.Path);
        var actual = facts.Read(expected.Path, expected.ContentSha256 != null);
        if (actual.Snapshot.Identity != expected.Identity || actual.Snapshot.Size != expected.Size
            || actual.Snapshot.ModifiedUtc != expected.ModifiedUtc) throw new InvalidOperationException("ChangedBeforeSimulatedMove");
        var destination = Path.Combine(Path.GetDirectoryName(expected.Path)!, "simulated-recycle");
        Directory.CreateDirectory(destination);
        sandbox.Move(expected.Path, Path.Combine(destination, Guid.NewGuid().ToString("D") + "-" + Path.GetFileName(expected.Path)));
        Interlocked.Increment(ref calls);
        return new(true, "SimulatedMoveWithinOwnedSandbox_NotRealRecycle");
    }
}
sealed class FailingRecycler(int failAt, SandboxRecycler inner) : IRecycleOnly
{
    private int calls;
    public bool IsAvailable => true;
    public string UnavailableReason => "";
    public int Calls => Volatile.Read(ref calls);
    public RecycleResult Recycle(FileSnapshot expected, CancellationToken cancellationToken)
    {
        if (Interlocked.Increment(ref calls) == failAt) throw new InvalidOperationException("InjectedRecycleFailure");
        return inner.Recycle(expected, cancellationToken);
    }
}
static class NativeLinks
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern bool CreateHardLink(string fileName, string existingFileName, IntPtr securityAttributes);
}
