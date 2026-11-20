using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using static QuickClean.Verification.OwnedQuickCleanFixture;

namespace QuickClean.Verification;

internal static partial class VerifyHost
{
    private const string Scan = "Scan", Clean = "Clean";
    private static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };
    private static readonly StringComparer Paths = StringComparer.OrdinalIgnoreCase;
    private static readonly string[] FixtureCases = ["Permanent", "Replacement", "ScanCancelled", "CleanPreCancelled", "CleanCancelled", "Interrupted", "Recycled"];

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            Require(OperatingSystem.IsWindows(), "Windows is required.");
            if (args is ["_child" or "_core-child", ..]) return Child(args);
            if (args is ["query", "History"]) return GuiHistory();
            if (args is ["core-fixture", var coreParent, var coreRun, var coreCase, var hostHash] && coreCase is "History" or "Crash")
                return CoreFixture(coreParent, coreRun, coreCase, hostHash);
            if (args is ["suite", var parent, var binary, var hash, "--recycle-one"])
                return Suite(parent, binary, hash, true);
            if (args is ["suite", var parent2, var binary2, var hash2])
                return Suite(parent2, binary2, hash2, false);
            if (args is ["fixture", var evidenceParent, var name] && name != "Recycled")
                return SingleFixture(evidenceParent, name);
            if (args is ["fixture", var recycleParent, "Recycled", "--recycle-one"])
                return SingleFixture(recycleParent, "Recycled");
            throw new ArgumentException("Usage: QuickClean.Verification suite <authorized GUID parent> <sjc-quickclean.exe> <SHA256> [--recycle-one]; or fixture <authorized GUID parent> <case> [--recycle-one]");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 99;
        }
    }

    private static Artifact RequireHostHash(string expectedHash)
    {
        var actual = Art(HostAssembly().Location);
        Require(expectedHash.Length == 64 && Paths.Equals(expectedHash, actual.SHA256), "Loaded Host DLL hash differs from the requested input.");
        return actual;
    }

    private static int CoreFixture(string parent, string run, string name, string hostHash)
    {
        parent = Canonical(parent);
        run = Canonical(run);
        var owner = CheckAuthorizedCoreRun(parent, run);
        Require(owner.Case == name && !Directory.EnumerateFileSystemEntries(run).Any(), "Core case must use its own fresh launcher-bound Host run.");
        const string sampleGuid = "00000000-0000-0000-0000-000000000000";
        var sampleTask = Path.Combine(run, sampleGuid, "state", "Tasks", sampleGuid);
        // Reserve space for the longest output plus the Host's atomic and history paths.
        Require(Path.Combine(sampleTask, "history-cancel-scan.output.json").Length <= 249 &&
            Path.Combine(sampleTask, ".history-" + new string('0', 32)).Length <= 259,
            "Core Host run is too deep for Windows PowerShell 5.1 to read the operation logs; use a shallower GUID EvidenceParent.");
        var host = RequireHostHash(hostHash);
        var temp = CreatePrivate(run, "temp");
        var fixture = OwnedQuickCleanFixture.Create(run, parent, name == "Crash" ? "Interrupted" : name, owner.Nonce);
        Save(Path.Combine(run, "inputs.json"), new { Driver = Art(Assembly.GetExecutingAssembly().Location), HostReferencedAssembly = host });
        var checks = new List<CheckResult>();
        Record(name, fixture.Root, () => name == "History" ? ExerciseHistory(fixture, temp) : Exercise(fixture, temp), checks, false);
        Require(RequireHostHash(hostHash) == host, "Host input changed during fixture.");
        var result = checks.Single();
        Console.WriteLine(JsonSerializer.Serialize(new { fixture.Parent, fixture.Run, fixture.Root, Name = result.Case, result.Outcome, result.Detail }));
        return result.Outcome == "Passed" ? 0 : 1;
    }

    private static object ExerciseHistory(OwnedQuickCleanFixture fixture, string temp)
    {
        Equal(0, History(fixture, temp, "empty-history").GetArrayLength(), "A fresh fixture must not inherit history from any other state root");
        var outside = fixture.FixtureFile("outside-rules.tmp", "outside-rule sentinel", outside: true);
        var control = fixture.FixtureFile("not-selected.txt", "non-candidate sentinel");
        var target = fixture.FixtureFile("history-approved.tmp", "history permanent fixture");
        var kept = fixture.FixtureFile("history-kept.tmp", "history excluded fixture");
        var task = fixture.CreateTask();
        var scan = RunJob(fixture, task, temp, Scan, "history-scan", "");
        AssertStatus(scan.Result, "Success");
        Equal(2, Int(scan.Result, "CandidateCount"), "History success plan count");
        var plan = CheckPlan(task, scan.Result, fixture.Files, [target, kept]);
        var bytes = new FileInfo(target).Length;
        var clean = RunJob(fixture, task, temp, Clean, "history-clean", "", [plan[kept]]);
        AssertStatus(clean.Result, "Success");
        Equal(1, Int(clean.Result, "Deleted"), "History successful deletion count");
        Equal(1, Int(clean.Result, "Skipped"), "History explicit exclusion count");
        Equal(bytes, Int(clean.Result, "ProcessedBytes"), "History logical processed bytes");
        Missing(target);
        AssertFile(kept, "history excluded fixture");

        var cancelTask = fixture.CreateTask();
        var cancelTarget = fixture.FixtureFile("history-cancelled.tmp", "history cancellation fixture");
        var cancelScan = RunJob(fixture, cancelTask, temp, Scan, "history-cancel-scan", "");
        AssertStatus(cancelScan.Result, "Success");
        Equal(2, Int(cancelScan.Result, "CandidateCount"), "History cancellation plan count");
        _ = CheckPlan(cancelTask, cancelScan.Result, fixture.Files, [kept, cancelTarget]);
        var cancel = Path.Combine(cancelTask, "verify.cancel");
        WriteNew(cancel, "cancel");
        var cancelled = RunJob(fixture, cancelTask, temp, Clean, "history-cancelled", cancel);
        AssertStatus(cancelled.Result, "Cancelled");
        Equal(0, Int(cancelled.Result, "Deleted"), "Pre-cancelled history deletion count");
        Equal(0, Int(cancelled.Result, "ProcessedBytes"), "Pre-cancelled history logical bytes");
        Require(!Path.Exists(Path.Combine(cancelTask, "clean.claimed")), "Pre-cancellation claimed a plan.");

        var before = History(fixture, temp, "recorded-history");
        Equal(4, before.GetArrayLength(), "One persisted row per scan and clean attempt");
        _ = BindHistoryLog(before, task, Scan, "Success", scan);
        _ = BindHistoryLog(before, cancelTask, Scan, "Success", cancelScan);
        var completedRow = BindHistoryLog(before, task, Clean, "Success", clean);
        var cancelledRow = BindHistoryLog(before, cancelTask, Clean, "Cancelled", cancelled);
        Require(before[0].GetRawText() == cancelledRow.GetRawText() && before[2].GetRawText() == completedRow.GetRawText(),
            "History is not ordered newest-first across the two actual outcomes.");
        foreach (var (row, count, skipped) in new[] { (completedRow, 1, 1), (cancelledRow, 0, 0) })
        {
            var summary = Text(row, "Summary");
            Require(summary.Contains($"处理 {count} 个") && summary.Contains($"跳过 {skipped} 个") && !summary.Contains("实际释放"),
                "History summary did not describe actual processed/excluded counts or asserted freed space.");
        }
        Require(before.GetRawText() == History(fixture, temp, "reopened-history").GetRawText(), "Reopening changed persisted outcomes.");

        var replay = RunJob(fixture, task, temp, Clean, "history-replay", "");
        AssertFailedReplay(replay, Path.Combine(task, "clean.claimed"));
        var after = History(fixture, temp, "history-after-completed-replay");
        AssertOnlyReplayAdded(before, after, task, replay);
        AssertFile(kept, "history excluded fixture");
        AssertFile(cancelTarget, "history cancellation fixture");
        AssertFile(outside, "outside-rule sentinel");
        AssertFile(control, "non-candidate sentinel");
        return new { Task = task, CancelTask = cancelTask, Scan = scan, Clean = clean, Cancelled = cancelled, Replay = replay, BeforeReplay = before, AfterReplay = after };
    }

    private static int SingleFixture(string parent, string name)
    {
        Require(FixtureCases.Contains(name), "Unknown fixture case: " + name);
        parent = CheckAuthorizedParent(parent);
        var run = CreatePrivate(parent, Guid.NewGuid().ToString("D"));
        var temp = CreatePrivate(run, "temp");
        var fixture = OwnedQuickCleanFixture.Create(run, parent, name);
        var assembly = HostAssembly();
        Save(Path.Combine(run, "inputs.json"), new { Driver = Art(Assembly.GetExecutingAssembly().Location), HostReferencedAssembly = Art(assembly.Location) });
        var checks = new List<CheckResult>();
        Record(name, fixture.Root, () => Exercise(fixture, temp), checks, false);
        var result = checks.Single();
        Console.WriteLine(JsonSerializer.Serialize(new { fixture.Root, fixture.State, fixture.Files, Task = Directory.GetDirectories(fixture.Tasks).SingleOrDefault(),
            TaskEvidence = result.Evidence,
            Name = result.Case, result.Outcome, result.Detail }));
        return result.Outcome == "Passed" ? 0 : 1;
    }

    private static int Suite(string parent, string binary, string expectedHash, bool recycle)
    {
        parent = CheckAuthorizedParent(parent);
        binary = Canonical(binary);
        CheckPlain(binary);
        Require(Paths.Equals(Path.GetFileName(binary), "sjc-quickclean.exe") && expectedHash.Length == 64 &&
            Paths.Equals(expectedHash, Sha(binary)), "Published apphost path/hash mismatch.");
        var run = CreatePrivate(parent, Guid.NewGuid().ToString("D"));
        var temp = CreatePrivate(run, "temp");
        var before = ApphostFacts(binary);
        var assembly = HostAssembly();
        var driver = Assembly.GetExecutingAssembly().Location;
        var loadedHost = Art(assembly.Location);
        bool assemblyMatch = before.ManagedAssemblies.Any(x => Paths.Equals(x.SHA256, loadedHost.SHA256));
        Save(Path.Combine(run, "inputs.json"), new
        {
            CreatedUtc = DateTime.UtcNow, Runtime = Environment.Version.ToString(), OS = Environment.OSVersion.ToString(),
            Driver = Art(driver), HostReferencedAssembly = loadedHost, Published = before, RecycleRequested = recycle
        });
        Console.WriteLine(JsonSerializer.Serialize(new { EvidenceRoot = run }));
        Require(assemblyMatch, "Fixture driver must load the exact published sjc-quickclean.dll. Stage it beside the verification DLL in a new test directory.");
        var results = new List<CheckResult>();
        foreach (var name in FixtureCases)
        {
            if (name == "Recycled" && !recycle)
            {
                results.Add(new(name, "Skipped", null, "Pass --recycle-one to move one owned GUID fixture via Windows Shell."));
                continue;
            }
            var fixture = OwnedQuickCleanFixture.Create(run, parent, name);
            Record(name, fixture.Root, () => Exercise(fixture, temp), results);
        }
        var cliEvidence = CreatePrivate(run, "published-cli");
        foreach (var check in ProductionChecks(binary, cliEvidence, temp))
            Record(check.Name, cliEvidence, check.Test, results);
        var stable = JsonSerializer.Serialize(before) == JsonSerializer.Serialize(ApphostFacts(binary)) && loadedHost.SHA256 == Sha(assembly.Location);
        Save(Path.Combine(run, "summary.json"), new { FinishedUtc = DateTime.UtcNow, PublishedStable = stable, PublishedManagedAssemblyMatches = assemblyMatch,
            Passed = results.Count(r => r.Outcome == "Passed"), Failed = results.Count(r => r.Outcome == "Failed"), Skipped = results.Count(r => r.Outcome == "Skipped"), Results = results });
        if (!stable || results.Any(r => r.Outcome == "Failed")) return 1;
        return results.Any(r => r.Outcome == "Skipped") ? 3 : 0;
    }

    private static void Record(string name, string path, Func<object> check, List<CheckResult> results, bool show = true)
    {
        try
        {
            var value = check();
            Save(Path.Combine(path, name + ".pass.json"), value);
            results.Add(new(name, "Passed", path, null));
            if (show) Console.WriteLine("PASS " + name);
        }
        catch (Exception ex)
        {
            Save(Path.Combine(path, name + ".failure.json"), new { ex.Message, ex.StackTrace });
            results.Add(new(name, "Failed", path, ex.Message));
            if (show) Console.WriteLine("FAIL " + name + ": " + ex.Message);
        }
    }

    private static object Exercise(OwnedQuickCleanFixture fixture, string temp)
    {
        var task = fixture.CreateTask();
        var cancel = Path.Combine(task, "verify.cancel");
        var outside = fixture.FixtureFile("outside.tmp", "outside-rule fixture", outside: true);
        var younger = fixture.FixtureFile("young.tmp", "younger than threshold", old: false);
        var control = fixture.FixtureFile("not-selected.txt", "non-candidate fixture");
        var planned = new Dictionary<string, string>(Paths);
        string Add(string name, string content)
        {
            var path = fixture.FixtureFile(name, content);
            planned.Add(path, content);
            return path;
        }
        var mainFile = Add(fixture.Case == "Recycled" ? $"sjc-recycle-{Path.GetFileName(fixture.Root)}.tmp" : "target.tmp", "old data");
        string? second = fixture.Case is "Permanent" or "Replacement" ? Add("control.log", "unchanged secondary") : null;
        if (fixture.Case is "Interrupted" or "CleanCancelled")
            for (var i = 0; i < 2048; i++) Add($"batch-{i:D4}.tmp", "candidate-" + i);
        if (fixture.Case == "ScanCancelled") WriteNew(cancel, "cancel");

        var scan = RunJob(fixture, task, temp, Scan, "scan", cancel);
        AssertStatus(scan.Result, fixture.Case == "ScanCancelled" ? "Cancelled" : "Success");
        Equal(fixture.Case == "ScanCancelled" ? 0 : planned.Count, Int(scan.Result, "CandidateCount"), "Scan candidate count");
        foreach (var item in planned) AssertFile(item.Key, item.Value);
        var claim = Path.Combine(task, "clean.claimed");
        Require(!Path.Exists(claim), "Scan must not claim cleaning rights.");
        if (fixture.Case == "ScanCancelled")
        {
            var denied = RunJob(fixture, task, temp, Clean, "cancelled-scan-denied", "");
            AssertStatus(denied.Result, "Failed");
            Equal(0, Int(denied.Result, "Deleted"), "Cancelled scan did not authorize deletion");
            AssertFile(mainFile, "old data");
            AssertSentinels(outside, younger, control);
            return new { Task = task, Scan = scan, Clean = denied };
        }

        var plan = CheckPlan(task, scan.Result, fixture.Files, planned.Keys);
        Save(Path.Combine(fixture.Root, "planned-fixtures.json"), new { Files = planned.Keys, RecycleMode = fixture.Case == "Recycled" });
        if (fixture.Case == "Interrupted")
        {
            var cut = Interrupt(fixture, task, temp, cancel, claim);
            var survivors = planned.Keys.Where(File.Exists).Order(Paths).ToArray();
            Require(survivors.Length > 0, "No approved fixture survived; interruption missed execution.");
            foreach (var path in survivors) AssertFile(path, planned[path]);
            var before = History(fixture, temp, "interrupted-history");
            Equal(2, before.GetArrayLength(), "Interrupted task must have exactly its scan and interrupted clean rows");
            _ = BindHistoryLog(before, task, Scan, "Success", scan);
            var interrupted = RequireRow(before, task, "Clean", "Unknown");
            var explanation = Text(interrupted, "Summary");
            Require(Text(interrupted, "Status") == "结果未知" && explanation.Contains("可能已部分处理") &&
                interrupted.GetProperty("Result").ValueKind == JsonValueKind.Null,
                "History must mark an unknown outcome and warn about potentially partial execution without providing a definitive result.");
            Require(before.GetRawText() == History(fixture, temp, "reopened-interrupted-history").GetRawText(),
                "A fresh process did not reopen the recorded interruption consistently.");
            var replay = RunJob(fixture, task, temp, Clean, "interrupted-replay", "");
            AssertFailedReplay(replay, claim);
            Require(survivors.SequenceEqual(planned.Keys.Where(File.Exists).Order(Paths), Paths), "Replay after interruption removed surviving candidates.");
            foreach (var path in survivors) AssertFile(path, planned[path]);
            var after = History(fixture, temp, "history-after-replay");
            AssertOnlyReplayAdded(before, after, task, replay);
            AssertSentinels(outside, younger, control);
            return new { Task = task, Scan = scan, Interrupted = cut, Survivors = survivors, Replay = replay, BeforeReplay = before, AfterReplay = after };
        }
        if (fixture.Case == "CleanCancelled")
        {
            var cancelled = CancelDuringClean(fixture, task, temp, cancel, claim);
            AssertStatus(cancelled.Result, "Cancelled");
            var survivors = planned.Keys.Where(File.Exists).Order(Paths).ToArray();
            Require(survivors.Length > 0, "All approved files were processed before cancellation took effect.");
            Equal(planned.Count - survivors.Length, Int(cancelled.Result, "Deleted"), "Cancelled clean count vs physical file state");
            var processedBytes = planned.Where(item => !File.Exists(item.Key)).Sum(item => Encoding.UTF8.GetByteCount(item.Value));
            Equal(processedBytes, Int(cancelled.Result, "ProcessedBytes"), "Cancelled clean logical bytes vs physical file state");
            _ = RequireRow(History(fixture, temp, "active-cancelled-history"), task, "Clean", "Cancelled");
            var replay = RunJob(fixture, task, temp, Clean, "active-cancelled-replay", "");
            AssertFailedReplay(replay, claim);
            Require(survivors.SequenceEqual(planned.Keys.Where(File.Exists).Order(Paths), Paths), "Replay after cancellation removed survivors.");
            foreach (var path in survivors) AssertFile(path, planned[path]);
            AssertSentinels(outside, younger, control);
            return new { Task = task, Scan = scan, Cancelled = cancelled, Survived = survivors.Length, Replay = replay };
        }

        object? replacement = null;
        string? original = null;
        if (fixture.Case == "Replacement")
        {
            var old = new FileInfo(mainFile);
            var length = old.Length;
            var mtime = old.LastWriteTimeUtc;
            original = Path.Combine(fixture.Files, "original-retained.bin");
            CheckDirect(original, fixture.Files);
            CheckFileOwner(mainFile);
            Require(!Path.Exists(original), "Original retention destination unexpectedly exists.");
            File.Move(mainFile, original);
            WriteNew(mainFile, "new data");
            File.SetLastWriteTimeUtc(mainFile, mtime);
            var changed = new FileInfo(mainFile);
            Require(changed.FullName == old.FullName && changed.Length == length && changed.LastWriteTimeUtc.Ticks == mtime.Ticks,
                "Replacement fixture must have identical full path, size and mtime.");
            replacement = new { Path = mainFile, OldRetainedAt = original, Length = length, ExactUtcTicks = mtime.Ticks };
            AssertFile(original, "old data");
        }

        if (fixture.Case == "CleanPreCancelled") WriteNew(cancel, "cancel");
        var recycle = fixture.Case == "Recycled";
        if (recycle) Equal(0, ShellRecycleMatches(mainFile), "Unique fixture is already present in Shell Recycle Bin");
        var exclusions = fixture.Case == "Permanent" ? new[] { plan[second!] } : [];
        var result = RunJob(fixture, task, temp, Clean, "clean", cancel, exclusions, recycle);
        JobResult? again = null;
        int? shellMatches = null;
        switch (fixture.Case)
        {
            case "Permanent":
                AssertStatus(result.Result, "Success");
                Equal(1, Int(result.Result, "Deleted"), "Permanently deleted count");
                Equal(1, Int(result.Result, "Skipped"), "Explicit exclusion count");
                Equal(Encoding.UTF8.GetByteCount("old data"), Int(result.Result, "ProcessedBytes"), "Logical bytes");
                Missing(mainFile);
                AssertFile(second!, "unchanged secondary");
                _ = RequireRow(History(fixture, temp, "completed-history"), task, "Clean", "Success");
                again = RunJob(fixture, task, temp, Clean, "completed-replay", "");
                AssertFailedReplay(again, claim);
                AssertFile(second!, "unchanged secondary");
                break;
            case "Replacement":
                AssertStatus(result.Result, "Partial");
                Equal(1, Int(result.Result, "Deleted"), "Only unchanged control may be deleted");
                Equal(1, Int(result.Result, "Skipped"), "Same-path replacement must be skipped");
                Equal(1, Int(result.Result, "ErrorCount"), "One replacement refusal should be recorded");
                Equal(Encoding.UTF8.GetByteCount("unchanged secondary"), Int(result.Result, "ProcessedBytes"), "Replacement contributed processed bytes");
                Missing(second!);
                AssertFile(mainFile, "new data");
                AssertFile(original!, "old data");
                break;
            case "CleanPreCancelled":
                AssertStatus(result.Result, "Cancelled");
                Equal(0, Int(result.Result, "Deleted"), "Pre-cancelled clean deleted a file");
                AssertFile(mainFile, "old data");
                Require(!Path.Exists(claim), "Pre-cancellation consumed the plan before execution.");
                _ = RequireRow(History(fixture, temp, "cancelled-history"), task, "Clean", "Cancelled");
                break;
            case "Recycled":
                AssertStatus(result.Result, "Success");
                Equal(1, Int(result.Result, "Deleted"), "Successfully processed recycled count");
                Missing(mainFile);
                var timer = Stopwatch.StartNew();
                do
                {
                    shellMatches = ShellRecycleMatches(mainFile);
                    if (shellMatches != 0) break;
                    Thread.Sleep(100);
                } while (timer.Elapsed < TimeSpan.FromSeconds(5));
                Equal(1, shellMatches.Value, "Exact original name + parent is missing from Windows Shell Recycle Bin; permanent fallback is not success");
                break;
            default: throw new InvalidOperationException("Unexpected case " + fixture.Case);
        }
        AssertSentinels(outside, younger, control);
        return new { Task = task, Scan = scan, Clean = result, Replay = again, Replacement = replacement, RecycleItem = recycle ? mainFile : null, ShellMatches = shellMatches };
    }

    private static void AssertSentinels(string outside, string younger, string control)
    {
        AssertFile(outside, "outside-rule fixture");
        AssertFile(younger, "younger than threshold");
        AssertFile(control, "non-candidate fixture");
    }

    private static void AssertFile(string file, string content)
    {
        CheckFileOwner(file);
        Require(File.ReadAllText(file) == content, "Fixture contents changed: " + file);
    }

    private static void Missing(string path) => Require(!Path.Exists(path), "Expected processed file to be gone: " + path);

    private static Dictionary<string, string> CheckPlan(string task, JsonElement scan, string files, IEnumerable<string> expected)
    {
        var plan = Text(scan, "PlanPath");
        CheckDirect(plan, task);
        CheckPlain(plan);
        Require(Path.GetFileName(plan) == "candidates.jsonl", "Unexpected plan filename.");
        var paths = new Dictionary<string, string>(Paths);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var line in File.ReadLines(plan))
        {
            var row = Parse(line);
            var file = Text(row, "Path");
            var id = Text(row, "Id");
            CheckDirect(file, files);
            CheckFileOwner(file);
            Require(Guid.TryParseExact(id, "N", out _) && ids.Add(id) && paths.TryAdd(file, id), "Invalid or duplicated sealed candidate.");
        }
        Require(paths.Keys.ToHashSet(Paths).SetEquals(expected), "Sealed candidate paths are not the exact owned fixture set.");
        return paths;
    }

    private static void AssertFailedReplay(JobResult replay, string claim)
    {
        CheckPlain(claim);
        AssertStatus(replay.Result, "Failed");
        if (replay.Result.TryGetProperty("Reviewed", out var reviewed)) Equal(0, reviewed.GetInt64(), "Old plan replay reviewed a fixture");
        Equal(0, Int(replay.Result, "Deleted"), "Old plan replay deleted a fixture");
        Equal(0, Int(replay.Result, "ProcessedBytes"), "Old plan replay reported processed bytes");
    }

    private static CutResult Interrupt(OwnedQuickCleanFixture fixture, string task, string temp, string cancel, string claim)
    {
        var (payload, output) = Channels(task, Clean, "interrupted", cancel, [], false, fixture.Core);
        using var child = StartDriver(fixture, temp, "job", Clean, payload, output);
        try
        {
            var observed = ObserveClaim(child, output, claim);
            child.Process.Kill(); // Retained handle; no PID lookup and no process-tree kill.
            var finish = child.Finish(10_000);
            Save(Path.Combine(fixture.Root, "interrupted-process.json"), new { child.Process.Id, ObservedUtc = observed, Claim = claim, Process = finish });
            Require(finish.ExitCode != 0 && !File.Exists(output), "Worker has a terminal result; interruption was not proven.");
            CheckPlain(claim);
            return new(child.Process.Id, observed, finish.ExitCode);
        }
        catch
        {
            child.Stop();
            Save(Path.Combine(fixture.Root, "failed-interrupt-process.json"), child.Finish(10_000));
            throw;
        }
    }

    private static JobResult CancelDuringClean(OwnedQuickCleanFixture fixture, string task, string temp, string cancel, string claim)
    {
        var (payload, output) = Channels(task, Clean, "active-cancel", cancel, [], false, fixture.Core);
        using var child = StartDriver(fixture, temp, "job", Clean, payload, output);
        var observed = ObserveClaim(child, output, claim);
        WriteNew(cancel, "cancel");
        var done = child.Finish(120_000);
        Save(Path.Combine(fixture.Root, "active-cancel.process.json"), new { child.Process.Id, Claim = claim, ObservedUtc = observed, done });
        return ReadJobResult(output, done.ExitCode);
    }

    private static DateTime ObserveClaim(Running child, string output, string claim)
    {
        var timer = Stopwatch.StartNew();
        Require(!File.Exists(output), "Unexpected terminal result before observing claim.");
        while (!File.Exists(claim))
        {
            if (child.Process.WaitForExit(1)) throw new InvalidOperationException("Cleaner exited before claiming, code " + child.Process.ExitCode);
            Require(timer.Elapsed < TimeSpan.FromSeconds(45), "Cleaner did not claim the plan before timeout.");
        }
        var observed = DateTime.UtcNow;
        Require(!child.Process.HasExited, "Observed claim only after process exit.");
        return observed;
    }

    private static (string Payload, string Output) Channels(string task, string action, string attempt, string cancel, string[] excluded, bool recycle, bool core)
    {
        CheckPrivate(task);
        var payload = Path.Combine(task, attempt + ".payload.json");
        var output = Path.Combine(task, attempt + ".output.json");
        Require(!core || output.Length <= 249, "QuickCleanCore operation output path exceeds 249 characters.");
        var request = new Dictionary<string, object>
        {
            ["TaskDirectory"] = task, ["CancelPath"] = cancel, ["ProgressPath"] = "", ["CleaningProfile"] = "Medium", ["CustomEnabled"] = true
        };
        if (action == Scan) request.Add("RuleIds", new[] { "SandboxOld", "SandboxLog" });
        else { request.Add("ExcludedIds", excluded); request.Add("RecycleMode", recycle); }
        Save(payload, request);
        return (payload, output);
    }

    private static JobResult RunJob(OwnedQuickCleanFixture fixture, string task, string temp, string action, string attempt,
        string cancel, string[]? excluded = null, bool recycle = false)
    {
        var (payload, output) = Channels(task, action, attempt, cancel, excluded ?? [], recycle, fixture.Core);
        using var child = StartDriver(fixture, temp, "job", action, payload, output);
        var done = child.Finish(120_000);
        Save(Path.Combine(fixture.Root, attempt + ".process.json"), done);
        return ReadJobResult(output, done.ExitCode);
    }

    private static JobResult ReadJobResult(string output, int exitCode)
    {
        CheckPlain(output);
        var json = Parse(File.ReadAllText(output));
        var status = Text(json, "Status");
        Require(!string.IsNullOrWhiteSpace(status) && (status == "Success") == (exitCode == 0), "Native exit code disagrees with job status.");
        Require(Text(json, "LogPath") == output, "Operation result refers to the wrong output channel.");
        return new(exitCode, json);
    }

    private static JsonElement History(OwnedQuickCleanFixture fixture, string temp, string attempt)
    {
        using var child = StartDriver(fixture, temp, "history");
        var done = child.Finish(30_000);
        Save(Path.Combine(fixture.Root, attempt + ".process.json"), done);
        Equal(0, done.ExitCode, "History process exit code");
        return HistoryRows(Parse(done.Stdout));
    }

    private static JsonElement HistoryRows(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object) value = value.GetProperty("Items");
        Require(value.ValueKind == JsonValueKind.Array, "History must return a JSON list.");
        return value;
    }

    private static JsonElement BindHistoryLog(JsonElement rows, string task, string action, string status, JobResult job)
    {
        var row = RequireRow(rows, task, action, status);
        AssertStatus(job.Result, status);
        if (status == "Failed")
        {
            // The Host's exception result has no TaskId. Bind it through the owned
            // output path and verify that the history recorded its actual reason.
            var reason = Text(job.Result, "Error");
            Require(!string.IsNullOrWhiteSpace(reason) && Text(row, "Summary") == "未完成：" + reason,
                "Failed history did not record the actual rejection reason.");
        }
        else Require(Text(job.Result, "TaskId") == Path.GetFileName(task), "Operation log task ID differs from recorded task.");
        var log = Text(row, "LogPath");
        Require(log == Text(job.Result, "LogPath"), "History linked the wrong operation output.");
        CheckDirect(log, task);
        CheckFileOwner(log);
        Require(Parse(File.ReadAllText(log)).GetRawText() == job.Result.GetRawText(), "Recorded log no longer matches the actual operation result.");
        return row;
    }

    private static void AssertOnlyReplayAdded(JsonElement before, JsonElement after, string task, JobResult replay)
    {
        Equal(before.GetArrayLength() + 1, after.GetArrayLength(), "Replay must add exactly one refused attempt");
        var refused = BindHistoryLog(after, task, Clean, "Failed", replay).GetRawText();
        Require(after.EnumerateArray().Select(row => row.GetRawText()).Where(row => row != refused)
            .SequenceEqual(before.EnumerateArray().Select(row => row.GetRawText())), "Replay rewrote or dropped previously recorded history.");
    }

    private static JsonElement RequireRow(JsonElement rows, string task, string action, string status)
    {
        var actionLabel = action switch { Clean => "清理", Scan => "扫描", _ => throw new ArgumentOutOfRangeException(nameof(action)) };
        var statusLabel = status switch
        {
            "Success" => "完成", "Cancelled" => "已取消", "Unknown" => "结果未知", "Failed" => "失败",
            _ => throw new ArgumentOutOfRangeException(nameof(status))
        };
        var matches = rows.EnumerateArray().Where(row => Paths.Equals(task, Text(row, "TaskDirectory")) &&
            Text(row, "Action") == actionLabel && Text(row, "Status") == statusLabel).ToArray();
        Equal(1, matches.Length, $"History requires one {action}/{status} row for {task}; actual {rows.GetRawText()}");
        Require(!string.IsNullOrWhiteSpace(Text(matches[0], "Summary")), "History row summary missing.");
        if (status != "Unknown") Require(File.Exists(Text(matches[0], "LogPath")), "Terminal row must link a real operation log.");
        else Require(string.IsNullOrEmpty(Text(matches[0], "LogPath")), "Interrupted row must not advertise a definitive final log.");
        return matches[0];
    }

    private static void AssertStatus(JsonElement result, string expected) => Require(Text(result, "Status") == expected,
        $"Expected {expected} job result, actual {result.GetRawText()}");
    private static string Text(JsonElement element, string key) => element.GetProperty(key).GetString() ?? "";
    private static long Int(JsonElement element, string key) => element.GetProperty(key).GetInt64();
    private static void Equal(long expected, long actual, string text) => Require(expected == actual, $"{text}: expected {expected}, actual {actual}.");
    private static JsonElement Parse(string json) { using var value = JsonDocument.Parse(json); return value.RootElement.Clone(); }
    private static void Save(string path, object value) => WriteNew(path, JsonSerializer.Serialize(value, Indented));
    private static string Sha(string path) { using var file = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(file)); }
    private static Artifact Art(string path) { CheckPlain(path); return new(path, Sha(path)); }

    private sealed record CutResult(int Pid, DateTime ClaimedUtc, int ExitCode);
    private sealed record JobResult(int ExitCode, JsonElement Result);
    private sealed record CheckResult(string Case, string Outcome, string? Evidence, string? Detail);
    private sealed record Artifact(string Path, string SHA256);
}
