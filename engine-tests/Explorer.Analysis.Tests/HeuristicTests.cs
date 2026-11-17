using System.Runtime.InteropServices;
using SafeJunkCleaner.Explorer.Analysis;

internal static class HeuristicTests
{
    private sealed class Sink(Action<HeuristicProgress>? callback = null) : IProgress<HeuristicProgress>
    {
        internal readonly List<HeuristicProgress> Values = [];
        public void Report(HeuristicProgress value) { Values.Add(value); callback?.Invoke(value); }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLink(string path, string existing, IntPtr security);
    private static InventoryEvidenceSnapshot Inventory(string root)
    {
        var targets = new List<InventoryTarget>(); int next = 0;
        void Add(string p, string? parent)
        {
            var t = MetadataAccess.Capture("h-" + next++, parent, p); targets.Add(t);
            if (t.Kind == TargetKind.Directory)
                foreach (var child in Directory.EnumerateFileSystemEntries(p).OrderBy(p => p, StringComparer.Ordinal)) Add(child, t.ObjectId);
        }
        Add(root, null); return new(Guid.NewGuid().ToString("D"), 1, targets[0].ObjectId, targets);
    }
    private static void Text(string root, string path, string text)
    { string p = Path.Combine(root, path); Directory.CreateDirectory(Path.GetDirectoryName(p)!); File.WriteAllText(p, text); }
    private static void Cache(string root, string path)
    {
        string dir = Path.Combine(root, path); Directory.CreateDirectory(dir);
        File.WriteAllBytes(Path.Combine(dir, "index"), [0xc3, 0xca, 0x03, 0xc1, 0, 0, 0, 0]);
        for (int i = 0; i < 4; i++) Text(dir, "data_" + i, "synthetic cache"); Text(dir, "f_abcdef", "synthetic entry");
    }
    private static void Project(string root, string path)
    {
        Text(root, Path.Combine(path, "app.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk\" />");
        Text(root, Path.Combine(path, "Program.cs"), "synthetic source never execute");
        Text(root, Path.Combine(path, "bin/app.dll"), "synthetic generated");
        Text(root, Path.Combine(path, "bin/app.deps.json"), "{}");
        Text(root, Path.Combine(path, "obj/project.assets.json"), "{}");
    }
    // Evaluation control: identical probes, safety gates and budget; only traversal order changes.
    private static AnalysisResult FixedOrder(InventoryEvidenceSnapshot snapshot, HeuristicBudget limits)
    {
        var meter = new BudgetMeter(limits, default); ProbeContext? probes = null; var actions = new List<ExplorationAction>();
        AnalysisStatus status = AnalysisStatus.Complete; string reason = "FixedChecksComplete";
        try
        {
            var index = new InventoryIndex(snapshot, meter); probes = new(snapshot, meter, default, index, true);
            int visited = 0;
            foreach (var t in snapshot.Targets.Values.Where(t => t.Kind == TargetKind.Directory))
            {
                if (index.Blocked(t)) continue;
                if (visited++ >= limits.MaxTargets) throw new BudgetExceededException("TargetBudget");
                foreach (var action in new[] { ExplorationAction.InspectLayout, ExplorationAction.InspectDuplicates })
                {
                    if (meter.Steps >= limits.MaxActions) throw new BudgetExceededException("ActionBudget");
                    meter.Steps++; actions.Add(action);
                    try { probes.Run(action, t); }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
                    { probes.Fact(t, EvidenceKind.Missing, "ProbeUnavailableOrInventoryChanged"); }
                }
            }
        }
        catch (BudgetExceededException ex) { status = AnalysisStatus.BudgetExhausted; reason = ex.Message; }
        return new(snapshot.TaskId, snapshot.Revision, status, probes?.Evidence ?? [], probes?.Suggestions ?? [], actions, meter.Usage, reason);
    }
    internal static async Task Run(string parentSandbox, Action<bool, string> check)
    {
        const long GiB = 1024L * 1024 * 1024;
        check(AnalysisResources.ChooseLimit(40 * GiB, 16 * GiB) == 4 * GiB, "LargeMachineAllowanceDoesNotRejectAOneGiBMetadataSnapshot");
        check(AnalysisResources.ChooseLimit(8 * GiB, 2 * GiB) == GiB, "ResourceAllowanceRetainsBoundForSmallMachine");
        check(AnalysisResources.ChooseLimit(40 * GiB, GiB / 2) == GiB / 4, "CurrentFreeMemoryConstrainsAllowanceNotOnlyInstalledRam");
        string root = Path.Combine(parentSandbox, "heuristic-" + Guid.NewGuid().ToString("D")); Directory.CreateDirectory(root);
        var scheduler = new HeuristicExplorationScheduler();
        string Case(string name) { string p = Path.Combine(root, name); Directory.CreateDirectory(p); return p; }
        var multi = Case("multiple-evidence-groups");
        Cache(multi, "arbitrary/location-one"); Cache(multi, "unusual/location-two"); Project(multi, "workspace/first"); Project(multi, "workspace/second");
        Text(multi, "readme.pdf", "synthetic private body never read"); Text(multi, "source.cs", "synthetic");
        Text(multi, "unknown/data.txt", "arbitrary contents are not evidence");
        Text(multi, "dist/index.html", "names do not grant authorization");
        var snapshot = Inventory(multi); var sink = new Sink(); var result = await scheduler.ExploreAsync(snapshot, progress: sink);
        check(result.Status == AnalysisStatus.Complete, "HeuristicNoModelNormalComplete");
        check(result.Suggestions.Count(s => s.MayPrepareForReview && s.Classification == Classification.Cache) == 2, "HeuristicAutoDiscoversTwoCustomCaches");
        check(result.Suggestions.Count(s => s.MayPrepareForReview && s.Classification == Classification.BuildArtifact) == 4, "HeuristicAutoDiscoversMultipleProjectOutputs");
        check(result.Suggestions.Any(s => s.TargetId == snapshot.RootId && s.Classification == Classification.Mixed && s.HardProtected), "HeuristicSourceDocsProtectRootNotIndependentOutputs");
        check(result.Suggestions.Any(s => s.Classification == Classification.Unknown && s.Level == SuggestionLevel.Undetermined && s.CandidateFiles.Count == 0 && !s.MayPrepareForReview), "HeuristicUnknownVisibleNotCandidates");
        check(result.Suggestions.All(s => !s.SelectedByDefault), "HeuristicNothingSelectedByDefault");
        check(result.ExecutedActions.All(a => a is ExplorationAction.InspectLayout or ExplorationAction.InspectDuplicates) && result.Usage.Steps == result.ExecutedActions.Count, "HeuristicStepsAreRealProbesNotDecisions");
        check(!result.Evidence.Any(e => e.Kind == EvidenceKind.Ownership), "HeuristicSkipsSidOnlyOwnership");
        var candidates = result.Suggestions.Where(s => s.MayPrepareForReview).SelectMany(s => s.CandidateFiles).ToArray();
        check(candidates.Select(c => c.FileIdentity).Distinct().Count() == candidates.Length && candidates.Select(c => c.ObjectId).Distinct().Count() == candidates.Length, "HeuristicGlobalIdentityAndMemberDedup");
        check(result.Suggestions.All(s => s.EvidenceIds.All(id => result.Evidence.Any(e => e.EvidenceId == id))), "HeuristicEvidenceReferencesResolved");
        check(sink.Values.Count > 5 && sink.Values[^1].CurrentTargetId == null && !sink.Values[^1].HasMore && sink.Values[^1].QueuedTargets == 0, "HeuristicProgressFinishesWithoutMore");
        check(sink.Values.Zip(sink.Values.Skip(1)).All(p => p.First.CompletedActions <= p.Second.CompletedActions && p.First.VisitedTargets <= p.Second.VisitedTargets), "HeuristicProgressMonotonic");
        var selected = snapshot.Targets.Values.Single(t => t.Path.EndsWith(@"workspace\first", StringComparison.Ordinal));
        result = await scheduler.ExploreAsync(snapshot, selected.ObjectId);
        check(result.Suggestions.Count(s => s.MayPrepareForReview) == 2 && result.Suggestions.Where(s => s.MayPrepareForReview).SelectMany(s => s.CandidateFiles).All(f => MetadataAccess.Within(snapshot.Targets[f.ObjectId].Path, selected.Path)), "HeuristicSelectedSubtreeNoSiblingCandidates");
        var protectedSnapshot = new InventoryEvidenceSnapshot(snapshot.TaskId, snapshot.Revision, snapshot.RootId, snapshot.Targets.Values.Select(t => t.ObjectId == snapshot.RootId ? t with { HardProtected = true } : t));
        result = await scheduler.ExploreAsync(protectedSnapshot, selected.ObjectId);
        check(result.Usage.ReadFiles == 0 && result.Usage.HashBytes == 0 && result.Suggestions.All(s => !s.MayPrepareForReview), "HeuristicHardProtectedAncestorSelectedStillDenied");
        var partialSnapshot = new InventoryEvidenceSnapshot(snapshot.TaskId, snapshot.Revision, snapshot.RootId, snapshot.Targets.Values.Select(t => t.ObjectId == selected.ObjectId ? t with { Coverage = Coverage.Partial } : t));
        result = await scheduler.ExploreAsync(partialSnapshot, selected.ObjectId);
        check(result.Usage.ReadFiles == 0 && result.Suggestions.All(s => !s.MayPrepareForReview), "HeuristicPartialCoverageNoReadNoReview");
        var portable = Case("portable-counterexample"); Text(portable, "app.exe", "never execute"); Text(portable, "portable.ini", "never read"); Cache(portable, "sub-cache"); Project(portable, "sub-project");
        result = await scheduler.ExploreAsync(Inventory(portable));
        check(result.Suggestions.Any(s => s.Classification == Classification.Portable) && result.Usage.ReadFiles == 0 && result.Suggestions.All(s => !s.MayPrepareForReview), "HeuristicPortableAncestorStopsGeneratedChildren");
        var privateCache = Case("private-cache-counterexample"); Cache(privateCache, "custom"); Text(privateCache, "custom/holiday.jpg", "synthetic private photo never read");
        result = await scheduler.ExploreAsync(Inventory(privateCache));
        check(result.Suggestions.All(s => !s.MayPrepareForReview) && result.Usage.ReadFiles == 0, "HeuristicPrivateMixedCacheNotAuthorized");
        // Real files, explicitly trusted directory enumeration, and an unrelated coverage gap.
        var isolated = Case("partial-ancestor-isolated-cache"); Cache(isolated, "safe-cache"); Text(isolated, "unrelated/unknown.txt", "never sampled");
        var isolatedFull = Inventory(isolated);
        var isolatedCache = isolatedFull.Targets.Values.Single(t => t.Kind == TargetKind.Directory && Path.GetFileName(t.Path) == "safe-cache");
        InventoryEvidenceSnapshot IsolatedSnapshot(bool? enumeration, bool candidateGap = false, bool hardAncestor = false) => new(
            isolatedFull.TaskId, isolatedFull.Revision, isolatedFull.RootId, isolatedFull.Targets.Values.Select(t =>
                t.ObjectId == isolatedFull.RootId ? t with { Coverage = Coverage.Partial, DirectoryEnumerationComplete = enumeration, HardProtected = hardAncestor }
                : Path.GetFileName(t.Path) == "unrelated" ? t with { Coverage = Coverage.Partial, DirectoryEnumerationComplete = true }
                : candidateGap && t.ParentId == isolatedCache.ObjectId && Path.GetFileName(t.Path) == "data_0" ? t with { Coverage = Coverage.Partial }
                : t));
        result = await scheduler.ExploreAsync(IsolatedSnapshot(true));
        check(result.Suggestions.Count(s => s.MayPrepareForReview && s.TargetId == isolatedCache.ObjectId) == 1
            && result.Suggestions.All(s => !s.MayPrepareForReview || s.TargetId != isolatedFull.RootId) && result.Usage.ReadFiles == 1,
            "HeuristicExplicitPartialAncestorAllowsOnlyCompleteSiblingCache");
        var partialCandidate = IsolatedSnapshot(true);
        partialCandidate = new(partialCandidate.TaskId, partialCandidate.Revision, partialCandidate.RootId, partialCandidate.Targets.Values.Select(t =>
            t.ObjectId == isolatedCache.ObjectId ? t with { Coverage = Coverage.Partial, DirectoryEnumerationComplete = true } : t));
        foreach (var denied in new[] { IsolatedSnapshot(null), IsolatedSnapshot(true, candidateGap: true), IsolatedSnapshot(true, hardAncestor: true), partialCandidate })
        {
            result = await scheduler.ExploreAsync(denied, isolatedCache.ObjectId);
            check(result.Usage.ReadFiles == 0 && result.Usage.HashBytes == 0 && result.Suggestions.All(s => !s.MayPrepareForReview),
                "HeuristicLegacyPartialCandidateGapOrHardAncestorStillDenied");
        }
        var partialPortable = Inventory(portable);
        partialPortable = new(partialPortable.TaskId, partialPortable.Revision, partialPortable.RootId, partialPortable.Targets.Values.Select(t =>
            t.ObjectId == partialPortable.RootId ? t with { Coverage = Coverage.Partial, DirectoryEnumerationComplete = true } : t));
        result = await scheduler.ExploreAsync(partialPortable);
        check(result.Usage.ReadFiles == 0 && result.Suggestions.All(s => !s.MayPrepareForReview), "HeuristicPartialTrueDoesNotBypassPortableAncestor");
        var privateAncestor = Case("partial-private-ancestor"); Cache(privateAncestor, "personal-backup/safe-cache");
        var privateAncestorSnapshot = Inventory(privateAncestor);
        privateAncestorSnapshot = new(privateAncestorSnapshot.TaskId, privateAncestorSnapshot.Revision, privateAncestorSnapshot.RootId,
            privateAncestorSnapshot.Targets.Values.Select(t => t.Kind == TargetKind.Directory && Path.GetFileName(t.Path) == "personal-backup"
                ? t with { Coverage = Coverage.Partial, DirectoryEnumerationComplete = true } : t));
        result = await scheduler.ExploreAsync(privateAncestorSnapshot);
        check(result.Usage.ReadFiles == 0 && result.Suggestions.All(s => !s.MayPrepareForReview), "HeuristicPartialTrueDoesNotBypassPrivateAncestor");
        var copied = Case("cross-branch-package-display"); byte[] zip = [0x50, 0x4b, 3, 4, 1, 2, 3, 4];
        Directory.CreateDirectory(Path.Combine(copied, "a")); Directory.CreateDirectory(Path.Combine(copied, "b")); File.WriteAllBytes(Path.Combine(copied, "a/one.zip"), zip); File.WriteAllBytes(Path.Combine(copied, "b/two.zip"), zip);
        result = await scheduler.ExploreAsync(Inventory(copied));
        check(result.Suggestions.Count(s => s.Duplicate != null) == 1 && result.Suggestions.Where(s => s.Duplicate != null).All(s => s.HardProtected && s.Level == SuggestionLevel.OrganizeOpportunity && !s.MayPrepareForReview), "HeuristicCrossBranchZipOrganizeOnly");
        check(result.Usage.HashBytes == 16 && result.Usage.HashFiles == 2, "HeuristicFullHashesRealBudget");
        var large = Case("large-metadata-only"); Project(large, "project"); File.WriteAllBytes(Path.Combine(large, "one.zip"), zip); File.WriteAllBytes(Path.Combine(large, "two.zip"), zip);
        result = await scheduler.ExploreAsync(Inventory(large), budget: new(LargeFileBytes: 4));
        check(result.Usage.ReadFiles == 0 && result.Usage.HashBytes == 0 && result.Suggestions.All(s => !s.MayPrepareForReview), "HeuristicObservedLargeFilesMetadataOnly");
        var linked = Case("hardlink-generated-protection"); Project(linked, "project");
        string existing = Path.Combine(linked, "project/bin/app.dll"), alias = Path.Combine(linked, "project/bin/alias.dll");
        check(CreateHardLink(alias, existing, IntPtr.Zero), "HeuristicHardlinkFixtureCreated");
        result = await scheduler.ExploreAsync(Inventory(linked));
        check(!result.Suggestions.Any(s => s.MayPrepareForReview && s.CandidateFiles.Any(c => c.FileIdentity == MetadataAccess.Capture("alias", null, alias).FileIdentity)), "HeuristicHardlinkNoReview");
        result = await scheduler.ExploreAsync(snapshot, budget: new(MaxMetadataObjects: 1));
        check(result.Status == AnalysisStatus.BudgetExhausted && result.Usage.MetadataObjects == 1 && result.Usage.Steps == 0 && result.Suggestions.Count == 0, "HeuristicIndexConstructionChargedFailClosed");
        result = await scheduler.ExploreAsync(snapshot, budget: new(MaxActions: 1));
        check(result.Status == AnalysisStatus.BudgetExhausted && result.Usage.Steps == 1 && result.ExecutedActions.Count == 1, "HeuristicActionBudgetRealProbes");
        result = await scheduler.ExploreAsync(snapshot, budget: new(MaxTargets: 1));
        check(result.Status == AnalysisStatus.BudgetExhausted && result.Usage.Steps == 1, "HeuristicTargetBudget");
        var completion = await scheduler.ExploreAsync(snapshot, budget: new(MaxTargets: 1, MaxActions: 1, MaxMetadataObjects: 1, MaxDuration: TimeSpan.FromTicks(1), UntilComplete: true));
        check(completion.Status == AnalysisStatus.Complete && completion.Usage.Steps > 1 && completion.Usage.MetadataObjects > 1, "CompletionModeDoesNotTerminateOnPerRunCountOrDuration");
        using (var completionCancel = new CancellationTokenSource())
        {
            completionCancel.Cancel();
            var cancelledCompletion = await scheduler.ExploreAsync(snapshot, budget: new(UntilComplete: true), cancellationToken: completionCancel.Token);
            check(cancelledCompletion.Status == AnalysisStatus.Cancelled && cancelledCompletion.Usage.Steps == 0, "CompletionModeRetainsExplicitCancellation");
        }
        result = await scheduler.ExploreAsync(snapshot, budget: new(MaxDuration: TimeSpan.FromTicks(1)));
        check(result.Status == AnalysisStatus.BudgetExhausted && result.Reason == "DurationBudget" && result.Usage.Steps == 0, "HeuristicDurationIncludesIndexConstruction");
        using (var cancel = new CancellationTokenSource())
        {
            cancel.Cancel(); result = await scheduler.ExploreAsync(snapshot, cancellationToken: cancel.Token);
            check(result.Status == AnalysisStatus.Cancelled && result.Usage.Steps == 0 && result.Usage.ReadFiles == 0, "HeuristicPreCancellationNoProbe");
        }
        using (var cancel = new CancellationTokenSource())
        {
            var cancelling = new Sink(p => { if (p.CompletedActions == 1) cancel.Cancel(); });
            result = await scheduler.ExploreAsync(snapshot, progress: cancelling, cancellationToken: cancel.Token);
            check(result.Status == AnalysisStatus.Cancelled && result.Usage.Steps == 1, "HeuristicMidSearchCancellation");
        }
        var fair = Case("unknown-fairness"); for (int i = 0; i < 8; i++) Cache(fair, "cache-" + i); Text(fair, "unknown-branch/data.txt", "no classification clues");
        sink = new(); result = await scheduler.ExploreAsync(Inventory(fair), budget: new(MaxActions: 4), progress: sink);
        check(result.Status == AnalysisStatus.BudgetExhausted && sink.Values.Any(p => p.Reason == "UnknownFairExploration" && p.CompletedActions == 3), "HeuristicReservesUnknownFourthSlot");
        var wide = Case("wide-adjacency"); for (int i = 0; i < 140; i++) Text(wide, "branch-" + i + "/unknown.txt", "synthetic unknown");
        var wideSnapshot = Inventory(wide); result = await scheduler.ExploreAsync(wideSnapshot, budget: new(MaxTargets: 200));
        check(result.Status == AnalysisStatus.Complete && result.Usage.MetadataObjects < 10000 && result.Usage.MetadataObjects >= wideSnapshot.Targets.Count, "HeuristicWideTreeNoPerTargetFullInventoryScan");
        var deep = Case("deep-adjacency"); string path = deep; for (int i = 0; i < 40; i++) path = Path.Combine(path, "d"); Directory.CreateDirectory(path); Text(path, "unknown.txt", "synthetic");
        result = await scheduler.ExploreAsync(Inventory(deep));
        check(result.Status == AnalysisStatus.Complete && result.Usage.Steps == 41, "HeuristicDeepTreeFiniteTraversal");
        var unknown = Case("nothing-useful"); Text(unknown, "unknown.txt", "not read"); result = await scheduler.ExploreAsync(Inventory(unknown));
        check(result.Status == AnalysisStatus.Complete && result.Usage.ReadFiles == 0 && result.Usage.Steps == 1 && result.Reason == "NoUsefulChecksRemaining", "HeuristicNoUsefulChecksNormalComplete");
        var changed = Case("changed-generated-member"); Project(changed, "project"); var stale = Inventory(changed); Text(changed, "project/bin/app.dll", "changed synthetic generated"); result = await scheduler.ExploreAsync(stale);
        check(result.Suggestions.Where(s => s.MayPrepareForReview).SelectMany(s => s.CandidateFiles).All(c => !stale.Targets[c.ObjectId].Path.EndsWith(@"bin\app.dll")), "HeuristicChangedMemberRejected");
        var appeared = Case("new-private-output-member"); Project(appeared, "project"); var beforeNewFile = Inventory(appeared); Text(appeared, "project/bin/new-private.docx", "synthetic private never read");
        result = await scheduler.ExploreAsync(beforeNewFile);
        check(!result.Suggestions.Any(s => s.MayPrepareForReview && beforeNewFile.Targets[s.TargetId].Path.EndsWith(@"project\bin")), "HeuristicNewUnobservedOutputMemberRejectsEntireSet");
        var newLink = Case("new-hardlink-after-inventory"); Project(newLink, "project"); var beforeNewLink = Inventory(newLink);
        string newLinkExisting = Path.Combine(newLink, "project/bin/app.dll"), newLinkAlias = Path.Combine(newLink, "outside-alias.dll");
        check(CreateHardLink(newLinkAlias, newLinkExisting, IntPtr.Zero), "HeuristicNewHardlinkRaceFixtureCreated"); result = await scheduler.ExploreAsync(beforeNewLink);
        check(!result.Suggestions.Any(s => s.MayPrepareForReview && s.CandidateFiles.Any(c => beforeNewLink.Targets[c.ObjectId].Path == newLinkExisting)), "HeuristicChangedLinkCountRejected");
        // This pair differs only in probe evidence. A proven exact output removes later work;
        // an output counterexample leaves its layout probe scheduled. This is bounded adaptive
        // pruning, not a claim of unrestricted/model-equivalent exploration.
        var adaptive = Case("adaptive-evidence-pair"); Project(adaptive, "project"); var adaptiveSnapshot = Inventory(adaptive);
        var positiveProgress = new Sink(); var positive = await scheduler.ExploreAsync(adaptiveSnapshot, progress: positiveProgress);
        Text(adaptive, "project/bin/handwritten.cs", "synthetic source counterexample");
        var negativeProgress = new Sink(); var negative = await scheduler.ExploreAsync(Inventory(adaptive), progress: negativeProgress);
        check(positiveProgress.Values.Count(p => p.Reason == "ExactSetEvidenceSkipsRedundantLayout") == 2 && negativeProgress.Values.Count(p => p.Reason == "ExactSetEvidenceSkipsRedundantLayout") == 1 && negative.Usage.Steps == positive.Usage.Steps + 1, "HeuristicProbeEvidenceChangesActualNextProbeSet");
        var protectedForest = Case("protected-forest-does-not-starve-clues");
        for (int i = 0; i < 180; i++) Text(protectedForest, "protected-" + i + "/private.docx", "synthetic never read");
        Cache(protectedForest, "trusted-custom-location"); var forest = Inventory(protectedForest);
        forest = new(forest.TaskId, forest.Revision, forest.RootId, forest.Targets.Values.Select(t => t.ParentId == forest.RootId && t.Kind == TargetKind.Directory && Path.GetFileName(t.Path).StartsWith("protected-", StringComparison.Ordinal) ? t with { HardProtected = true } : t));
        result = await scheduler.ExploreAsync(forest, budget: new(MaxTargets: 2));
        check(result.Status == AnalysisStatus.Complete && result.Suggestions.Count(s => s.MayPrepareForReview && s.Classification == Classification.Cache) == 1 && result.Usage.Steps == 2 && result.Suggestions.Count(s => s.HardProtected) <= 129 && result.Evidence.Any(e => e.Value.Contains("ObservedBranches=180;ObservedFiles=180;ObservedDirectories=180;DisplayedGroups=128;OmittedDisplayGroups=52;OmittedDisplayBranches=52;NotCoveredInventoryObjects=0", StringComparison.Ordinal)), "HeuristicKnownProtectionDoesNotSpendTargetSlots");
        var privateFlood = Case("private-direct-file-display-flood");
        for (int i = 0; i < 10025; i++) Text(privateFlood, "personal-" + i + ".docx", "synthetic private never read");
        Cache(privateFlood, "trusted-custom-cache"); var floodSnapshot = Inventory(privateFlood);
        result = await scheduler.ExploreAsync(floodSnapshot);
        check(result.Status == AnalysisStatus.Complete && result.Suggestions.Count <= 3 && result.Suggestions.Count(s => s.MayPrepareForReview && s.Classification == Classification.Cache) == 1 && result.Usage.ReadFiles == 1 && result.Usage.HashBytes == 0, "HeuristicTenThousandPrivateFilesAggregatedBelowApplicationLimit");
        check(result.Evidence.Any(e => e.TargetId == floodSnapshot.RootId && e.Value.Contains("ObservedBranches=10025;ObservedFiles=10025;ObservedDirectories=0;DisplayedGroups=1;OmittedDisplayGroups=0;OmittedDisplayBranches=0;NotCoveredInventoryObjects=0", StringComparison.Ordinal)) && result.Suggestions.All(s => s.EvidenceIds.All(id => result.Evidence.Any(e => e.EvidenceId == id))), "HeuristicProtectionAggregateCountsAreExactAndBound");
        var spaceFlood = Case("space-display-flood");
        for (int i = 0; i < 160; i++) Text(spaceFlood, "observed-" + i + ".bin", "synthetic large by test threshold");
        result = await scheduler.ExploreAsync(Inventory(spaceFlood), budget: new(MaxTargets: 200, LargeFileBytes: 1));
        check(result.Status == AnalysisStatus.BudgetExhausted && result.Reason == "SuggestionDisplayBudget" && result.Suggestions.Count(s => s.Classification == Classification.SpaceOnly) == 128 && result.Evidence.Any(e => e.Value == "SuggestionDisplayLimit;OmittedSuggestions=32;NotCoveredForDisplayOnly;NoAuthorization") && result.Usage.ReadFiles == 0, "HeuristicSpaceDisplayOmissionExplicitAndBounded");
        // A scale test of the budget/index path: only the real root is ever probed; metadata-only
        // unmaterialized inventory members are never opened or presented as verified candidates.
        var scale = Case("maximum-inventory-index"); var capturedRoot = MetadataAccess.Capture("scale-root", null, scale);
        var scaleTargets = new List<InventoryTarget>(250000) { capturedRoot };
        for (int i = 1; i < 250000; i++) scaleTargets.Add(new("scale-" + i, capturedRoot.ObjectId, Path.Combine(scale, "metadata-" + i + ".txt"), TargetKind.File, "synthetic-scale-id-" + i, 1, 1, 0, 1, Coverage.Complete));
        var scaleSnapshot = new InventoryEvidenceSnapshot(Guid.NewGuid().ToString("D"), 1, capturedRoot.ObjectId, scaleTargets);
        result = await scheduler.ExploreAsync(scaleSnapshot);
        check(result.Status == AnalysisStatus.BudgetExhausted && result.Usage.Steps > 0 && result.Usage.MetadataObjects <= 250000 && result.Suggestions.All(s => !s.MayPrepareForReview), "HeuristicMaximumInventoryReservesActualProbeBudget");
        check(result.Reason == "PartialIndexMetadataBudget" && result.Usage.Steps == 1 && result.ExecutedActions.SequenceEqual(new[] { ExplorationAction.InspectLayout })
            && result.Usage.ReadFiles == 0 && result.Usage.SampleBytes == 0 && result.Usage.HashFiles == 0 && result.Usage.HashBytes == 0
            && result.Evidence.Any(e => e.TargetId == capturedRoot.ObjectId && e.Value.StartsWith("IncompleteDirectIndexMetadataOnly;", StringComparison.Ordinal)
                && e.Value.Contains("ExpectedDirectObjects=249999;", StringComparison.Ordinal)), "HeuristicMaximumInventoryRunsGuardedGapDiagnosticWithoutMemberReads");
        var hardScaleSnapshot = new InventoryEvidenceSnapshot(scaleSnapshot.TaskId, scaleSnapshot.Revision, scaleSnapshot.RootId,
            scaleSnapshot.Targets.Values.Select(t => t.ObjectId == scaleSnapshot.RootId ? t with { HardProtected = true } : t));
        var hardScaleResult = await scheduler.ExploreAsync(hardScaleSnapshot);
        check(hardScaleResult.Status == AnalysisStatus.BudgetExhausted && hardScaleResult.Usage.Steps == 0 && hardScaleResult.Usage.ReadFiles == 0
            && hardScaleResult.Usage.HashBytes == 0 && !hardScaleResult.Evidence.Any(e => e.Value.StartsWith("IncompleteDirectIndexMetadataOnly;", StringComparison.Ordinal))
            && hardScaleResult.Suggestions.All(s => !s.MayPrepareForReview), "HeuristicIncompleteIndexDoesNotProbeHardProtectedRoot");
        // Same real candidate, with index truncation confined to an unrelated sibling's descendants.
        // Put every ancestor/direct sibling and the whole candidate ahead of the synthetic tail.
        var localRoot = isolatedFull.Targets[isolatedFull.RootId];
        var localSibling = isolatedFull.Targets.Values.Single(t => t.Kind == TargetKind.Directory && Path.GetFileName(t.Path) == "unrelated");
        var localMembers = isolatedFull.Targets.Values.Where(t => t.ParentId == isolatedCache.ObjectId).ToArray();
        var localTail = isolatedFull.Targets.Values.Where(t => t.ParentId == localSibling.ObjectId).ToList();
        for (int i = 0; i < 1100; i++) localTail.Add(new("local-gap-" + i, localSibling.ObjectId, Path.Combine(localSibling.Path, "metadata-" + i + ".txt"),
            TargetKind.File, "synthetic-local-gap-" + i, 1, 1, 0, 1, Coverage.Complete));
        var localCompleteFirst = new[] { localRoot, isolatedCache, localSibling }.Concat(localMembers).Concat(localTail).ToArray();
        var localSnapshot = new InventoryEvidenceSnapshot(Guid.NewGuid().ToString("D"), 1, localRoot.ObjectId, localCompleteFirst);
        result = await scheduler.ExploreAsync(localSnapshot, budget: new(MaxMetadataObjects: 1024));
        check(result.Status == AnalysisStatus.BudgetExhausted && result.Reason == "PartialIndexMetadataBudget" && result.Usage.MetadataObjects <= 1024
            && result.Usage.Steps > 0 && result.Usage.ReadFiles == 1 && result.Usage.HashBytes == 0
            && result.Suggestions.Count(s => s.MayPrepareForReview && s.TargetId == isolatedCache.ObjectId) == 1
            && result.Suggestions.Where(s => s.MayPrepareForReview).SelectMany(s => s.CandidateFiles).All(f => localMembers.Any(t => t.ObjectId == f.ObjectId)),
            "HeuristicPartialIndexPreservesActualProbeForCompleteSiblingSubtree");
        var localCandidateOmitted = new InventoryEvidenceSnapshot(localSnapshot.TaskId, localSnapshot.Revision, localSnapshot.RootId,
            new[] { localRoot, isolatedCache, localSibling }.Concat(localTail).Concat(localMembers));
        result = await scheduler.ExploreAsync(localCandidateOmitted, budget: new(MaxMetadataObjects: 1024));
        check(result.Status == AnalysisStatus.BudgetExhausted && result.Reason == "PartialIndexMetadataBudget" && result.Usage.ReadFiles == 0
            && result.Usage.HashBytes == 0 && result.Suggestions.All(s => !s.MayPrepareForReview), "HeuristicPartialIndexCandidateDirectGapStillDenied");
        // Same frozen inventory, same probes/safety/budgets, hashes enabled in both modes.
        var frozen = Case("same-tool-fixed-order-control");
        for (int i = 0; i < 12; i++) Text(frozen, "a-unknown-" + i + "/unknown.txt", "synthetic unknown");
        Cache(frozen, "z/groups/cache-one"); Cache(frozen, "z/groups/cache-two"); Project(frozen, "z/projects/first"); Project(frozen, "z/projects/second");
        Directory.CreateDirectory(Path.Combine(frozen, "archives/first")); Directory.CreateDirectory(Path.Combine(frozen, "archives/second"));
        File.WriteAllBytes(Path.Combine(frozen, "archives/first/a.zip"), zip); File.WriteAllBytes(Path.Combine(frozen, "archives/second/b.zip"), zip);
        var frozenSnapshot = Inventory(frozen); var equalLimits = new HeuristicBudget(MaxActions: 8);
        var fixedBounded = FixedOrder(frozenSnapshot, equalLimits); var heuristicBounded = await scheduler.ExploreAsync(frozenSnapshot, budget: equalLimits);
        check(heuristicBounded.Suggestions.Count(s => s.MayPrepareForReview) > fixedBounded.Suggestions.Count(s => s.MayPrepareForReview), "HeuristicSameProbeBudgetPrioritizesNestedEvidenceOverUnknowns");
        var fixedFull = FixedOrder(frozenSnapshot, new()); var heuristicFull = await scheduler.ExploreAsync(frozenSnapshot);
        check(fixedFull.Status == AnalysisStatus.Complete && heuristicFull.Status == AnalysisStatus.Complete && fixedFull.Usage.HashBytes == 16 && heuristicFull.Usage.HashBytes == 16, "HeuristicFixedOrderControlHashesNotDisabled");
        var fixedMembers = fixedFull.Suggestions.Where(s => s.MayPrepareForReview).SelectMany(s => s.CandidateFiles).Select(f => f.ObjectId).ToHashSet(StringComparer.Ordinal);
        var heuristicMembers = heuristicFull.Suggestions.Where(s => s.MayPrepareForReview).SelectMany(s => s.CandidateFiles).Select(f => f.ObjectId).ToHashSet(StringComparer.Ordinal);
        check(fixedMembers.SetEquals(heuristicMembers) && heuristicFull.Suggestions.Count(s => s.MayPrepareForReview) == 6 && heuristicFull.Suggestions.Count(s => s.Duplicate != null) == 1 && heuristicFull.Usage.Steps < fixedFull.Usage.Steps, "HeuristicFullControlSameExactProofLessRedundantActions");
        Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { Comparison = "same-frozen-tree-same-probes", BoundedFixed = new { fixedBounded.Usage, ReviewGroups = fixedBounded.Suggestions.Count(s => s.MayPrepareForReview) }, BoundedHeuristic = new { heuristicBounded.Usage, ReviewGroups = heuristicBounded.Suggestions.Count(s => s.MayPrepareForReview) }, FullFixed = new { fixedFull.Usage, ReviewGroups = fixedFull.Suggestions.Count(s => s.MayPrepareForReview) }, FullHeuristic = new { heuristicFull.Usage, ReviewGroups = heuristicFull.Suggestions.Count(s => s.MayPrepareForReview) }, MaximumInventory = new { result.Status, result.Reason, result.Usage } }));
        check(File.Exists(Path.Combine(multi, "readme.pdf")) && File.Exists(existing) && File.Exists(alias), "HeuristicFixturesNeverDeleted");
    }
}
