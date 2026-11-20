using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using SafeJunkCleaner.QuickClean;
using static QuickClean.Verification.OwnedQuickCleanFixture;

namespace QuickClean.Verification;

internal static partial class VerifyHost
{
    private static Assembly HostAssembly() => typeof(Jobs).Assembly;

    // Test-only executable transport for the real GUI bridge. No arbitrary state or
    // operation is accepted; reopen only the authenticated fixture of this launcher.
    private static int GuiHistory()
    {
        var parent = Environment.GetEnvironmentVariable("SJC_QC_VERIFY_PARENT") ?? "";
        var run = Environment.GetEnvironmentVariable("SJC_QC_VERIFY_RUN") ?? "";
        var root = Environment.GetEnvironmentVariable("SJC_QC_VERIFY_ROOT") ?? "";
        var hash = Environment.GetEnvironmentVariable("SJC_QC_VERIFY_HOST_SHA256") ?? "";
        RequireHostHash(hash);
        var fixture = OpenForChild(parent, run, root, core: true);
        Require(fixture.Case == "History", "GUI transport only reopens a History fixture.");
        Console.WriteLine(JsonSerializer.Serialize(new Jobs(fixture.State, fixture.Files).Query("History", Parse(Console.In.ReadToEnd()))));
        return 0;
    }

    private static int Child(string[] args)
    {
        Require(args.Length >= 5, "Missing owned child arguments.");
        var fixture = OpenForChild(args[1], args[2], args[3], core: args[0] == "_core-child");
        // History is a typed QuickCleanCore case, not a legacy suite/fixture entry.
        Require(FixtureCases.Contains(fixture.Case) || fixture.Case == "History", "Unknown owned fixture case.");
        var jobs = new Jobs(fixture.State, fixture.Files);
        if (args is [_, _, _, _, "history"])
        {
            Console.WriteLine(JsonSerializer.Serialize(jobs.Query("History", Parse("{}"))));
            return 0;
        }
        if (args is [_, _, _, _, "job", var action, var payload, var output] && action is Scan or Clean)
        {
            var task = Path.GetDirectoryName(payload)!;
            CheckDirect(task, fixture.Tasks);
            CheckPrivate(task);
            CheckDirect(payload, task);
            CheckDirect(output, task);
            CheckFileOwner(payload);
            CheckFileOwner(Path.Combine(task, ".task-owner"));
            Require(!Path.Exists(output) && Guid.TryParseExact(Path.GetFileName(task), "D", out _), "Unsafe output or task ID.");
            var request = Parse(File.ReadAllText(payload));
            Require(SamePath(Text(request, "TaskDirectory"), task), "Payload task mismatch.");
            var cancel = Text(request, "CancelPath");
            if (cancel != "")
            {
                CheckDirect(cancel, task);
                Require(Path.GetFileName(cancel) == "verify.cancel", "Unexpected cancellation channel.");
            }
            Require(Text(request, "ProgressPath") == "", "Unexpected progress channel.");
            if (action == Clean && request.GetProperty("RecycleMode").GetBoolean())
            {
                Require(fixture.Case == "Recycled", "Recycling is not authorized for this owned case.");
                var target = Path.Combine(fixture.Files, $"sjc-recycle-{Path.GetFileName(fixture.Root)}.tmp");
                var plan = Path.Combine(task, "candidates.jsonl");
                CheckFileOwner(plan);
                var paths = File.ReadLines(plan).Select(line => Text(Parse(line), "Path")).ToArray();
                Require(paths.Length == 1 && SamePath(paths[0], target), "Recycling authorizes only the single GUID fixture.");
                CheckFileOwner(target);
            }
            return jobs.Job(action, payload, output);
        }
        throw new ArgumentException("The verification subprocess only accepts Scan, Clean and read-only History.");
    }

    private static Running StartDriver(OwnedQuickCleanFixture fixture, string temp, params string[] args)
    {
        var launched = Environment.ProcessPath ?? throw new InvalidOperationException("Process path unavailable.");
        var file = Paths.Equals(Path.GetFileName(launched), "dotnet.exe") ? new[] { Assembly.GetExecutingAssembly().Location } : [];
        var info = NewProcess(launched, fixture.Root, temp, [.. file, fixture.Core ? "_core-child" : "_child", fixture.Parent, fixture.Run, fixture.Root, .. args]);
        info.Environment[ChildToken] = fixture.Nonce;
        return new Running(info);
    }

