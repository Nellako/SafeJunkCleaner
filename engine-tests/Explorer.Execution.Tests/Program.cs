using SafeJunkCleaner.Explorer;
using SafeJunkCleaner.Explorer.Execution;
using System.Security.Cryptography;

var sandbox = new OwnedSandbox(args.Single());
int assertions = 0;
void Check(bool value, string reason) { assertions++; if (!value) throw new Exception(reason); }
void Reject(Action action, string reason) { bool rejected = false; try { action(); } catch (Exception) { rejected = true; } Check(rejected, reason); }
var facts = new WindowsExecutionFacts(Path.Combine(sandbox.Root, "state"));
FileSnapshot Snapshot(string path, bool hash = false)
{
    var f = facts.Read(path, hash).Snapshot;
    return f with { ObjectId = Guid.NewGuid().ToString("D") };
}
Fixture Create(int count = 1, ProcessingClass classification = ProcessingClass.VerifiedCache, bool duplicate = false)
{
    var dir = sandbox.NewDirectory();
    var files = Enumerable.Range(0, count).Select(n => { var p = Path.Combine(dir, $"item-{n}.tmp"); sandbox.Write(p, "owned-test-content"); return Snapshot(p, duplicate); }).ToArray();
    FileSnapshot[] keepers = [];
    if (duplicate) { var p = Path.Combine(dir, "keeper.tmp"); sandbox.Write(p, "owned-test-content"); keepers = [Snapshot(p, true)]; }
    var task = Guid.NewGuid().ToString("D"); var group = Guid.NewGuid().ToString("D");
    var source = new Source(new(task, Guid.NewGuid().ToString("D"), "scope-1", "suggestion-1", "policy-1", facts.OwnerSid, [dir],
        [new(group, classification, false, "Only the displayed temporary files are moved; no immediate free space claim", [Guid.NewGuid().ToString("D")], files, keepers)]));
    var store = new WindowsApprovalStore(Path.Combine(dir, "approvals"));
    var recycler = new SandboxRecycler(sandbox, facts);
    return new(source, store, recycler, new(source, facts, store, recycler), files, group);
}
using (var f = Create(2))
{
    var draft = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    Check(draft.Items.Length == 2 && draft.RecycleOnly, "draft exact set");
    var returned = draft.Items[0].File.Path;
    Reject(() => f.Executor.ConfirmApproval(draft.DraftId, new string('0', 64)), "wrong display hash");
    var approval = f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash);
    Reject(() => f.Executor.ConfirmApproval(draft.DraftId, draft.DisplayHash), "repeat confirmation");
    var extra = Path.Combine(Path.GetDirectoryName(returned)!, "new-after-confirm.tmp"); sandbox.Write(extra, "new");
    var result = f.Executor.ExecuteApproved(approval);
    Check(result.Status == "Completed" && result.Entries.Count(e => e.Status == "Recycled") == 2, "exact execution");
    Check(File.Exists(extra) && f.Files.All(s => !File.Exists(s.Path)), "new file excluded");
    Check(result.RecycledLogicalBytes == f.Files.Sum(s => s.Size), "logical bytes only");
    Reject(() => f.Executor.ExecuteApproved(approval), "claim cannot replay");
}
foreach (var classification in new[] { ProcessingClass.UserData, ProcessingClass.Photos, ProcessingClass.Backup, ProcessingClass.Mixed, ProcessingClass.System, ProcessingClass.Unknown })
{
    using var f = Create(classification: classification);
    Reject(() => f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]), "hard protected class " + classification);
    Check(f.Recycler.Calls == 0, "no protected side effect");
}
using (var f = Create(2))
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    sandbox.Write(f.Files[1].Path, "changed-size");
    Check(f.Executor.ExecuteApproved(a).Status == "Rejected" && f.Recycler.Calls == 0, "full preflight before first effect");
    Reject(() => f.Executor.ExecuteApproved(a), "rejected plan not replayable");
}
using (var f = Create(duplicate: true))
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    sandbox.Write(f.Source.Value.Suggestions[0].RetainedCopies[0].Path, "changed-retained-copy");
    Check(f.Executor.ExecuteApproved(a).Status == "Rejected" && f.Recycler.Calls == 0, "changed retained copy blocks deletion");
}
using (var f = Create())
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    f.Source.Value = f.Source.Value with { PolicyRevision = "policy-2" };
    Reject(() => f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash), "revision invalidates draft");
}
using (var f = Create())
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    using var token = new CancellationTokenSource(); token.Cancel();
    Check(f.Executor.ExecuteApproved(a, token.Token).Status == "Cancelled" && f.Recycler.Calls == 0, "cancel no effect");
    Reject(() => f.Executor.ExecuteApproved(a), "cancel cannot replay");
}
using (var f = Create())
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    var blocked = new ApprovalExecutor(f.Source, facts, f.Store, new UnavailableWindowsRecycler());
    Check(blocked.ExecuteApproved(a).Entries.Single().Status == "Skipped" && File.Exists(f.Files[0].Path), "unavailable native API skips");
}
using (var f = Create())
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    using (f.Store.Claim(a)) { f.Store.Append(a, new(f.Files[0].ObjectId, "Attempting", "crash-simulation", 0)); }
    Reject(() => f.Executor.ExecuteApproved(a), "crash intent not replayable");
    Check(f.Executor.GetExecutionResult(a).Status == "PartialOrInterrupted", "unknown intent visible");
}
using (var f = Create(2))
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    Check(f.Executor.GetExecutionResult(a).Status == "NotStarted" && !f.Store.IsClaimed(a), "unrequested approval has no execution claim");
    using (f.Store.Claim(a)) { }
    f.Store.Dispose();
    using var reopened = new WindowsApprovalStore(Path.Combine(Path.GetDirectoryName(f.Files[0].Path)!, "approvals"));
    var executor = new ApprovalExecutor(f.Source, facts, reopened, f.Recycler);
    var result = executor.GetExecutionResult(a);
    Check(result.Status == "PartialOrInterrupted" && result.Entries.Length == 0 && result.RecycledLogicalBytes == 0,
        "EXEC-02 durable claim without ledger is interrupted after DPAPI reopen");
    Reject(() => executor.ExecuteApproved(a), "claim-only interruption does not restore authority");
    Check(f.Recycler.Calls == 0 && f.Files.All(s => File.Exists(s.Path)), "claim-only interruption does not fabricate effects");
}
using (var f = Create(2))
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    var faultStore = new FailIntentStore(f.Store, d.Items[1].File.ObjectId);
    var executing = new ApprovalExecutor(f.Source, facts, faultStore, f.Recycler);
    bool interrupted = false;
    try { executing.ExecuteApproved(a); } catch (IOException ex) when (ex.Message == "ArtificialSecondIntentWriteFailure") { interrupted = true; }
    Check(interrupted && f.Recycler.Calls == 1, "real executor interrupted at second write-ahead intent after one effect");
    f.Store.Dispose();
    using var reopened = new WindowsApprovalStore(Path.Combine(Path.GetDirectoryName(f.Files[0].Path)!, "approvals"));
    var executor = new ApprovalExecutor(f.Source, facts, reopened, f.Recycler);
    // Historical reporting must use the authenticated seal, not renew source eligibility.
    f.Source.Value = f.Source.Value with { PolicyRevision = "later-policy" };
    var result = executor.GetExecutionResult(a);
    Check(result.Status == "PartialOrInterrupted", "EXEC-01 successful prefix of sealed set is not Completed after DPAPI reopen");
    Check(result.Entries.Length == 2 && result.Entries[0].Status == "Attempting" && result.Entries[1].Status == "Recycled" &&
        result.RecycledLogicalBytes == d.Items[0].File.Size, "interrupted result retains actual ledger and bytes without fabricated suffix");
    Check(f.Files.Count(s => File.Exists(s.Path)) == 1 && reopened.IsClaimed(a), "failed intent retains untouched suffix and consumed claim");
    f.Source.Value = f.Source.Value with { PolicyRevision = "policy-1" };
    Reject(() => executor.ExecuteApproved(a), "interrupted prefix cannot replay even when source again matches");
}
foreach (var boundary in new[] { "Missing", "WrongObject", "ExtraObject", "WrongBytes", "LatestUnknown" })
{
    using var f = Create(2);
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    using (f.Store.Claim(a))
    {
        foreach (var item in d.Items.Take(boundary == "Missing" ? 1 : 2))
            f.Store.Append(a, new(boundary == "WrongObject" && item == d.Items[1] ? Guid.NewGuid().ToString("D") : item.File.ObjectId,
                "Recycled", "ArtificialLedgerBoundary", boundary == "WrongBytes" ? item.File.Size + 1 : item.File.Size));
        if (boundary == "ExtraObject") f.Store.Append(a, new(Guid.NewGuid().ToString("D"), "Recycled", "ArtificialExtra", 0));
        if (boundary == "LatestUnknown") f.Store.Append(a, new(d.Items[0].File.ObjectId, "UnknownOrFailed", "ArtificialLatest", 0));
    }
    Check(f.Executor.GetExecutionResult(a).Status == "PartialOrInterrupted", "Completed requires exact sealed final set: " + boundary);
    Check(f.Recycler.Calls == 0 && f.Files.All(s => File.Exists(s.Path)), "ledger boundary fixture makes no file effect: " + boundary);
}
using (var f = Create(2))
using (var cancel = new CancellationTokenSource())
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    f.Recycler.AfterRecycle = cancel.Cancel;
    var result = f.Executor.ExecuteApproved(a, cancel.Token);
    Check(result.Status == "Cancelled" && result.Entries.Count(e => e.Status == "Recycled") == 1 &&
        result.Entries.Count(e => e.Status == "NotAttempted") == 1 && result.RecycledLogicalBytes == d.Items[0].File.Size,
        "cancellation after one effect preserves truthful prefix and untouched suffix");
    Check(f.Executor.GetExecutionResult(a).Status == "PartialOrInterrupted" && f.Files.Count(s => File.Exists(s.Path)) == 1,
        "historical cancellation does not mean nothing was processed");
    Reject(() => f.Executor.ExecuteApproved(a), "cancelled prefix cannot replay");
}
using (var f = Create())
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]);
    var path = Path.Combine(Path.GetDirectoryName(f.Files[0].Path)!, "approvals", d.DraftId + ".draft");
    using (var stream = new FileStream(path, FileMode.Open, FileAccess.Write)) { stream.Position = stream.Length - 1; stream.WriteByte(0x42); }
    Reject(() => f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash), "DPAPI tampering rejected");
}
using (var f = Create())
{
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    using var occupied = new FileStream(f.Files[0].Path, FileMode.Open, FileAccess.Read, FileShare.Read);
    Check(f.Executor.ExecuteApproved(a).Status == "Rejected", "occupied file rejected");
}
using (var f = Create(duplicate: true))
{
    var keeper = f.Source.Value.Suggestions[0].RetainedCopies[0];
    sandbox.AssertOwned(keeper.Path); File.SetAttributes(keeper.Path, File.GetAttributes(keeper.Path) | FileAttributes.ReadOnly);
    var d = f.Executor.PrepareApproval(f.Source.Value.TaskId, [f.Group]); var a = f.Executor.ConfirmApproval(d.DraftId, d.DisplayHash);
    Check(f.Executor.ExecuteApproved(a).Status == "Completed" && File.Exists(keeper.Path), "read-only retained copy remains protected");
}
using (var f = Create())
{
    Exception? failure = null;
    var thread = new Thread(() =>
    {
        try
        {
        var expected = f.Files[0];
        var fake = new FakeNative { Flags = 0 };
        var recycler = new WindowsRecycleOnly(facts, NativeRecycleMode.RecycleOnly, fake);
        Check(!recycler.Recycle(expected, default).Recycled && fake.Vetoed, "no recycle callback flag veto");
        fake.Flags = WindowsRecycleOnly.RecycleIfPossible;
        Check(recycler.Recycle(expected, default).Recycled, "fake native confirms recycle item");
        fake.NewItem = false;
        Reject(() => recycler.Recycle(expected, default), "native missing recycle item is contract violation");
        fake.NewItem = true;
        var dry = new WindowsRecycleOnly(facts, NativeRecycleMode.VetoBeforeDelete, fake);
        Check(!dry.Recycle(expected, default).Recycled && fake.Vetoed, "native dry-run always vetoes");
        Check((fake.OperationFlags & 0x80000) != 0 && (fake.OperationFlags & 0x100000) != 0 && (fake.OperationFlags & 0x10) == 0, "native required flags no yes-to-all");
        Check(File.Exists(expected.Path), "native API fake performs no filesystem operation");
        // Explicit mock-only veto coverage. Real Shell/COM is prohibited in this run.
        sandbox.AssertOwned(expected.Path);
        var before = facts.Read(expected.Path, true).Snapshot;
        var veto = new WindowsRecycleOnly(facts, NativeRecycleMode.VetoBeforeDelete, fake);
        var vetoResult = veto.Recycle(expected, default);
        var after = facts.Read(expected.Path, true).Snapshot;
        Check(vetoResult.Reason == "PreDeleteVetoObserved" && !vetoResult.Recycled, "mock PreDelete veto reached");
        Check(before == after, "mock veto preserves identity size time and hash");
        Console.WriteLine($"MOCK VETO ONLY; real COM NOT tested: {vetoResult.Reason}; Identity={after.Identity}; SHA256={after.ContentSha256}; real recycle NOT tested");
        }
        catch (Exception ex) { failure = ex; }
    });
    thread.SetApartmentState(ApartmentState.STA);
    thread.Start(); thread.Join(); if (failure != null) throw failure;
}
// Trusted BuildArtifact exception is narrower than a UI class or a bin directory name.
{
    var project = sandbox.NewDirectory(); var output = Path.Combine(project, "bin", "Debug", "net10.0"); Directory.CreateDirectory(output);
    var markerPath = Path.Combine(project, "Owned.csproj"); sandbox.Write(markerPath, "<Project Sdk=\"Microsoft.NET.Sdk\" />");
    var dllPath = Path.Combine(output, "Owned.dll"); sandbox.Write(dllPath, "artificial-generated-dll-not-executable");
    var candidate = Snapshot(dllPath, true); var marker = Snapshot(markerPath, true);
    var groupId = Guid.NewGuid().ToString("D"); var evidenceId = Guid.NewGuid().ToString("D");
    var source = new Source(new(Guid.NewGuid().ToString("D"), Guid.NewGuid().ToString("D"), "scope-1", "suggestion-1", "policy-1", facts.OwnerSid, [project],
        [new(groupId, ProcessingClass.ReviewSuggested, false, "Exact generated DLL; rebuild needed", [evidenceId], [candidate], [])]));
    var authorization = new BuildArtifactAuthorization(source.Value, groupId, candidate, project, marker, evidenceId, true);
    var provider = new BuildAuthorizations(source, authorization);
    var classifiedFacts = new WindowsExecutionFacts(Path.Combine(sandbox.Root, "state"), provider);
    Check(facts.HardProtection(dllPath) != null && classifiedFacts.HardProtection(dllPath) == null, "only trusted exact BuildArtifact DLL exception");
    using var store = new WindowsApprovalStore(Path.Combine(project, "approvals"));
    var recycler = new SandboxRecycler(sandbox, classifiedFacts);
    var executor = new ApprovalExecutor(source, classifiedFacts, store, recycler);
    var draft = executor.PrepareApproval(source.Value.TaskId, [groupId]);
    Check(draft.Items.Single().File == candidate, "project DLL exact candidate approved");
    var approved = executor.ConfirmApproval(draft.DraftId, draft.DisplayHash);
    provider.Current = authorization with { TrustedIndexClassifiedBuildArtifact = false };
    Reject(() => executor.PrepareApproval(source.Value.TaskId, [groupId]), "fake UI build class is not trusted analysis evidence");
    provider.Current = authorization;
    source.Value = source.Value with { PolicyRevision = "policy-2" };
    Check(classifiedFacts.HardProtection(dllPath) != null, "stale provider revision fails closed");
    source.Value = authorization.CurrentSource;
    sandbox.Write(markerPath, "<Project Sdk=\"Microsoft.NET.Sdk\"><!--changed--></Project>");
    Check(classifiedFacts.HardProtection(dllPath) != null, "project marker change revokes exception");
    sandbox.Write(markerPath, "<Project Sdk=\"Microsoft.NET.Sdk\" />");
    // Exact marker mtime is part of the trusted snapshot; refresh only this artificial trusted index.
    marker = Snapshot(markerPath, true); authorization = authorization with { ProjectMarker = marker }; provider.Current = authorization;
    Check(executor.ExecuteApproved(approved).Status == "Completed" && recycler.Calls == 1, "project DLL simulated recycle only");
    var installedRoot = Path.Combine(sandbox.NewDirectory(), "Program Files", "ArtificialInstalledApp");
    Directory.CreateDirectory(Path.Combine(installedRoot, "bin"));
    var installedMarker = Path.Combine(installedRoot, "Fake.csproj"); sandbox.Write(installedMarker, "<Project Sdk=\"Microsoft.NET.Sdk\" />");
    var installedDll = Path.Combine(installedRoot, "bin", "Installed.dll"); sandbox.Write(installedDll, "artificial-installed-dll");
    var installedCandidate = Snapshot(installedDll, true);
    var installedSource = new Source(source.Value with { Roots = [installedRoot], Suggestions = [new(groupId, ProcessingClass.ReviewSuggested, false, "fake build", [evidenceId], [installedCandidate], [])] });
    var installedProvider = new BuildAuthorizations(installedSource, new(installedSource.Value, groupId, installedCandidate, installedRoot, Snapshot(installedMarker, true), evidenceId, true));
    var installedFacts = new WindowsExecutionFacts(Path.Combine(sandbox.Root, "state"), installedProvider);
    Check(installedFacts.HardProtection(installedDll) != null, "installed DLL denied despite false trusted-build proof");
    using var installedStore = new WindowsApprovalStore(Path.Combine(Path.GetDirectoryName(installedRoot)!, "approvals"));
    Reject(() => new ApprovalExecutor(installedSource, installedFacts, installedStore, new UnavailableWindowsRecycler()).PrepareApproval(installedSource.Value.TaskId, [groupId]), "installed DLL cannot prepare");
    var document = Path.Combine(output, "Private.docx"); sandbox.Write(document, "artificial-user-document");
    var documentCandidate = Snapshot(document, true);
    var documentSource = new Source(source.Value with { Suggestions = [new(groupId, ProcessingClass.ReviewSuggested, false, "fake build", [evidenceId], [documentCandidate], [])] });
    var documentProvider = new BuildAuthorizations(documentSource, new(documentSource.Value, groupId, documentCandidate, project, marker, evidenceId, true));
    var documentFacts = new WindowsExecutionFacts(Path.Combine(sandbox.Root, "state"), documentProvider);
    Check(documentFacts.HardProtection(document) != null, "user document fake build class cannot override extension");
    var sourceFile = Path.Combine(project, "obj", "Private.cs"); Directory.CreateDirectory(Path.GetDirectoryName(sourceFile)!); sandbox.Write(sourceFile, "// artificial source");
    Check(classifiedFacts.HardProtection(sourceFile) != null, "source code hard protected");
}
Check(facts.HardProtection(Path.Combine(sandbox.Root, "photo.jpg")) != null, "photo extension hard protection");
Check(facts.HardProtection(Path.Combine(sandbox.Root, "Backups", "item.tmp")) != null, "backup path hard protection");
Console.WriteLine($"PASS {assertions} assertions; Sandbox={sandbox.Root}; simulated in-sandbox moves only; real Recycle Bin NOT tested");

