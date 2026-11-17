using System.Security.Cryptography;
using System.Text.Json;
using SafeJunkCleaner.Explorer;
using SafeJunkCleaner.Explorer.Analysis;
using SafeJunkCleaner.Explorer.Application;
using SafeJunkCleaner.Explorer.Execution;
using SafeJunkCleaner.Explorer.Host;

internal static class LifecycleChecks
{
    private static JsonElement J(object value) => JsonSerializer.SerializeToElement(value);
    private sealed class SimulatedRecycler : IRecycleOnly
    {
        internal int Calls;
        public bool IsAvailable => true;
        public string UnavailableReason => "SimulationOnly";
        public RecycleResult Recycle(FileSnapshot file, CancellationToken token)
        { Interlocked.Increment(ref Calls); return new(false, "SimulatedNoFilesystemEffects"); }
    }
    internal static async Task<int> Run(string parent)
    {
        int count = 0;
        void Check(bool ok, string name) { if (!ok) throw new Exception("Lifecycle: " + name); count++; }
        void Rejected(Action action, string name)
        {
            Exception? failure = null; try { action(); } catch (Exception ex) when (ex is not OutOfMemoryException) { failure = ex; }
            Check(failure != null, name); Console.WriteLine($"REJECT {name}: {failure!.GetType().Name}/{failure.Message}");
        }
        string local = TestEvidence.CreateFixture(parent, "host-lifecycle");
        string project = Path.Combine(local, "projects");
        var expectedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (int group = 0; group < 4; group++)
        {
            string root = Path.Combine(project, "group" + group), bin = Path.Combine(root, "bin"); Directory.CreateDirectory(bin);
            File.WriteAllText(Path.Combine(root, "app.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk\" />");
            foreach (string name in new[] { "app.dll", "app.deps.json" }.Concat(Enumerable.Range(0, 16).Select(i => $"part{i}.cache")))
            { string path = Path.Combine(bin, name); File.WriteAllText(path, "synthetic fixture " + group + "/" + name); expectedPaths.Add(path); }
        }
        string state = Path.Combine(local, "state"), approvalRoot = Path.Combine(local, "approvals");
        using var engine = new InventoryEngine(state); var rows = new HostInventoryRows(engine);
        string task = engine.CreateInventory(project);
        for (int i = 0; i < 4000 && engine.ReadTaskHeader(task).State == "Inventory"; i++) await Task.Delay(5);
        var header = rows.ReadHeader(task); Check(header.State == "Ready", "fixture inventory ready");
        var fake = new SimulatedRecycler(); string? firstApproval = null, lastApproval = null; Exception? historicalFailure = null;
        using (var store = new WindowsApprovalStore(approvalRoot))
        {
            var baseFacts = new WindowsExecutionFacts(state); ExplorerCoordinator? current = null;
            var provider = new HostBuildArtifactProvider(rows, () => current!); var facts = new WindowsExecutionFacts(state, provider);
            using var coordinator = current = new(rows, facts.OwnerSid, store, facts, fake, snapshots =>
            { var source = new ApprovalSourceAdapter(rows, snapshots, baseFacts, provider.BindCandidateHash); provider.Bind(source); return source; }, provider.Register);
            async Task<string> Analyze()
            {
                string id = J(coordinator.Analyze(task, null, header.Revision, "Scope")).GetProperty("AnalysisId").GetString()!;
                for (int i = 0; i < 4000; i++)
                {
                    var progress = J(coordinator.GetAnalysisProgress(task, id));
                    if (progress.GetProperty("Status").GetString() != "Running")
                    { Check(progress.GetProperty("HasResult").GetBoolean(), "analysis publishes result"); await Task.Delay(20); return id; }
                    await Task.Delay(5);
                }
                throw new Exception("Lifecycle analysis timeout");
            }
            JsonElement Prepare(string id)
            {
                var review = J(coordinator.QuerySuggestions(task, id, null, 64)).GetProperty("Items").EnumerateArray().Where(s => s.GetProperty("MayPrepareForReview").GetBoolean()).ToArray();
                Check(review.Length == 4 && review.All(s => s.GetProperty("CandidateCount").GetInt32() == 18), "four whole exact groups, 18 each, no capped remainder");
                var draft = J(coordinator.PrepareApproval(task, id, review.Select(s => s.GetProperty("SuggestionId").GetString()!).ToArray(), header.Revision));
                Check(draft.GetProperty("ItemCount").GetInt32() == 72, "72 exact approved candidates"); return draft;
            }
            for (int round = 0; round < 20; round++)
            {
                string id = await Analyze(); var draft = Prepare(id); coordinator.InvalidateAnalysis(task, id);
                var session = J(coordinator.GetSessionInfo());
                Check(session.GetProperty("AnalysisSessions").GetInt32() == 0 && session.GetProperty("DraftBindings").GetInt32() == 0, "round " + round + " invalidation releases analyses and draft bindings");
                Rejected(() => coordinator.ConfirmApproval(task, draft.GetProperty("DraftId").GetString()!, draft.GetProperty("DisplayHash").GetString()!), "invalidated draft cannot confirm");
            }
            Console.WriteLine($"LIFECYCLE STAGE1 PASS: 20 Analyze/Prepare/Invalidate rounds; {count} assertions; {local}");
            string analysis = await Analyze();
            for (int round = 0; round < 10; round++)
            {
                var draft = Prepare(analysis);
                string draftId = draft.GetProperty("DraftId").GetString()!;
                var sealPaths = new Dictionary<string, string>(StringComparer.Ordinal);
                for (int offset = 0; ;)
                {
                    var page = J(coordinator.QueryApprovalItems(task, draftId, offset, 31));
                    foreach (var item in page.GetProperty("Items").EnumerateArray())
                        sealPaths.Add(item.GetProperty("File").GetProperty("ObjectId").GetString()!, item.GetProperty("File").GetProperty("Path").GetString()!);
                    if (page.GetProperty("NextAfter").ValueKind == JsonValueKind.Null) break;
                    offset = page.GetProperty("NextAfter").GetInt32();
                }
                Check(sealPaths.Count == 72 && expectedPaths.SetEquals(sealPaths.Values), "seal contains complete artificial candidate set");
                string approval = J(coordinator.ConfirmApproval(task, draftId, draft.GetProperty("DisplayHash").GetString()!)).GetProperty("ApprovalId").GetString()!;
                firstApproval ??= approval; lastApproval = approval; coordinator.ExecuteApproved(task, approval);
                JsonElement result = default;
                for (int i = 0; i < 4000; i++)
                { result = J(coordinator.GetExecutionResult(task, approval, 0, 31)); if (result.GetProperty("Status").GetString() != "Running") break; await Task.Delay(5); }
                Check(result.GetProperty("Status").GetString() == "PartialOrInterrupted", "simulated no-effects execution is never success");
                var entries = new List<JsonElement>(); int pages = 0;
                for (int offset = 0; ;)
                {
                    var page = J(coordinator.GetExecutionResult(task, approval, offset, 31)); pages++;
                    Check(page.GetProperty("ExpectedItems").GetInt32() == 72 && page.GetProperty("FinalItems").GetInt32() == 72 && page.GetProperty("SkippedItems").GetInt32() == 72 && page.GetProperty("UnknownItems").GetInt32() == 0 && page.GetProperty("RecycledItems").GetInt32() == 0 && page.GetProperty("RecycledLogicalBytes").GetInt64() == 0 && page.GetProperty("LedgerEntries").GetInt32() == 144, "full-ledger statistics stable on every page");
                    entries.AddRange(page.GetProperty("Entries").EnumerateArray().Select(e => e.Clone()));
                    if (page.GetProperty("NextAfter").ValueKind == JsonValueKind.Null) break;
                    int next = page.GetProperty("NextAfter").GetInt32(); Check(next > offset, "entry cursor progresses"); offset = next;
                }
                Check(pages == 5 && entries.Count == 144 && entries.All(e => e.GetProperty("Path").GetString() == sealPaths[e.GetProperty("ObjectId").GetString()!]), "all 144 entries paged once, paths bound to seal");
                Check(entries.GroupBy(e => e.GetProperty("ObjectId").GetString()).All(g => g.Select(e => e.GetProperty("Status").GetString()).SequenceEqual(new[] { "Attempting", "Skipped" }) && g.Last().GetProperty("Reason").GetString() == "SimulatedNoFilesystemEffects"), "write-ahead Attempting followed by final for each item");
                Check(store.IsClaimed(approval), "execution claim persisted");
                Rejected(() => coordinator.ExecuteApproved(task, approval), "completed execution replay denied");
                Check(J(coordinator.GetSessionInfo()).GetProperty("ExecutionSessions").GetInt32() <= 1, "finished execution sessions pruned before next execute");
                Console.WriteLine($"LIFECYCLE EXECUTE {round + 1}/10 PASS: 72 items, 144 entries, 5 pages");
            }
            Check(fake.Calls == 720 && expectedPaths.All(File.Exists), "720 simulated calls leave all files intact");
            // Check persisted replay after the first session has been pruned, not merely the in-memory duplicate guard.
            Rejected(() => coordinator.ExecuteApproved(task, firstApproval!), "pruned completed execution persistent replay denied");
            store.Append(firstApproval!, new(Guid.NewGuid().ToString("D"), "Recycled", "UnknownObjectFixture", 99));
            Rejected(() => coordinator.GetExecutionResult(task, firstApproval!, 0, 64), "unknown ledger object explicitly fails");
            string corrupt = Path.Combine(approvalRoot, firstApproval + ".ledger");
            File.AppendAllText(corrupt, "not-base64-ledger\n");
            Rejected(() => coordinator.GetExecutionResult(task, firstApproval!, 0, 64), "corrupt ledger explicitly fails");
            coordinator.ReleaseFinishedSessions(true);
            Check(J(coordinator.GetSessionInfo()).GetProperty("ExecutionSessions").GetInt32() == 0, "explicit release clears execution sessions");
            try
            {
                var reread = J(coordinator.GetExecutionResult(task, lastApproval!, 0, 64));
                Check(reread.GetProperty("LedgerEntries").GetInt32() == 144, "persisted result survives session release");
            }
            catch (Exception ex) { historicalFailure = ex; Console.WriteLine("FAIL persisted result survives session release: " + ex); }
        }
        using (var restarted = new WindowsApprovalStore(approvalRoot))
        {
            Check(restarted.IsClaimed(firstApproval!), "claim survives store reopen");
            Rejected(() => { using var claim = restarted.Claim(firstApproval!); }, "reopened store refuses persistent claim replay");
        }
        foreach (var test in new[] {
            ("Budget", "HashBudget", Classification.Unknown), ("Coverage", "PartialIndex", Classification.Unknown),
            ("Protected", "Personal", Classification.UserData), ("MixedMembers", "SourceOrPrivateOrPartial", Classification.Mixed),
            ("UnsupportedLayout", "ChromiumSimpleCacheRecognized", Classification.Unknown) })
        {
            var suggestion = new Suggestion("s", "t", test.Item3, SuggestionLevel.OrganizeOpportunity, [], ["e"], [], "fixture", false);
            var result = new AnalysisResult(task, 1, default, [new AnalysisEvidence("e", "t", EvidenceKind.Layout, test.Item2)], [suggestion], [], new(0, 0, 0, 0, 0, 0), "fixture");
            var reason = SuggestionReasons.For(result, suggestion, false, false);
            Check(reason.Category == test.Item1 && !string.IsNullOrEmpty(reason.Code) && !string.IsNullOrEmpty(reason.Hint), "production reason category " + test.Item1);
        }
        if (historicalFailure != null) throw new InvalidOperationException("LifecycleHistoricalResultAfterReleaseFailed", historicalFailure);
        File.WriteAllText(Path.Combine(local, "lifecycle-result.json"), JsonSerializer.Serialize(new { Passed = true, Assertions = count, AnalyzePrepareInvalidateRounds = 20, ExecuteRounds = 10, CandidatesPerExecution = 72, LedgerEntriesPerExecution = 144, SimulationOnly = true, NativeRecycleCalls = 0 }));
        Console.WriteLine($"LIFECYCLE PASS {count} assertions; evidence {local}"); return count;
    }
}
