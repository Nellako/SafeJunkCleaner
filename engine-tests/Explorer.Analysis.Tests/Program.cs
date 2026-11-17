using System.Security.Principal;
using System.Text.Json;
using SafeJunkCleaner.Explorer.Analysis;

internal static class Program
{
    private static int count; private static readonly List<object> checks = [];
    private static void Assert(bool ok, string name) { if (!ok) throw new Exception(name); count++; checks.Add(new { Name = name, Passed = true }); }
    private sealed class Scripted(params ExplorationAction[] actions) : IExplorationDecider
    {
        private int index; public List<AnalysisState> States { get; } = [];
        public ValueTask<ExplorationDecision> DecideAsync(AnalysisState state, CancellationToken token)
        { States.Add(state); return ValueTask.FromResult(new ExplorationDecision(true, index < actions.Length ? actions[index++] : ExplorationAction.Stop, state.TargetId)); }
    }
    private sealed class Forged : IExplorationDecider
    { public ValueTask<ExplorationDecision> DecideAsync(AnalysisState s, CancellationToken t) => ValueTask.FromResult(new ExplorationDecision(true, ExplorationAction.InspectDuplicates, "not-in-inventory")); }
    private static InventoryEvidenceSnapshot Inventory(string root)
    {
        var list = new List<InventoryTarget>(); var ids = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); int i = 0;
        void Add(string p, string? parent)
        {
            string id = "object-" + i++; ids[p] = id; list.Add(MetadataAccess.Capture(id, parent, p));
            if (Directory.Exists(p)) foreach (var child in Directory.EnumerateFileSystemEntries(p).OrderBy(p => p, StringComparer.Ordinal)) Add(child, id);
        }
        Add(root, null); return new(Guid.NewGuid().ToString("D"), 1, list[0].ObjectId, list);
    }
    private static void Text(string root, string path, string text) { var p = Path.Combine(root, path); Directory.CreateDirectory(Path.GetDirectoryName(p)!); File.WriteAllText(p, text); }
    private static async Task<AnalysisResult> Run(string root, IExplorationDecider? decider = null, AnalysisBudget? budget = null)
    { var snapshot = Inventory(root); return await new BoundedExplorationScheduler().AnalyzeAsync(snapshot, snapshot.RootId, decider ?? new UnavailableDecider(), budget); }
    public static async Task<int> Main(string[] args)
    {
        string evidence = Path.Combine(args[0], "analysis-" + Guid.NewGuid().ToString("D")); Directory.CreateDirectory(evidence);
        string sandbox = TestEvidence.CreateFixture(args[0], "analysis-fixture");
        Directory.CreateDirectory(sandbox); File.WriteAllText(Path.Combine(sandbox, ".sandbox-owner"), WindowsIdentity.GetCurrent().User!.Value + "|" + sandbox);
        string Case(string name) { string p = Path.Combine(sandbox, name); Directory.CreateDirectory(p); return p; }
        try
        {
            var net = Case("dotnet"); Text(net, "app.csproj", "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>"); Text(net, "Program.cs", "synthetic source never execute"); Text(net, "bin/app.dll", "synthetic assembly"); Text(net, "bin/app.deps.json", "{}"); Text(net, "obj/project.assets.json", "{}");
            var result = await Run(net); Assert(result.Status == AnalysisStatus.ModelUnavailable, "UnavailableExplicitFactsOnly");
            Assert(result.Suggestions.Count(s => s.Classification == Classification.BuildArtifact) == 2, "DotnetBinAndObjDetected");
            Assert(result.Suggestions.All(s => s.TargetId != Inventory(net).RootId), "ProjectRootNotOutput");
            Assert(result.Suggestions.SelectMany(s => s.CandidateFiles).All(f => f.ObjectId != "object-0"), "CandidatesAreExactFiles");
            Assert(result.Suggestions.All(s => !s.SelectedByDefault), "NeverDefaultSelected");
            Assert(result.Suggestions.All(s => s.EvidenceIds.All(id => result.Evidence.Any(e => e.EvidenceId == id))), "EvidenceReferencesResolved");
            var rootOnly = Case("project-root-only"); Text(rootOnly, "app.csproj", "<Project Sdk=\"Microsoft.NET.Sdk\" />"); Text(rootOnly, "Program.cs", "synthetic"); Assert((await Run(rootOnly)).Suggestions.Count == 0, "RootProjectNotSuggested");
            Text(net, "docs/readme.pdf", "synthetic private body not read"); result = await Run(net); Assert(result.Suggestions.Count(s => s.MayPrepareForReview) == 2 && result.Suggestions.Any(s => s.Classification == Classification.Mixed), "RootDocsProtectRootNotExactOutputs");
            Text(net, "bin/handwritten.py", "never execute"); result = await Run(net); Assert(!result.Suggestions.Any(s => s.MayPrepareForReview && s.CandidateFiles.Any(f => f.ObjectId == Inventory(net).Targets.Values.First(t => t.Path.EndsWith("handwritten.py")).ObjectId)), "HandwrittenOutputProtected");
            Text(net, "bin/secret.cs", "source"); result = await Run(net); Assert(result.Suggestions.Where(s => s.Classification == Classification.Mixed).All(s => s.HardProtected && !s.MayPrepareForReview), "MixedSourceProtected"); Assert(result.Suggestions.Any(s => s.Classification == Classification.Mixed), "MixedSourceDetected");
            var frontend = Case("frontend"); Text(frontend, "package.json", "{\"scripts\":{\"build\":\"vite build\"}}"); Text(frontend, "dist/index.html", "synthetic generated"); Text(frontend, "dist/assets/index-a1b2c3d4.js", "synthetic generated");
            result = await Run(frontend); Assert(result.Suggestions.Single().Classification == Classification.BuildArtifact, "FrontendDistDetected"); Assert(result.Suggestions.Single().CandidateFiles.Count == 2, "DistExactTwoFiles");
            var protectedSnapshot = Inventory(frontend); protectedSnapshot = new(protectedSnapshot.TaskId, protectedSnapshot.Revision, protectedSnapshot.RootId, protectedSnapshot.Targets.Values.Select(t => t.ObjectId == protectedSnapshot.RootId ? t with { HardProtected = true } : t));
            result = await new BoundedExplorationScheduler().AnalyzeAsync(protectedSnapshot, protectedSnapshot.RootId, new UnavailableDecider()); Assert(result.Usage.ReadFiles == 0 && result.Suggestions.All(s => s.HardProtected && !s.MayPrepareForReview), "InventoryAncestorProtectionCannotBypass");
            var fake = Case("fake-dist"); Text(fake, "package.json", "{\"scripts\":{\"build\":\"echo arbitrary\"}}"); Text(fake, "dist/index.html", "x"); Text(fake, "dist/assets/index-a1b2c3d4.js", "x"); Assert((await Run(fake)).Suggestions.Count == 0, "ArbitraryBuildScriptNotTrusted");
            var noPackage = Case("dist-name-only"); Text(noPackage, "dist/index.html", "x"); Assert((await Run(noPackage)).Suggestions.Count == 0, "DistNameAloneInsufficient");
            var chrome = Case("custom-location"); Directory.CreateDirectory(chrome); File.WriteAllBytes(Path.Combine(chrome, "index"), [0xc3, 0xca, 0x03, 0xc1, 0, 0, 0, 0]); for (int i = 0; i < 4; i++) Text(chrome, "data_" + i, "synthetic"); Text(chrome, "f_abcdef", "synthetic entry");
            result = await Run(chrome); Assert(result.Suggestions.Single().Classification == Classification.Cache, "ChromiumCustomLocationDetected"); Assert(result.Suggestions.Single().EvidenceIds.Count >= 2, "ChromiumMultipleEvidence");
            var namedCache = Case("Cache"); Text(namedCache, "data.txt", "not enough"); Assert((await Run(namedCache)).Suggestions.Count == 0, "CacheNameNotEvidence");
            Text(chrome, "holiday.jpg", "synthetic private photo no body read"); result = await Run(chrome); Assert(!result.Suggestions.Any(s => s.MayPrepareForReview), "PhotoMixedCacheProtected"); Assert(result.Evidence.Any(e => e.Kind == EvidenceKind.Protection), "PhotoProtectionEvidence");
            var portable = Case("portable"); Text(portable, "app.exe", "not executed"); Text(portable, "portable.ini", "never read"); Text(portable, "old.log", "x"); result = await Run(portable); Assert(result.Suggestions.Single().Classification == Classification.Portable && result.Suggestions.Single().HardProtected, "PortableNotResidual");
            var personal = Case("personal"); foreach (var ext in new[] { ".docx", ".jpg", ".bak", ".sqlite" }) Text(personal, "synthetic" + ext, "do not read"); result = await Run(personal); Assert(result.Suggestions.Any(s => s.Classification == Classification.Mixed && s.HardProtected), "DocumentsPhotosBackupDatabaseProtected"); Assert(result.Usage.ReadFiles == 0 && result.Usage.HashBytes == 0, "PrivateBodiesNeverRead");
            var large = Case("large"); Text(large, "big.bin", new string('x', 2048)); result = await Run(large, budget: new AnalysisBudget(LargeFileBytes: 1024)); Assert(result.Suggestions.Any(s => s.Classification == Classification.SpaceOnly && s.HardProtected && s.Level == SuggestionLevel.OrganizeOpportunity), "LargeFileOrganizeOnly");
            var downloads = Case("downloads"); byte[] zip = [0x50, 0x4b, 3, 4, 1, 2, 3, 4, 5, 6]; File.WriteAllBytes(Path.Combine(downloads, "setup-a.zip"), zip); File.WriteAllBytes(Path.Combine(downloads, "setup-b.zip"), zip);
            var inspect = new Scripted(ExplorationAction.InspectDuplicates, ExplorationAction.Stop); result = await Run(downloads, inspect); Assert(result.Suggestions.Single().Classification == Classification.InstallerDuplicate, "PackageDuplicateFullHash"); Assert(result.Usage.HashBytes == 20 && result.Usage.HashFiles == 2, "FullHashBudgetTracked"); Assert(result.Suggestions.Single().CandidateFiles.Count == 1, "RetainedCopyExcluded"); Assert(result.Suggestions.Single().Duplicate is { ContentSha256.Length: 64, RetainedChoiceConfirmed: false } && result.Suggestions.Single().Duplicate!.RetainedFiles.Count == 1, "DuplicateHashAndUnconfirmedKeeper"); Assert(!result.Suggestions.Single().MayPrepareForReview && result.Suggestions.Single().Level == SuggestionLevel.OrganizeOpportunity, "GenericZipOrganizeOnly"); Assert(result.Evidence.Any(e => e.Value == "RetainedCopyIdentityAndMetadataReconfirmed"), "RetainedCopyConfirmed");
            var stop = await Run(downloads, new Scripted(ExplorationAction.Stop)); Assert(stop.Usage.HashBytes == 0 && !stop.Suggestions.Any(s => s.Classification == Classification.InstallerDuplicate), "DecisionChangesActualNextProbe");
            Assert(inspect.States.All(s => !JsonSerializer.Serialize(s).Contains(sandbox, StringComparison.OrdinalIgnoreCase)), "DecisionStateHasNoPaths"); Assert(inspect.States.SelectMany(s => s.Evidence).All(e => e.Value.Length < 100), "DecisionEvidenceShort");
            byte[] otherZip = [0x50, 0x4b, 3, 4, 9, 9, 9, 9, 9, 9]; File.WriteAllBytes(Path.Combine(downloads, "other-a.zip"), otherZip); File.WriteAllBytes(Path.Combine(downloads, "other-b.zip"), otherZip);
            result = await Run(downloads, new Scripted(ExplorationAction.InspectDuplicates, ExplorationAction.Stop)); Assert(result.Suggestions.Count(s => s.Duplicate != null) == 2 && result.Suggestions.Select(s => s.SuggestionId).Distinct().Count() == 2, "MultipleDuplicateGroupsPreserved");
            result = await Run(downloads, new Scripted(ExplorationAction.InspectDuplicates), new AnalysisBudget(MaxHashBytes: 5)); Assert(result.Status == AnalysisStatus.BudgetExhausted && result.Suggestions.Count == 0, "HashBudgetFailClosed");
            result = await Run(downloads, new Scripted(ExplorationAction.InspectLayout, ExplorationAction.InspectLayout)); Assert(result.Status == AnalysisStatus.NoProgress, "RepeatNoProgressStops");
            result = await Run(downloads, new Forged()); Assert(result.Status == AnalysisStatus.InvalidDecision && result.Usage.HashBytes == 0, "ForgedTargetRejected");
            result = await Run(downloads, new Scripted(ExplorationAction.AskUser)); Assert(result.Status == AnalysisStatus.AskedUser && result.Evidence.Any(e => e.Kind == EvidenceKind.Question), "AskUserNoExecution");
            result = await Run(downloads, new Scripted(ExplorationAction.InspectOwnership, ExplorationAction.Stop)); Assert(result.Evidence.Any(e => e.Kind == EvidenceKind.Ownership) && result.Suggestions.Count == 0, "OwnershipNotAuthorization");
            result = await Run(downloads, budget: new AnalysisBudget(MaxMetadataObjects: 1)); Assert(result.Status == AnalysisStatus.BudgetExhausted, "MetadataBudget");
            var snapshot = Inventory(downloads); using var cancelled = new CancellationTokenSource(); cancelled.Cancel(); result = await new BoundedExplorationScheduler().AnalyzeAsync(snapshot, snapshot.RootId, new UnavailableDecider(), cancellationToken: cancelled.Token); Assert(result.Status == AnalysisStatus.Cancelled, "ExplicitCancellation");
            snapshot = Inventory(downloads); File.AppendAllText(Path.Combine(downloads, "setup-a.zip"), "changed"); result = await new BoundedExplorationScheduler().AnalyzeAsync(snapshot, snapshot.RootId, new Scripted(ExplorationAction.InspectDuplicates)); Assert(!result.Suggestions.Any(s => s.Duplicate?.RetainedFiles.Any(f => f.ObjectId == snapshot.Targets.Values.First(t => t.Path.EndsWith("setup-a.zip")).ObjectId) == true || s.CandidateFiles.Any(f => f.ObjectId == snapshot.Targets.Values.First(t => t.Path.EndsWith("setup-a.zip")).ObjectId)), "ChangedInventoryFileNoDuplicateSuggestion");
            var unknown = new Suggestion("s", "o", Classification.Unknown, SuggestionLevel.ReviewSuggested, [new("f", "id", 1, 1)], [], [], "unknown", false); Assert(!unknown.MayPrepareForReview, "UnknownCannotPrepareReview");
            await HeuristicTests.Run(sandbox, Assert);
            Assert(File.Exists(Path.Combine(net, "Program.cs")) && File.Exists(Path.Combine(downloads, "setup-b.zip")), "FixturesNotDeletedOrExecuted");
            File.WriteAllText(Path.Combine(evidence, "result.json"), JsonSerializer.Serialize(new { Passed = true, Assertions = count, Sandbox = sandbox, AnalysisSha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(typeof(BoundedExplorationScheduler).Assembly.Location))), Checks = checks }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"ANALYSIS SELFTEST PASS {count} assertions; evidence {evidence}"); return 0;
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(evidence, "failure.txt"), ex.ToString()); Console.Error.WriteLine(ex); return 1; }
    }
}
