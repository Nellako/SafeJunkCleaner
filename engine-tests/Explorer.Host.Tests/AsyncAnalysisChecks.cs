using System.Diagnostics;
using System.Text.Json;
using SafeJunkCleaner.Explorer;
using SafeJunkCleaner.Explorer.Application;
using SafeJunkCleaner.Explorer.Execution;
using SafeJunkCleaner.Explorer.Host;

internal static class AsyncAnalysisChecks
{
    internal static async Task<int> Run(InventoryEngine engine)
    {
        int checks = 0;
        void Assert(bool condition, string name) { if (!condition) throw new Exception(name); checks++; }
        static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value);
        async Task<JsonElement> Finish(ExplorerCoordinator c, string task, string id)
        {
            for (int i = 0; i < 2000; i++)
            {
                var p = Json(c.GetAnalysisProgress(task, id));
                if (p.GetProperty("Status").GetString() != "Running") { await Task.Delay(10); return p; }
                await Task.Delay(5);
            }
            throw new Exception("Synthetic analysis timeout");
        }
        foreach (string mode in new[] { "cancel-load", "revision-load", "duration-load", "cancel-display", "ready-display", "failed-load", "failed-private-load" })
        {
            var rows = new BlockingRows(mode.EndsWith("load", StringComparison.Ordinal));
            var source = new BlockingSource(mode.EndsWith("display", StringComparison.Ordinal));
            using var c = new ExplorerCoordinator(rows, "test-owner", new NeverStore(), new NeverFacts(), new NeverRecycler(), snapshots => { source.Snapshots = snapshots; return source; },
                analysisDuration: mode == "duration-load" ? TimeSpan.FromMilliseconds(100) : TimeSpan.FromSeconds(30));
            Task<object>? started = null;
            try
            {
                var clock = Stopwatch.StartNew(); started = Task.Run(() => c.Analyze(rows.Header.TaskId, null, rows.Header.Revision, "Scope"));
                Assert(await Task.WhenAny(started, Task.Delay(2000)) == started, "Analyze returns before blocked inventory page: " + mode);
                string id = Json(await started).GetProperty("AnalysisId").GetString()!;
                Assert(!Json(await started).GetProperty("HasResult").GetBoolean(), "Analyze reports no result before asynchronous stages complete: " + mode);
                var entered = mode.EndsWith("load", StringComparison.Ordinal) ? rows.Entered : source.Entered;
                Assert(entered.Wait(TimeSpan.FromSeconds(2)), "worker reaches blocked stage: " + mode);
                var inspect = Task.Run(() => c.GetAnalysisProgress(rows.Header.TaskId, id));
                Assert(await Task.WhenAny(inspect, Task.Delay(1000)) == inspect, "GetProgress not held behind blocked worker: " + mode);
                Assert(Json(await inspect).GetProperty("Status").GetString() == "Running", "partial build is not published as ready: " + mode);
                bool unavailable = false; try { c.Read(rows.Header.TaskId, rows.Header.Revision); } catch (InvalidOperationException) { unavailable = true; }
                Assert(unavailable, "external trusted source cannot read pending result: " + mode);
                if (mode.StartsWith("cancel", StringComparison.Ordinal))
                {
                    string Request(string operation, object payload) => JsonSerializer.Serialize(new { ProtocolVersion = 1, RequestId = Guid.NewGuid().ToString("D"), TaskId = rows.Header.TaskId, Operation = operation, Payload = payload }) + "\n";
                    string requests = Request("GetAnalysisProgress", new { AnalysisId = id }) + Request("CancelAnalysis", new { AnalysisId = id });
                    using var input = new MemoryStream(System.Text.Encoding.UTF8.GetBytes(requests)); using var output = new StringWriter();
                    var cancel = Task.Run(() => HostProtocol.RunAsync(engine, c, engine.ListTasks, input, output));
                    Assert(await Task.WhenAny(cancel, Task.Delay(1000)) == cancel, "JSONL progress and cancel respond while worker stage is blocked: " + mode); await cancel;
                    var replies = output.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => JsonDocument.Parse(line).RootElement.Clone()).ToArray();
                    Assert(replies.Length == 2 && replies.All(r => r.GetProperty("Ok").GetBoolean()) && replies[1].GetProperty("Result").GetProperty("CancellationRequested").GetBoolean(), "wire returns progress then accepted cancellation before blocked stage is released: " + mode);
                }
                if (mode == "revision-load") rows.Header = rows.Header with { Revision = rows.Header.Revision + 1 };
                if (mode == "duration-load") await Task.Delay(180);
                if (mode == "failed-load") rows.InvalidCoverage = true;
                if (mode == "failed-private-load") rows.PrivateFailure = true;
                rows.Release.Set(); source.Release.Set();
                if (mode is "failed-load" or "failed-private-load")
                {
                    var failed = await Finish(c, rows.Header.TaskId, id);
                    Assert(failed.GetProperty("Status").GetString() == "Failed" && !failed.GetProperty("HasResult").GetBoolean(), "failed load cannot publish suggestions");
                    Assert(failed.GetProperty("Reason").GetString() == (mode == "failed-load" ? "InvalidInventoryRow" : "AnalysisFailed:IOException"), "fixed internal code retained without exposing private exception text");
                    Assert(failed.GetProperty("Timing").GetProperty("TotalMilliseconds").GetDouble() > 0
                        && failed.GetProperty("Timing").GetProperty("SnapshotMilliseconds").GetDouble() > 0, "failed snapshot still reports actual elapsed time");
                    c.InvalidateAnalysis(rows.Header.TaskId, id);
                    continue;
                }
                if (mode == "revision-load")
                {
                    for (int i = 0; i < 1000; i++) { try { c.InvalidateAnalysis(rows.Header.TaskId, id); break; } catch (InvalidOperationException ex) when (ex.Message == "TaskHasActiveWork") { await Task.Delay(5); } }
                    bool rejected = false; try { c.Read(rows.Header.TaskId, rows.Header.Revision - 1); } catch (InvalidOperationException) { rejected = true; }
                    Assert(rejected && source.Calls == 0, "revision changed during load never publishes/prepares source");
                    continue;
                }
                var result = await Finish(c, rows.Header.TaskId, id);
                Assert(result.GetProperty("HasResult").GetBoolean() == (mode == "ready-display"), "HasResult differentiates published result from cancelled/budget-only diagnostics: " + mode);
                if (mode.StartsWith("cancel", StringComparison.Ordinal)) Assert(result.GetProperty("Status").GetString() == "Cancelled", "blocked-stage cancellation does not publish suggestions: " + mode);
                else if (mode == "duration-load") Assert(result.GetProperty("Status").GetString() == "BudgetExhausted" && result.GetProperty("Reason").GetString() == "DurationBudget", "snapshot load counts toward total duration budget");
                else
                {
                    Assert(result.GetProperty("Status").GetString() is not ("Failed" or "Cancelled"), "canonical display preparation completes");
                    int calls = source.Calls;
                    c.QuerySuggestions(rows.Header.TaskId, id, null, 64); c.QuerySuggestions(rows.Header.TaskId, id, null, 64);
                    Assert(source.Calls == calls && calls == 2, "suggestion page never invokes canonical source on reader thread");
                }
                c.InvalidateAnalysis(rows.Header.TaskId, id);
            }
            finally { rows.Release.Set(); source.Release.Set(); if (started != null) try { await started; } catch { } }
        }
        return checks;
    }
    private sealed class BlockingRows(bool blocked) : ITrustedInventoryRows
    {
        internal readonly ManualResetEventSlim Entered = new(), Release = new();
        internal bool InvalidCoverage;
        internal bool PrivateFailure;
        internal TrustedTaskHeader Header = new(Guid.NewGuid().ToString("D"), 7, Guid.NewGuid().ToString("D"), "scope", "policy", "test-owner", "1", @"E:\synthetic-async-analysis", "root-id", "Ready");
        public TrustedTaskHeader ReadHeader(string task) => Header;
        public InventoryPage ReadPage(string task, long revision, string? after, int size)
        {
            Entered.Set(); if (blocked && !Release.Wait(TimeSpan.FromSeconds(10))) throw new Exception("Test release timeout");
            if (PrivateFailure) throw new IOException(@"C:\private-example\not-for-the-user-interface.txt");
            return new([new("1", null, Header.RootPath, "Directory", "root-id", null, DateTime.UnixEpoch.ToString("O"), 16, 1, InvalidCoverage ? "InvalidCoverage" : "Complete", null)], null);
        }
    }
    private sealed class BlockingSource(bool blocked) : IApprovalSource
    {
        internal readonly ManualResetEventSlim Entered = new(), Release = new();
        internal ITrustedAnalysisSnapshots? Snapshots; internal int Calls;
        public ApprovalSource Read(string task)
        {
            Calls++; var inventory = ((ITrustedInventorySnapshots)Snapshots!).ReadInventory(task, 7); var analysis = Snapshots!.Read(task, 7);
            Entered.Set(); if (blocked && !Release.Wait(TimeSpan.FromSeconds(10))) throw new Exception("Test release timeout");
            return new(task, inventory.Header.ScopeId, "scope", analysis.Reason, "policy", "test-owner", [inventory.Header.RootPath], []);
        }
    }
    private sealed class NeverRecycler : IRecycleOnly
    {
        public bool IsAvailable => false; public string UnavailableReason => "SyntheticNoExecution";
        public RecycleResult Recycle(FileSnapshot file, CancellationToken token) => throw new Exception("UnexpectedRecycle");
    }
    private sealed class NeverFacts : IExecutionFacts
    {
        public string OwnerSid => "test-owner"; public void ValidateLocalPath(string path) => throw new NotSupportedException(); public string? HardProtection(string path) => throw new NotSupportedException();
        public AncestorSnapshot[] Ancestors(string path) => throw new NotSupportedException(); public CurrentFile Read(string path, bool verifyContent) => throw new NotSupportedException();
        public IDisposable GuardAncestors(string path, AncestorSnapshot[] expected) => throw new NotSupportedException(); public IDisposable GuardRetainedCopy(FileSnapshot expected) => throw new NotSupportedException();
    }
    private sealed class NeverStore : IApprovalStore
    {
        public bool IsClaimed(string id) => throw new NotSupportedException();
        public void PutDraft(ApprovalDraft draft) => throw new NotSupportedException(); public ApprovalDraft ReadDraft(string id) => throw new NotSupportedException();
        public void PutSeal(ApprovalSeal seal) => throw new NotSupportedException(); public ApprovalSeal ReadSeal(string id) => throw new NotSupportedException();
        public IDisposable Claim(string id) => throw new NotSupportedException(); public void Append(string id, ExecutionEntry entry) => throw new NotSupportedException(); public ExecutionEntry[] ReadLedger(string id) => throw new NotSupportedException();
    }
}
