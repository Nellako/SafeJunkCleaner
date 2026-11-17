using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text.Json;
using SafeJunkCleaner.Explorer;
using SafeJunkCleaner.Explorer.Execution;

internal static class Program
{
    private static readonly List<object> results = [];
    private static string root = "";
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static void Reject(Action action, string code)
    {
        try { action(); } catch (InvalidOperationException ex) when (ex.Message == code) { return; }
        throw new Exception("Expected " + code);
    }
    private static void Run(string name, Action action)
    {
        try { action(); results.Add(new { Name = name, Passed = true, Error = "" }); Console.WriteLine("PASS " + name); }
        catch (Exception ex) { results.Add(new { Name = name, Passed = false, Error = ex.ToString() }); Console.WriteLine("FAIL " + name + " " + ex); }
    }
    private static string Id() => Guid.NewGuid().ToString("D");
    private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
    private static ApprovalDraft Draft() => new(1, Id(), Id(), Id(), "scope", "suggestion", "policy", WindowsIdentity.GetCurrent().User!.Value,
        DateTimeOffset.UtcNow, true, [], [], [], [], 0, "artificial", "artificial");
    private static Dictionary<string, string> Inventory(string path) => Directory.GetFiles(path).Where(p => !p.EndsWith("execution.lock")).ToDictionary(p => Path.GetFileName(p)!, Hash);
    private static void Same(Dictionary<string, string> before, string path) => Check(before.OrderBy(x => x.Key).SequenceEqual(Inventory(path).OrderBy(x => x.Key)), "All original artifact names and bytes retained");
    private static string PathFor(string name) => Path.Combine(root, name);
    private static void Fill(string path, int total)
    {
        int count = Directory.GetFiles(path).Count(p => !p.EndsWith("execution.lock"));
        for (int i = count; i < total; i++) using (File.Create(Path.Combine(path, Id() + ".ledger"))) { }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateHardLink(string link, string existing, IntPtr reserved);
    public static int Main(string[] args)
    {
        root = TestEvidence.CreateFixture(args.Single(), "approval-maintenance-strict");
        Run("active-confirmed-executed retention and explicit confirmation", () =>
        {
            string path = PathFor("retention"); using var s = new WindowsApprovalStore(path);
            var active = Draft(); var confirmed = Draft(); var executed = Draft(); var stale = Draft();
            foreach (var d in new[] { active, confirmed, executed, stale }) s.PutDraft(d);
            var seal = new ApprovalSeal(1, Id(), DateTimeOffset.UtcNow, confirmed); s.PutSeal(seal);
            using (s.Claim(executed.DraftId)) { } s.Append(executed.DraftId, new(Id(), "NotAttempted", "ArtificialOnlyNoRecycle", 0));
            var before = Inventory(path); var keep = new HashSet<string> { active.DraftId };
            Reject(() => s.ArchiveUnconfirmed(keep, false), "ExplicitApprovalArchiveConfirmationRequired"); Same(before, path);
            var result = s.ArchiveUnconfirmed(keep, true);
            Check(result.DraftsArchived == 1 && File.Exists(Path.Combine(result.ArchivePath, stale.DraftId + ".draft")), "Only stale draft archived");
            foreach (var entry in before.Where(x => x.Key != stale.DraftId + ".draft")) Check(File.Exists(Path.Combine(path, entry.Key)) && Hash(Path.Combine(path, entry.Key)) == entry.Value, "Protected artifact intact " + entry.Key);
            using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(result.ArchivePath, "manifest.json")));
            using var completed = JsonDocument.Parse(File.ReadAllText(Path.Combine(result.ArchivePath, "completed.json")));
            Check(manifest.RootElement.GetProperty("Status").GetString() == "Pending" && completed.RootElement.GetProperty("Status").GetString() == "Completed" && completed.RootElement.GetProperty("MovedFiles").GetArrayLength() == 1 && !File.Exists(Path.Combine(result.ArchivePath, "partial.json")), "Accurate complete manifest");
            Check(Hash(Path.Combine(result.ArchivePath, "manifest.json")) == result.ManifestSha256, "Manifest hash exact");
            var retained = s.GetStorageInfo(keep);
            Check(retained.RetainedArchiveDirectories == 1 && retained.RetainedArchiveBytes == Directory.GetFiles(result.ArchivePath).Sum(p => new FileInfo(p).Length) && retained.RetainedArchiveUnavailableEntries == 0, "Retained archive actual bytes count separately from active quota");
        });
        Run("4095 files rejects execution before side effects", () =>
        {
            string path = PathFor("capacity4095"); using var s = new WindowsApprovalStore(path); Fill(path, 4095);
            var before = Inventory(path); Reject(() => s.RequireExecutionCapacity(1), "ApprovalExecutionFileReserve"); Same(before, path);
            Check(s.GetStorageInfo(new HashSet<string>()).Files == 4095, "4095 legal checked artifacts");
        });
        Run("4094 preflight then claim and ledger fit exactly 4096", () =>
        {
            string path = PathFor("capacity4094"); using var s = new WindowsApprovalStore(path); Fill(path, 4094);
            var before = Inventory(path); s.RequireExecutionCapacity(1); Same(before, path);
            string id = Id(); using (s.Claim(id)) { } s.Append(id, new(Id(), "NotAttempted", "PreflightOnlyNoRecycle", 0));
            Check(s.GetStorageInfo(new HashSet<string>()).Files == 4096 && s.ReadLedger(id).Single().Reason == "PreflightOnlyNoRecycle", "Exactly 4096 with retained claim ledger");
            foreach (var p in before) Check(Hash(Path.Combine(path, p.Key)) == p.Value, "Capacity originals intact");
        });
        Run("locked second draft reports partial and complete conservation", () =>
        {
            string path = PathFor("partial"); using var s = new WindowsApprovalStore(path); var a = Draft(); var b = Draft(); s.PutDraft(a); s.PutDraft(b);
            var before = Inventory(path); Exception? failure = null;
            using (var held = new FileStream(Path.Combine(path, b.DraftId + ".draft"), FileMode.Open, FileAccess.Read, FileShare.None))
            { try { s.ArchiveUnconfirmed(new HashSet<string>(), true); } catch (Exception ex) { failure = ex; } }
            var archives = Directory.GetDirectories(root, "partial-retained-*");
            var all = Directory.GetFiles(path, "*.draft").Concat(archives.SelectMany(p => Directory.GetFiles(p, "*.draft"))).ToArray();
            Check(all.Length == before.Count && all.Select(Path.GetFileName).Distinct().Count() == before.Count && all.All(p => before[Path.GetFileName(p)] == Hash(p)), "Complete artifact conservation independent of enumeration order");
            Check(failure is ApprovalArchiveException, "Expected ApprovalArchiveException with ArchivePath/MovedFiles, actual " + failure?.GetType().FullName);
            var error = (ApprovalArchiveException)failure!; Check(archives.Contains(error.ArchivePath), "Exception archive path exists");
            using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(error.ArchivePath, "manifest.json")));
            using var partial = JsonDocument.Parse(File.ReadAllText(Path.Combine(error.ArchivePath, "partial.json")));
            var moved = Directory.GetFiles(error.ArchivePath, "*.draft").Select(Path.GetFileName).Order().ToArray();
            Check(error.MovedFiles.Order().SequenceEqual(moved) && partial.RootElement.GetProperty("MovedFiles").EnumerateArray().Select(x => x.GetString()).Order().SequenceEqual(moved), "MovedFiles exact full set");
            Check(manifest.RootElement.GetProperty("Status").GetString() == "Pending" && manifest.RootElement.GetProperty("Files").GetArrayLength() == 2 && partial.RootElement.GetProperty("Status").GetString() == "Partial" && !File.Exists(Path.Combine(error.ArchivePath, "completed.json")), "Accurate pending partial not completed");
        });
        Run("tampered draft rejected without displacement", () =>
        {
            string path = PathFor("tamper"); using var s = new WindowsApprovalStore(path); var d = Draft(); s.PutDraft(d);
            File.WriteAllBytes(Path.Combine(path, d.DraftId + ".draft"), [1, 2, 3, 4]); var before = Inventory(path);
            bool refused = false; try { s.ReadDraft(d.DraftId); } catch (System.ComponentModel.Win32Exception) { refused = true; }
            Check(refused, "Tampered DPAPI rejected"); Same(before, path);
        });
        Run("hardlinked artifact rejected", () =>
        {
            string path = PathFor("links"); using var s = new WindowsApprovalStore(path); string original = Path.Combine(path, Id() + ".ledger"); File.WriteAllText(original, "artificial");
            Check(CreateHardLink(Path.Combine(root, "retained-hardlink"), original, IntPtr.Zero), "Create synthetic hardlink " + Marshal.GetLastWin32Error());
            Reject(() => s.GetStorageInfo(new HashSet<string>()), "UnsafeArtifact"); Check(File.ReadAllText(original) == "artificial", "Linked source retained");
        });
        Run("unknown artifact rejected", () =>
        {
            string path = PathFor("unknown"); using var s = new WindowsApprovalStore(path); File.WriteAllText(Path.Combine(path, "unknown.artifact"), "artificial");
            var before = Inventory(path); Reject(() => s.GetStorageInfo(new HashSet<string>()), "UnknownApprovalArtifact"); Same(before, path);
        });
        Run("byte quota refuses new Prepare retaining claim ledger", () =>
        {
            string path = PathFor("bytes"); using var s = new WindowsApprovalStore(path); string id = Id(); using (s.Claim(id)) { } s.Append(id, new(Id(), "NotAttempted", "Retain", 0));
            using (var padding = new FileStream(Path.Combine(path, Id() + ".ledger"), FileMode.CreateNew)) padding.SetLength(268435456);
            string claim = Hash(Path.Combine(path, id + ".claim")), ledger = Hash(Path.Combine(path, id + ".ledger"));
            string input = PathFor("quota-input"); Directory.CreateDirectory(input); string file = Path.Combine(input, "synthetic.tmp"); File.WriteAllText(file, "artificial only");
            var facts = new WindowsExecutionFacts(PathFor("facts-state")); var snapshot = facts.Read(file, false).Snapshot with { ObjectId = Id() };
            string task = Id(), group = Id(); var source = new Source(new(task, Id(), "scope", "suggestion", "policy", facts.OwnerSid, [input], [new(group, ProcessingClass.VerifiedCache, false, "Artificial test", [Id()], [snapshot], [])]));
            var recycler = new NeverRecycle(); var executor = new ApprovalExecutor(source, facts, s, recycler);
            Reject(() => executor.PrepareApproval(task, [group]), "ApprovalStorageQuota");
            Check(!s.GetStorageInfo(new HashSet<string>()).CanPrepare && Directory.GetFiles(path, "*.draft").Length == 0 && Hash(Path.Combine(path, id + ".claim")) == claim && Hash(Path.Combine(path, id + ".ledger")) == ledger && recycler.Calls == 0 && File.ReadAllText(file) == "artificial only", "Quota retained all existing evidence no side effects");
        });
        Run("execution evidence lease blocks capacity theft and releases cleanly", () =>
        {
            string path = PathFor("reservation"); using var s = new WindowsApprovalStore(path); var draft = Draft(); s.PutDraft(draft);
            string approval = Id();
            using (var budget = s.ReserveExecution(approval, 1))
            {
                Reject(() => s.PutDraft(Draft()), "ExecutionEvidenceReservationActive");
                Reject(() => s.PutSeal(new(1, Id(), DateTimeOffset.UtcNow, draft)), "ExecutionEvidenceReservationActive");
                Reject(() => { using var other = s.Claim(Id()); }, "ExecutionEvidenceReservationActive");
                Reject(() => s.ArchiveUnconfirmed(new HashSet<string>(), true), "ExecutionEvidenceReservationActive");
                using (s.Claim(approval)) { }
                string objectId = Id(); s.Append(approval, new(objectId, "Attempting", "WriteAheadIntent", 0));
                s.Append(approval, new(objectId, "Skipped", new string('x', 1000), 0));
                var ledger = s.ReadLedger(approval);
                Check(ledger.Length == 2 && ledger[1].Reason.Length <= 400 && ledger[1].Reason.Contains("ReasonTruncated"), "Reserved records durably fit bounded evidence");
            }
            s.PutDraft(Draft());
            Check(s.IsClaimed(approval) && s.ReadLedger(approval).Length == 2, "Lease release restores preparing but retains claim and ledger");
        });
        Run("failure-report write failure preserves structured archive context", () =>
        {
            string path = PathFor("reportfailure"); using var s = new WindowsApprovalStore(path);
            for (int i = 0; i < 12; i++) s.PutDraft(Draft());
            var last = Draft(); s.PutDraft(last); var before = Inventory(path);
            using var held = new FileStream(Path.Combine(path, last.DraftId + ".draft"), FileMode.Open, FileAccess.Read, FileShare.None);
            using var watcher = new FileSystemWatcher(root, "reportfailure-retained-*") { NotifyFilter = NotifyFilters.DirectoryName };
            var reportBlocked = new ManualResetEventSlim();
            watcher.Created += (_, change) =>
            {
                try { Directory.CreateDirectory(Path.Combine(change.FullPath, "partial.json")); reportBlocked.Set(); } catch { }
            };
            watcher.EnableRaisingEvents = true;
            ApprovalArchiveException? failure = null;
            try { s.ArchiveUnconfirmed(new HashSet<string>(), true); } catch (ApprovalArchiveException ex) { failure = ex; }
            Check(reportBlocked.Wait(TimeSpan.FromSeconds(2)), "Synthetic failure report path blocked before error reporting");
            Check(failure != null && Directory.Exists(failure.ArchivePath) && failure.InnerException != null, "Structured recovery context survives second I/O failure");
            Check(Directory.Exists(Path.Combine(failure!.ArchivePath, "partial.json")) && !File.Exists(Path.Combine(failure.ArchivePath, "completed.json")), "No false completed marker when report failed");
            var all = Directory.GetFiles(path, "*.draft").Concat(Directory.GetFiles(failure.ArchivePath, "*.draft")).ToArray();
            held.Dispose();
            Check(all.Length == before.Count && all.All(p => before[Path.GetFileName(p)] == Hash(p)), "All original draft bytes conserved");
            Check(failure.MovedFiles.Length == Directory.GetFiles(failure.ArchivePath, "*.draft").Length, "Exception contains exact moved set even without partial file");
        });
        File.WriteAllText(Path.Combine(root, "result.json"), JsonSerializer.Serialize(new { Fixture = root, Results = results }, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine("Evidence " + root); return results.Any(x => !JsonSerializer.SerializeToElement(x).GetProperty("Passed").GetBoolean()) ? 1 : 0;
    }
    private sealed class Source(ApprovalSource value) : IApprovalSource { public ApprovalSource Read(string task) => value; }
    private sealed class NeverRecycle : IRecycleOnly
    {
        public int Calls; public bool IsAvailable => false; public string UnavailableReason => "TestNoShell";
        public RecycleResult Recycle(FileSnapshot expected, CancellationToken token) { Calls++; throw new Exception("No recycle authorized"); }
    }
}