sealed class BuildAuthorizations(Source source, BuildArtifactAuthorization authorization) : ITrustedBuildArtifactAuthorizations
{
    public BuildArtifactAuthorization? Current = authorization;
    public BuildArtifactAuthorization? ReadCurrent(string canonicalPath)
    {
        var p = Current;
        return p != null && p.Candidate.Path == canonicalPath && source.Value == p.CurrentSource ? p : null;
    }
}
sealed class FakeNative : IWindowsRecycleApi
{
    public uint Flags = WindowsRecycleOnly.RecycleIfPossible;
    public bool NewItem = true, Vetoed;
    public uint OperationFlags;
    public NativeRecycleOutcome DeleteOne(string path, uint operationFlags, Func<uint, string, int> preDelete)
    {
        OperationFlags = operationFlags; Vetoed = preDelete(Flags, path) < 0;
        return new(Vetoed ? WindowsRecycleOnly.Abort : 0, Vetoed, !Vetoed, 0, !Vetoed && NewItem, true);
    }
}
sealed class Source(ApprovalSource value) : IApprovalSource
{
    public ApprovalSource Value { get; set; } = value;
    public ApprovalSource Read(string taskId) => taskId == Value.TaskId ? Value : throw new InvalidOperationException("UnknownTask");
}
sealed class FailIntentStore(WindowsApprovalStore inner, string secondObjectId) : IApprovalStore
{
    public void PutDraft(ApprovalDraft draft) => inner.PutDraft(draft);
    public ApprovalDraft ReadDraft(string id) => inner.ReadDraft(id);
    public void PutSeal(ApprovalSeal seal) => inner.PutSeal(seal);
    public ApprovalSeal ReadSeal(string id) => inner.ReadSeal(id);
    public IDisposable Claim(string id) => inner.Claim(id);
    public bool IsClaimed(string id) => inner.IsClaimed(id);
    public ExecutionEntry[] ReadLedger(string id) => inner.ReadLedger(id);
    public void Append(string id, ExecutionEntry entry)
    {
        if (entry.ObjectId == secondObjectId && entry.Status == "Attempting") throw new IOException("ArtificialSecondIntentWriteFailure");
        inner.Append(id, entry);
    }
}
sealed record Fixture(Source Source, WindowsApprovalStore Store, SandboxRecycler Recycler, ApprovalExecutor Executor, FileSnapshot[] Files, string Group) : IDisposable
{ public void Dispose() => Store.Dispose(); }
sealed class OwnedSandbox
{
    private static readonly HashSet<string> Registered = new(StringComparer.OrdinalIgnoreCase);
    private readonly string marker;
    public string Root { get; }
    public OwnedSandbox(string parent)
    {
        Root = TestEvidence.CreateFixture(parent, "execution-fixture");
        marker = $"{Environment.ProcessId}:{Guid.NewGuid():D}"; File.WriteAllText(Path.Combine(Root, ".execution-test-owner"), marker); Registered.Add(Root);
    }
    public void AssertOwned(string path)
    {
        if (!Registered.Contains(Root) || File.ReadAllText(Path.Combine(Root, ".execution-test-owner")) != marker || !WindowsFacts.Within(WindowsFacts.Canonical(path), Root) || path == Root)
            throw new InvalidOperationException("NotCurrentProcessOwnedSandbox");
        using var guard = WindowsFacts.Guard(Path.GetDirectoryName(path)!);
    }
    public string NewDirectory() { var dir = Path.Combine(Root, Guid.NewGuid().ToString("D")); Directory.CreateDirectory(dir); return dir; }
    public void Write(string path, string text) { AssertOwned(path); File.WriteAllText(path, text); }
    public void Move(string source, string destination) { AssertOwned(source); AssertOwned(destination); TestEvidence.MoveWithManifest(Root, source, destination); }
}
sealed class SandboxRecycler(OwnedSandbox sandbox, WindowsExecutionFacts facts) : IRecycleOnly
{
    public bool IsAvailable => true;
    public string UnavailableReason => "";
    public int Calls { get; private set; }
    public Action? AfterRecycle { get; set; }
    public RecycleResult Recycle(FileSnapshot expected, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested(); sandbox.AssertOwned(expected.Path);
        var actual = facts.Read(expected.Path, expected.ContentSha256 != null);
        if (actual.Snapshot.Identity != expected.Identity || actual.Snapshot.Size != expected.Size || actual.Snapshot.ModifiedUtc != expected.ModifiedUtc) throw new InvalidOperationException("ChangedBeforeSimulatedMove");
        var destination = Path.Combine(Path.GetDirectoryName(expected.Path)!, "simulated-recycle"); Directory.CreateDirectory(destination);
        sandbox.Move(expected.Path, Path.Combine(destination, Guid.NewGuid().ToString("D") + ".tmp")); Calls++; AfterRecycle?.Invoke();
        return new(true, "SimulatedMoveWithinOwnedSandbox_NotRealRecycle");
    }
}
