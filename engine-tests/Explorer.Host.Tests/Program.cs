using System.Security.Principal;
using System.Text.Json;
using SafeJunkCleaner.Explorer;
using SafeJunkCleaner.Explorer.Application;
using SafeJunkCleaner.Explorer.Execution;
using SafeJunkCleaner.Explorer.Host;

internal static class Program
{
    private static int count;
    private static JsonElement Json(object o) => JsonSerializer.SerializeToElement(o);
    private static void Assert(bool value, string name) { if (!value) throw new Exception(name); count++; }
    private static void Reject(Action action, string name) { bool rejected = false; try { action(); } catch (InvalidOperationException) { rejected = true; } Assert(rejected, name); }
    private static async Task WaitForAnalysis(ExplorerCoordinator coordinator, string task, string id)
    {
        for (int i = 0; i < 2000; i++)
        {
            var result = Json(coordinator.GetAnalysisProgress(task, id));
            if (result.GetProperty("Status").GetString() != "Running") { Assert(result.GetProperty("Status").GetString() is not ("Failed" or "ModelUnavailable"), "heuristic analysis does not fail/model unavailable"); await Task.Delay(10); return; }
            await Task.Delay(5);
        }
        throw new Exception("Analysis timeout");
    }
    private static async Task ProtocolChecks(InventoryEngine engine, ExplorerCoordinator coordinator, string task, TrustedTaskHeader header)
    {
        using var input = new MemoryStream();
        void Request(string operation, object payload, bool owned = true)
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { ProtocolVersion = 1, RequestId = Guid.NewGuid().ToString("D"), TaskId = owned ? task : null, Operation = operation, Payload = payload }) + "\n"); input.Write(bytes);
        }
        Request("Health", new { }, false);
        Request("Analyze", new { TargetId = (string?)null, ExpectedEvidenceRevision = header.Revision, ExplorationMode = "Scope", UseModel = true });
        Request("Analyze", new { TargetId = header.RootObjectId, ExpectedEvidenceRevision = header.Revision, ExplorationMode = "Scope" });
        Request("Analyze", new { TargetId = (string?)null, ExpectedEvidenceRevision = header.Revision });
        Request("QuerySpace", new { AfterCursor = (string?)null, PageSize = 1 });
        Request("QuerySpace", new { AfterCursor = (string?)null, PageSize = 65 });
        Request("QuerySpace", new { AfterCursor = (string?)null, PageSize = 1, Path = header.RootPath });
        input.Position = 0; using var output = new StringWriter();
        await HostProtocol.RunAsync(engine, coordinator, engine.ListTasks, input, output);
        var lines = output.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(x => JsonDocument.Parse(x).RootElement.Clone()).ToArray();
        var health = lines[0].GetProperty("Result"); var caps = health.GetProperty("Capabilities");
        Assert(health.GetProperty("ContractVersion").GetInt32() == 3 && health.GetProperty("ModelMode").GetString() == "Absent" && caps.GetProperty("HeuristicExploration").GetBoolean() && !caps.GetProperty("ModelIncluded").GetBoolean(), "contract 3 explicitly excludes model");
        Assert(lines.Skip(1).Take(3).All(x => !x.GetProperty("Ok").GetBoolean()), "reject legacy model switch/mode mismatch/null selected");
        Assert(lines[4].GetProperty("Ok").GetBoolean() && lines.Skip(5).All(x => !x.GetProperty("Ok").GetBoolean()), "QuerySpace rejects excessive page and client paths");
        string invalidId = Json(coordinator.Analyze(task, "not-in-index", header.Revision)).GetProperty("AnalysisId").GetString()!;
        for (int i = 0; i < 1000 && Json(coordinator.GetAnalysisProgress(task, invalidId)).GetProperty("Status").GetString() == "Running"; i++) await Task.Delay(5);
        var invalid = Json(coordinator.GetAnalysisProgress(task, invalidId));
        Assert(invalid.GetProperty("Status").GetString() == "Failed" && invalid.GetProperty("Reason").GetString() == "TargetNotInInventory", "asynchronously loaded selected target must still belong to trusted snapshot");
        await Task.Delay(10); coordinator.InvalidateAnalysis(task, invalidId);
        var first = engine.QuerySpace(task, null, 1); Assert(first.Items.Count == 1 && first.NextCursor != null, "space first page has opaque continuation");
        var second = engine.QuerySpace(task, first.NextCursor, 64);
        Assert(second.Items.All(x => x.ObjectId != first.Items[0].ObjectId) && second.Revision == header.Revision, "stable space page has no overlap");
        string cursor = first.NextCursor!;
        Reject(() => engine.QuerySpace(task, cursor[..^1] + (cursor[^1] == 'A' ? "B" : "A"), 1), "tampered space cursor rejected");
        Reject(() => engine.QuerySpace(task, Guid.NewGuid().ToString("D"), 1), "old object-id cursor is not accepted");
        var codec = new OpaqueCursorCodec(); string bound = codec.Encode(task, header.Revision, "analysis-a", "sort-a", "suggestion-a", 1);
        Reject(() => codec.Decode(bound, task, header.Revision, "analysis-b", "sort-a", "suggestion-a"), "cursor analysis binding");
        Reject(() => codec.Decode(bound, task, header.Revision + 1, "analysis-a", "sort-a", "suggestion-a"), "cursor revision binding");
        Reject(() => codec.Decode(bound, task, header.Revision, "analysis-a", "sort-b", "suggestion-a"), "cursor sort binding");
        Reject(() => codec.Decode(bound, task, header.Revision, "analysis-a", "sort-a", "suggestion-b"), "cursor suggestion binding");
        var scoped = Json(coordinator.Analyze(task, null, header.Revision, "Scope")); string id = scoped.GetProperty("AnalysisId").GetString()!;
        Assert(scoped.TryGetProperty("Progress", out _) && scoped.TryGetProperty("Usage", out _) && !scoped.TryGetProperty("ModelStatus", out _), "analysis progress schema is model-free");
        coordinator.CancelAnalysis(task, id); await WaitForAnalysis(coordinator, task, id);
        var progress = Json(coordinator.GetAnalysisProgress(task, id));
        Assert(progress.GetProperty("Status").GetString() != "ModelUnavailable", "cancelled no-model exploration has no model-unavailable state");
        coordinator.InvalidateAnalysis(task, id);
    }
    private static async Task MultiTargetChecks(InventoryEngine engine, ExplorerCoordinator coordinator, HostInventoryRows rows, string local)
    {
        string scope = Path.Combine(local, "multi");
        foreach (string project in new[] { "small", "large" })
        {
            string root = Path.Combine(scope, project); Directory.CreateDirectory(Path.Combine(root, "bin"));
            File.WriteAllText(Path.Combine(root, project + ".csproj"), "<Project Sdk=\"Microsoft.NET.Sdk\" />");
            File.WriteAllText(Path.Combine(root, "bin", project + ".dll"), new string('X', project == "large" ? 100 : 10));
            File.WriteAllText(Path.Combine(root, "bin", project + ".deps.json"), "{}");
        }
        string task = engine.CreateInventory(scope);
        for (int i = 0; i < 2000 && engine.ReadTaskHeader(task).State == "Inventory"; i++) await Task.Delay(5);
        var header = rows.ReadHeader(task); string id = Json(coordinator.Analyze(task, null, header.Revision, "Scope")).GetProperty("AnalysisId").GetString()!;
        await WaitForAnalysis(coordinator, task, id);
        var page = Json(coordinator.QuerySuggestions(task, id, null, 64));
        var review = page.GetProperty("Items").EnumerateArray().Where(s => s.GetProperty("MayPrepareForReview").GetBoolean()).ToArray();
        Assert(review.Length == 2 && review.All(s => s.GetProperty("Classification").GetString() == "BuildArtifact"), "scope exploration yields two independently reviewable generated subsets");
        Assert(review[0].GetProperty("LogicalBytes").GetInt64() > review[1].GetProperty("LogicalBytes").GetInt64(), "review suggestions sort by descending observed logical benefit");
        var draft = Json(coordinator.PrepareApproval(task, id, review.Select(s => s.GetProperty("SuggestionId").GetString()!).ToArray(), header.Revision));
        var items = Json(coordinator.QueryApprovalItems(task, draft.GetProperty("DraftId").GetString()!, 0, 64)).GetProperty("Items").EnumerateArray().ToArray();
        Assert(items.Length == 4 && items.Select(i => i.GetProperty("File").GetProperty("Identity").GetString()).Distinct().Count() == 4, "multi-target approval contains exact four disjoint identities");
        Assert(items.All(i => !i.GetProperty("File").GetProperty("Path").GetString()!.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase)), "project markers never become execution members");
        coordinator.InvalidateAnalysis(task, id);
        Reject(() => coordinator.ConfirmApproval(task, draft.GetProperty("DraftId").GetString()!, draft.GetProperty("DisplayHash").GetString()!), "multi-target draft invalidation rejects stale generation");
    }
    private sealed class SimulatedRecycler : IRecycleOnly
    {
        public int Calls; public ApartmentState Apartment;
        public bool IsAvailable => true; public string UnavailableReason => "SimulationOnly";
        public RecycleResult Recycle(FileSnapshot file, CancellationToken token) { Calls++; Apartment = Thread.CurrentThread.GetApartmentState(); return new(false, "SimulatedNoFilesystemEffects"); }
    }
    private sealed class BlockingPrepareSource(IApprovalSource inner, ITrustedAnalysisSnapshots snapshots) : IApprovalSource, IApprovalSourceReadScope
    {
        internal volatile bool Block;
        internal readonly ManualResetEventSlim Entered = new();
        public IDisposable BeginReadScope() => ((IApprovalSourceReadScope)inner).BeginReadScope();
        public ApprovalSource Read(string task)
        {
            if (Block)
            {
                Entered.Set();
                var token = ((ITrustedAnalysisBuildContext)snapshots).BuildCancellationToken;
                while (Block) { token.ThrowIfCancellationRequested(); Thread.Sleep(5); }
            }
            return inner.Read(task);
        }
    }
    private static async Task UnsupportedNameCoverageChecks(InventoryEngine engine, ExplorerCoordinator coordinator, HostInventoryRows rows, string local)
    {
        string scope = Path.Combine(local, "unsupported-name-coverage"); Directory.CreateDirectory(scope);
        File.WriteAllText(Path.Combine(scope, "ordinary.tmp"), "owned artificial file");
        // Extended API input is used only to create the owned adverse fixture. Product
        // path policy remains unchanged and must refuse this exact raw filename.
        string unsupported = Path.Combine(scope, "unsupported.");
        File.WriteAllText(@"\\?\" + unsupported, "owned unsupported-name fixture; never probe");
        Assert(Directory.EnumerateFileSystemEntries(scope).Any(p => p.EndsWith("unsupported.", StringComparison.Ordinal)), "real adverse filename preserved by NTFS fixture");
        string task = engine.CreateInventory(scope);
        for (int i = 0; i < 2000 && engine.ReadTaskHeader(task).State == "Inventory"; i++) await Task.Delay(5);
        var header = rows.ReadHeader(task);
        Assert(header.State == "Partial", "real unsupported-name scan remains incomplete, not success");
        var coverageProgress=Json(engine.GetProgress(task));
        Assert(coverageProgress.GetProperty("SkippedReasons").GetProperty("MetadataUnavailable").GetInt64() == 1,
            "completed partial inventory exposes safe actual skip counts without user paths");
        var snapshot = new InventorySnapshotAdapter(rows, header.OwnerSid).Load(task, header.Revision);
        var gap = snapshot.Coverage.Single(c => c.Path == unsupported);
        Assert(!gap.Analyzable && gap.Coverage == "NotCovered" && gap.Reason == "MetadataUnavailable:InvalidOperationException", "actual Inventory unknown row loads as coverage-only gap");
        Assert(!snapshot.Evidence.Targets.Values.Any(t => t.Path == unsupported), "unsupported filename never becomes an analysis target");
        string id = Json(coordinator.Analyze(task, null, header.Revision, "Scope")).GetProperty("AnalysisId").GetString()!;
        await WaitForAnalysis(coordinator, task, id);
        var progress = Json(coordinator.GetAnalysisProgress(task, id));
        Assert(progress.GetProperty("HasResult").GetBoolean(), "actual partial inventory can publish protected analysis facts instead of throwing NonCanonicalPath");
        var page = Json(coordinator.QuerySuggestions(task, id, null, 64));
        Assert(page.GetProperty("Items").EnumerateArray().All(s => !s.GetProperty("MayPrepareForReview").GetBoolean()), "incomplete adverse fixture cannot gain review approval");
        coordinator.InvalidateAnalysis(task, id);
        Assert(File.Exists(@"\\?\" + unsupported) && File.Exists(Path.Combine(scope, "ordinary.tmp")), "adverse and ordinary input files retained without deletion");
    }
    public static async Task<int> Main(string[] args)
    {
        if (args.Length > 1 && args[1] == "--lifecycle") { await LifecycleChecks.Run(args[0]); return 0; }
        string local = TestEvidence.CreateFixture(args[0], "host-fixture"); Directory.CreateDirectory(local);
        File.WriteAllText(Path.Combine(local, ".sandbox-owner"), WindowsIdentity.GetCurrent().User!.Value + "|" + local);
        string files = Path.Combine(local, "project"); Directory.CreateDirectory(Path.Combine(files, "bin"));
        File.WriteAllText(Path.Combine(files, "app.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk\" />"); File.WriteAllText(Path.Combine(files, "bin", "app.dll"), "synthetic dll never executed"); File.WriteAllText(Path.Combine(files, "bin", "app.deps.json"), "{}");
        string evidence = Path.Combine(args[0], "host-provider-" + Guid.NewGuid().ToString("D")); Directory.CreateDirectory(evidence);
        try
        {
            string state = Path.Combine(local, "state"); using var engine = new InventoryEngine(state); var rows = new HostInventoryRows(engine);
            using var store = new WindowsApprovalStore(Path.Combine(local, "approval")); var baseFacts = new WindowsExecutionFacts(state); ExplorerCoordinator? coordinator = null;
            var provider = new HostBuildArtifactProvider(rows, () => coordinator!); var facts = new WindowsExecutionFacts(state, provider); var fake = new SimulatedRecycler();
            BlockingPrepareSource? blocker = null;
            using var owned = coordinator = new(rows, facts.OwnerSid, store, facts, fake, a => { var source = new ApprovalSourceAdapter(rows, a, baseFacts, provider.BindCandidateHash); provider.Bind(source); return blocker = new(source, a); }, provider.Register);
            string task = engine.CreateInventory(files);
            for (int i = 0; i < 1000 && Json(engine.GetProgress(task)).GetProperty("Task").GetProperty("State").GetString() == "Inventory"; i++) await Task.Delay(5);
            var header = rows.ReadHeader(task);
            await ProtocolChecks(engine, coordinator, task, header);
            using (var spaceRelease = new ManualResetEventSlim())
            {
                var spaceStarted = Json(coordinator.QuerySpaceAsync(task, null, 64, () => { spaceRelease.Wait(TimeSpan.FromSeconds(5)); return engine.QuerySpace(task, null, 64); }));
                Assert(spaceStarted.GetProperty("Status").GetString() == "Running", "space aggregation returns a background job state rather than blocking the reader");
                var spacePoll = Task.Run(() => coordinator.QuerySpaceAsync(task, null, 64, () => throw new Exception("Duplicate query work")));
                Assert(await Task.WhenAny(spacePoll, Task.Delay(1000)) == spacePoll && Json(await spacePoll).GetProperty("Status").GetString() == "Running", "space progress poll remains responsive while its worker is blocked");
                spaceRelease.Set();
                JsonElement spaceDone = default;
                for (int i = 0; i < 1000; i++) { spaceDone = Json(coordinator.QuerySpaceAsync(task, null, 64, () => throw new Exception("Duplicate query work"))); if (spaceDone.GetProperty("Status").GetString() != "Running") break; await Task.Delay(5); }
                Assert(spaceDone.GetProperty("Status").GetString() == "Ready" && spaceDone.GetProperty("Page").GetProperty("Items").GetArrayLength() > 0, "background space query publishes actual page only when ready");
            }
            var a = Json(coordinator.Analyze(task, header.RootObjectId, header.Revision)); string analysis = a.GetProperty("AnalysisId").GetString()!;
            for (int i = 0; i < 1000 && Json(coordinator.GetAnalysisProgress(task, analysis)).GetProperty("Status").GetString() == "Running"; i++) await Task.Delay(5);
            var allSuggestions = Json(coordinator.QuerySuggestions(task, analysis, null, 64)).GetProperty("Items");
            var suggestions = allSuggestions.EnumerateArray().Where(s => s.GetProperty("MayPrepareForReview").GetBoolean()).ToArray();
            Assert(suggestions.Length == 1 && suggestions[0].GetProperty("Classification").GetString() == "BuildArtifact" && suggestions[0].GetProperty("CandidateCount").GetInt32() == 2, "Exact project dll+deps is the only reviewable subset");
            Assert(allSuggestions.EnumerateArray().Where(s => s.GetProperty("Classification").GetString() == "Mixed").All(s => !s.GetProperty("MayPrepareForReview").GetBoolean() && s.GetProperty("CandidateCount").GetInt32() == 0), "mixed project root remains display-only with no members");
            var suggestionPage = Json(coordinator.QuerySuggestions(task, analysis, null, 1));
            string suggestionCursor = suggestionPage.GetProperty("NextAfterId").GetString()!;
            Assert(suggestionPage.GetProperty("CursorSchema").GetString() == "opaque-hmac-v1" && suggestionPage.GetProperty("Revision").GetInt64() == header.Revision, "suggestion cursor schema is text and revision is int64");
            Assert(suggestions[0].GetProperty("TargetPath").GetString() == Path.Combine(files, "bin") && allSuggestions.EnumerateArray().All(s => s.GetProperty("TargetPath").GetString() == coordinator.ReadInventory(task, header.Revision).Evidence.Targets[s.GetProperty("TargetId").GetString()!].Path), "all suggestion target paths come from trusted inventory mapping");
            Assert(suggestionPage.GetProperty("Items")[0].GetProperty("SuggestionId").GetString() == suggestions[0].GetProperty("SuggestionId").GetString(), "review subset sorts before display-only parent");
            var suggestionSecond = Json(coordinator.QuerySuggestions(task, analysis, suggestionCursor, 1));
            Assert(suggestionSecond.GetProperty("Items")[0].GetProperty("SuggestionId").GetString() != suggestions[0].GetProperty("SuggestionId").GetString() && suggestionSecond.GetProperty("NextAfterId").ValueKind == JsonValueKind.Null, "suggestion opaque pagination is stable and exact");
            var membersPage = Json(coordinator.QuerySuggestionFiles(task, analysis, suggestions[0].GetProperty("SuggestionId").GetString()!, null, 1));
            string memberCursor = membersPage.GetProperty("NextAfterId").GetString()!;
            Assert(membersPage.GetProperty("CursorSchema").GetString() == "opaque-hmac-v1" && membersPage.GetProperty("Revision").GetInt64() == header.Revision && membersPage.GetProperty("Sort").GetString() == "objectid-ordinal-v1", "member page additive metadata preserves text schema/int64 revision");
            var membersSecond = Json(coordinator.QuerySuggestionFiles(task, analysis, suggestions[0].GetProperty("SuggestionId").GetString()!, memberCursor, 1));
            Assert(membersPage.GetProperty("Items")[0].GetProperty("ObjectId").GetString() != membersSecond.GetProperty("Items")[0].GetProperty("ObjectId").GetString(), "candidate opaque pagination contains exact disjoint files");
            Reject(() => coordinator.QuerySuggestionFiles(task, analysis, allSuggestions[1].GetProperty("SuggestionId").GetString()!, memberCursor, 1), "member cursor cannot move to another suggestion");
            var usage = Json(coordinator.GetAnalysisProgress(task, analysis)).GetProperty("Usage");
            Assert(usage.GetProperty("HashFiles").GetInt32() == 1 && usage.GetProperty("HashBytes").GetInt64() == new FileInfo(Path.Combine(files, "bin", "app.dll")).Length, "first display DLL proof is counted exactly once in final investigation usage");
            string dll = Path.Combine(files, "bin", "app.dll"); var proof = provider.ReadCurrent(dll); Assert(proof is { TrustedIndexClassifiedBuildArtifact: true } && proof.Candidate.ContentSha256 is { Length: 64 } && proof.ProjectMarker.ContentSha256 is { Length: 64 }, "Candidate and project marker full hashes bound");
            Assert(facts.HardProtection(dll) == null && baseFacts.HardProtection(dll) != null, "Exception only in composed execution facts");
            blocker!.Block = true;
            var beginClock = System.Diagnostics.Stopwatch.StartNew();
            var blockedPreparation = Json(coordinator.BeginPrepareApproval(task, analysis, [suggestions[0].GetProperty("SuggestionId").GetString()!], header.Revision));
            Assert(beginClock.Elapsed < TimeSpan.FromSeconds(1) && blocker.Entered.Wait(TimeSpan.FromSeconds(2)), "preparation starts without holding request reader behind blocked work");
            string blockedId = blockedPreparation.GetProperty("PreparationId").GetString()!;
            var progressTask = Task.Run(() => coordinator.GetPreparationProgress(task, blockedId));
            Assert(await Task.WhenAny(progressTask, Task.Delay(1000)) == progressTask, "progress responds while preparation source is blocked");
            Reject(() => coordinator.InvalidateAnalysis(task, analysis), "active preparation blocks analysis replacement");
            coordinator.CancelPreparation(task, blockedId);
            for (int i = 0; i < 1000 && Json(coordinator.GetPreparationProgress(task, blockedId)).GetProperty("Status").GetString() == "Running"; i++) await Task.Delay(5);
            Assert(Json(coordinator.GetPreparationProgress(task, blockedId)).GetProperty("Status").GetString() == "Cancelled", "blocked preparation cancels without producing a draft or execution claim");
            blocker.Block = false;
            var draft = Json(coordinator.PrepareApproval(task, analysis, [suggestions[0].GetProperty("SuggestionId").GetString()!], header.Revision));
            var preparation = Json(coordinator.BeginPrepareApproval(task, analysis, [suggestions[0].GetProperty("SuggestionId").GetString()!], header.Revision));
            string preparationId = preparation.GetProperty("PreparationId").GetString()!;
            for (int i = 0; i < 2000; i++)
            {
                preparation = Json(coordinator.GetPreparationProgress(task, preparationId));
                if (preparation.GetProperty("Status").GetString() != "Running") break;
                await Task.Delay(5);
            }
            Assert(preparation.GetProperty("Status").GetString() == "Ready" && preparation.GetProperty("CheckedFiles").GetInt32() == 2, "background preparation reports real file checks and reaches Ready");
            Assert(preparation.GetProperty("Prepared").GetProperty("CandidateSetHash").GetString() == draft.GetProperty("CandidateSetHash").GetString(), "background and synchronous preparation preserve exact candidate set");
            Reject(() => coordinator.GetPreparationProgress(Guid.NewGuid().ToString("D"), preparationId), "preparation cannot be queried from another task");
            Assert(draft.GetProperty("ItemCount").GetInt32() == 2, "Exact dll+deps draft not whole root");
            Assert(draft.GetProperty("AlgorithmMode").GetString() == "Heuristic" && !draft.TryGetProperty("ModelStatus", out _), "prepare approval uses strict heuristic contract without model status");
            var confirm = Json(coordinator.ConfirmApproval(task, draft.GetProperty("DraftId").GetString()!, draft.GetProperty("DisplayHash").GetString()!)); string approval = confirm.GetProperty("ApprovalId").GetString()!;
            Assert(confirm.GetProperty("CanExecute").GetBoolean(), "Explicit confirmed seal can execute");
            coordinator.ExecuteApproved(task, approval);
            for (int i = 0; i < 1000 && fake.Calls < 2; i++) await Task.Delay(5);
            Assert(fake.Calls == 2 && fake.Apartment == ApartmentState.STA, "Approved simulation runs on actual STA queue");
            Assert(File.Exists(dll) && File.Exists(Path.Combine(files, "bin", "app.deps.json")), "Mock recycler leaves all files intact");
            var result = Json(coordinator.GetExecutionResult(task, approval, 0, 64));
            for (int i = 0; i < 1000 && result.GetProperty("Status").GetString() == "Running"; i++) { await Task.Delay(5); result = Json(coordinator.GetExecutionResult(task, approval, 0, 64)); }
            Assert(result.GetProperty("RecycledLogicalBytes").GetInt64() == 0, "Simulation never claims recycled bytes");
            var oldDraft = Json(coordinator.PrepareApproval(task, analysis, [suggestions[0].GetProperty("SuggestionId").GetString()!], header.Revision));
            var oldSeal = Json(coordinator.ConfirmApproval(task, oldDraft.GetProperty("DraftId").GetString()!, oldDraft.GetProperty("DisplayHash").GetString()!));
            coordinator.InvalidateAnalysis(task, analysis);
            Reject(() => coordinator.ConfirmApproval(task, oldDraft.GetProperty("DraftId").GetString()!, oldDraft.GetProperty("DisplayHash").GetString()!), "invalidated generation cannot confirm old draft");
            Reject(() => coordinator.ExecuteApproved(task, oldSeal.GetProperty("ApprovalId").GetString()!), "invalidated generation cannot execute old seal");
            Assert(provider.ReadCurrent(dll) == null, "Stale analysis source cannot authorize dll");
            var next = Json(coordinator.Analyze(task, null, header.Revision, "Scope")); string nextId = next.GetProperty("AnalysisId").GetString()!;
            Assert(nextId != analysis && next.GetProperty("ExplorationMode").GetString() == "Scope", "fresh scope generation has new GUID");
            await WaitForAnalysis(coordinator, task, nextId);
            Reject(() => coordinator.QuerySuggestions(task, nextId, suggestionCursor, 1), "suggestion cursor cannot survive analysis generation change");
            Reject(() => coordinator.ConfirmApproval(task, oldDraft.GetProperty("DraftId").GetString()!, oldDraft.GetProperty("DisplayHash").GetString()!), "reanalysis cannot revive an old draft");
            Reject(() => coordinator.ExecuteApproved(task, oldSeal.GetProperty("ApprovalId").GetString()!), "reanalysis cannot revive an old seal");
            File.AppendAllText(Path.Combine(files, "app.csproj"), "changed"); Assert(facts.HardProtection(dll) != null, "Project marker tamper revokes exact exception");
            coordinator.InvalidateAnalysis(task, nextId);
            await MultiTargetChecks(engine, coordinator, rows, local);
            await UnsupportedNameCoverageChecks(engine, coordinator, rows, local);
            count += await AsyncAnalysisChecks.Run(engine);
            count += await ProofBudgetChecks.Run(local);
            count += await StorageRecoveryChecks.Run(local);
            File.WriteAllText(Path.Combine(evidence, "result.json"), JsonSerializer.Serialize(new { Passed = true, Assertions = count, Sandbox = local, SimulationOnly = true, NativeRecycleCalls = 0 }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"HOST PROVIDER SIMULATION PASS {count} assertions; evidence {evidence}"); return 0;
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(evidence, "failure.txt"), ex.ToString()); Console.Error.WriteLine(ex); return 1; }
    }
}