    private static ProcessStartInfo NewProcess(string exe, string workingDir, string temp, string[] args)
    {
        var info = new ProcessStartInfo(exe) { WorkingDirectory = workingDir, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
        info.Environment.Remove(ChildToken);
        info.Environment["TEMP"] = temp;
        info.Environment["TMP"] = temp;
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return info;
    }

    private static Published ApphostFacts(string binary)
    {
        var root = Path.GetDirectoryName(binary)!;
        var managed = new List<Artifact>();
        var companions = new List<Artifact>();
        foreach (var nonExe in new[] { "sjc-quickclean.dll", "sjc-quickclean.deps.json", "sjc-quickclean.runtimeconfig.json", "quickclean-component-manifest.json" })
        {
            var path = Path.Combine(root, nonExe);
            if (!File.Exists(path)) continue;
            var facts = Art(path);
            if (nonExe.EndsWith(".dll", StringComparison.Ordinal)) managed.Add(facts); else companions.Add(facts);
        }
        return new(Art(binary), managed.ToArray(), companions.ToArray());
    }

    private static IEnumerable<(string Name, Func<object> Test)> ProductionChecks(string binary, string evidence, string temp)
    {
        ProcessOutcome Invoke(string[] args, string input = "")
        {
            var start = NewProcess(binary, evidence, temp, args);
            var absentSdk = Path.Combine(evidence, "no-sdk");
            Require(!Path.Exists(absentSdk), "Reserved absent SDK path exists.");
            foreach (var name in start.Environment.Keys.Where(x => x.StartsWith("DOTNET_ROOT", StringComparison.OrdinalIgnoreCase)).ToArray())
                start.Environment.Remove(name);
            start.Environment["DOTNET_ROOT"] = absentSdk;
            start.Environment["DOTNET_ROOT_X64"] = absentSdk;
            start.Environment["DOTNET_MULTILEVEL_LOOKUP"] = "0";
            start.Environment["PATH"] = Environment.SystemDirectory;
            start.RedirectStandardInput = true;
            start.StandardInputEncoding = new UTF8Encoding(false);
            using var process = new Running(start);
            process.Process.StandardInput.Write(input);
            process.Process.StandardInput.Close();
            return process.Finish(30_000);
        }
        yield return ("ApphostHealth", () =>
        {
            var result = Invoke(["health"]);
            Save(Path.Combine(evidence, "health.process.json"), result);
            Equal(0, result.ExitCode, "Health native exit code");
            var health = Parse(result.Stdout);
            Require(Text(health, "Version") == OwnedQuickCleanFixture.Version, "Health version differs from the requested beta.");
            Require(Text(health, "Backend") == "QuickClean" && Text(health, "Framework").StartsWith(".NET 10.", StringComparison.Ordinal),
                "Health did not identify an independent .NET 10 QuickClean backend.");
            Equal(1, Int(health, "Protocol"), "QuickClean protocol major version");
            return health;
        });
        yield return ("ApphostHistory", () =>
        {
            // Production history is read-only. Never retain or print the user's rows/paths.
            var result = Invoke(["query", "History"], "{}");
            Equal(0, result.ExitCode, "History query native exit code (production stdout deliberately not logged)");
            var rows = HistoryRows(Parse(result.Stdout));
            foreach (var row in rows.EnumerateArray())
                Require(new[] { "Action", "Status", "Summary", "TaskDirectory", "LogPath" }.All(k => row.TryGetProperty(k, out _)), "Invalid public history row shape.");
            return new { result.ExitCode, RowCount = rows.GetArrayLength(), HistoryRedacted = true };
        });
        yield return ("ApphostMaintenanceCheck", () =>
        {
            var result = Invoke(["maintenance-check"]);
            Save(Path.Combine(evidence, "maintenance-check.process.json"), result);
            Equal(0, result.ExitCode, "Maintenance check native exit code");
            var check = Parse(result.Stdout);
            Require(Text(check, "Status") == "Ready" && !check.GetProperty("Started").GetBoolean() && Text(check, "Elevation") == "DismOnly" &&
                Paths.Equals(Text(check, "FileName"), Path.Combine(Environment.SystemDirectory, "dism.exe")) &&
                Text(check, "Arguments") == "/Online /Cleanup-Image /StartComponentCleanup", "Incorrect readiness result or check launched maintenance.");
            return check;
        });
        yield return ("ApphostInvalidArguments", () =>
        {
            var forbidden = Path.Combine(evidence, "unsupported-root-not-created");
            Require(!Path.Exists(forbidden), "Negative test path already exists.");
            (string[] Args, string Input)[] attempts = [(["health", "--state", forbidden], ""), (["health", "--test-root", forbidden], ""),
                (["fixture", forbidden, "Permanent"], ""), (["query", "UnknownVerificationQuery"], "{}"),
                (["query", "History"], JsonSerializer.Serialize(new { StateRoot = forbidden, TestRoot = forbidden })),
                (["maintenance-check", "--invalid-verification-option"], ""), (["job", "UnknownVerificationOperation"], "")];
            var outcomes = new List<object>();
            foreach (var (args, input) in attempts)
            {
                var result = Invoke(args, input);
                Save(Path.Combine(evidence, $"invalid-{outcomes.Count}.process.json"), new { Args = args, Result = result });
                Require(result.ExitCode != 0, "Production unexpectedly accepted: " + string.Join(' ', args));
                Require(!Path.Exists(forbidden), "Production created the caller-supplied state/fixture directory.");
                outcomes.Add(new { Args = args, result.ExitCode });
            }
            return outcomes;
        });
    }

    private static int ShellRecycleMatches(string original)
    {
        var folder = Path.GetDirectoryName(original)!;
        var name = Path.GetFileName(original);
        var type = Type.GetTypeFromProgID("Shell.Application", throwOnError: true)!;
        object shell = Activator.CreateInstance(type)!;
        object? bin = null, items = null;
        try
        {
            bin = ((dynamic)shell).NameSpace(10); // CSIDL_BITBUCKET, never EmptyRecycleBin.
            Require(bin is not null, "Windows Shell Recycle Bin namespace unavailable.");
            items = ((dynamic)bin!).Items();
            Require(items is not null, "Windows Shell Recycle Bin could not enumerate items.");
            int count = ((dynamic)items!).Count;
            var matches = 0;
            for (int i = 0; i < count; i++)
            {
                object? item = ((dynamic)items!).Item(i);
                if (item is null) continue;
                try
                {
                    // Filter by the exact owned original directory first; never log other items.
                    string? origin = ((dynamic)item).ExtendedProperty("System.Recycle.DeletedFrom") as string;
                    if (!Paths.Equals(origin?.TrimEnd('\\'), folder)) continue;
                    string? shellName = ((dynamic)item).ExtendedProperty("System.FileName") as string;
                    string? displayName = ((dynamic)item).Name as string;
                    if (Paths.Equals(shellName, name) || Paths.Equals(displayName, name) ||
                        Paths.Equals(displayName, Path.GetFileNameWithoutExtension(name))) matches++;
                }
                finally { Marshal.ReleaseComObject(item); }
            }
            return matches;
        }
        finally
        {
            if (items is not null) Marshal.ReleaseComObject(items);
            if (bin is not null) Marshal.ReleaseComObject(bin);
            Marshal.ReleaseComObject(shell);
        }
    }

    private sealed record Published(Artifact Executable, Artifact[] ManagedAssemblies, Artifact[] Companions);
    private sealed record ProcessOutcome(int ExitCode, string Stdout, string Stderr);

    private sealed class Running : IDisposable
    {
        internal Process Process { get; }
        private readonly Task<string> stdout, stderr;
        internal Running(ProcessStartInfo info)
        {
            Process = new Process { StartInfo = info };
            try
            {
                Require(Process.Start(), "Native process did not start: " + info.FileName);
                _ = Process.Handle;
                stdout = Process.StandardOutput.ReadToEndAsync();
                stderr = Process.StandardError.ReadToEndAsync();
            }
            catch { Process.Dispose(); throw; }
        }
        internal ProcessOutcome Finish(int timeout)
        {
            if (!Process.WaitForExit(timeout))
            {
                Stop();
                throw new TimeoutException("Owned native child timed out.");
            }
            Require(Task.WaitAll([stdout, stderr], 10_000), "Owned child's output channels did not close.");
            return new(Process.ExitCode, stdout.Result, stderr.Result);
        }
        internal void Stop()
        {
            if (!Process.HasExited)
            {
                try { Process.Kill(); }
                catch (InvalidOperationException) when (Process.HasExited) { }
                Require(Process.WaitForExit(10_000), "Owned child did not exit after termination.");
            }
        }
        public void Dispose()
        {
            try { Stop(); }
            finally { Process.Dispose(); }
        }
    }
}
