using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using SafeJunkCleaner.Explorer.Analysis;

internal static class Program
{
    private static int assertions;
    private static string caseName = "Preflight";
    private static readonly List<string> caseNames = [];
    private static readonly List<object> checks = [];

    private static void Begin(string name) { caseName = name; caseNames.Add(name); }
    private static void Assert(bool ok, string name)
    {
        if (!ok) throw new Exception($"ASSERT FAILED [{caseName}] {name}");
        assertions++; checks.Add(new { Case = caseName, Name = name, Passed = true });
    }

    private sealed class Scripted(params ExplorationAction[] actions) : IExplorationDecider
    {
        private int index;
        public ValueTask<ExplorationDecision> DecideAsync(AnalysisState state, CancellationToken token)
            => ValueTask.FromResult(new ExplorationDecision(true, index < actions.Length ? actions[index++] : ExplorationAction.Stop, state.TargetId));
    }

    // Claims an available model decision that names a chosen classification; the engine must keep deterministic protection.
    private sealed class Claiming(string targetId, Classification classification) : IExplorationDecider
    {
        private readonly string targetId = targetId;
        private readonly Classification classification = classification;
        private int calls;
        public List<AnalysisState> States { get; } = [];
        public ValueTask<ExplorationDecision> DecideAsync(AnalysisState state, CancellationToken token)
        {
            States.Add(state); calls++;
            return calls == 1
                ? ValueTask.FromResult(new ExplorationDecision(true, ExplorationAction.InspectLayout, targetId, classification))
                : ValueTask.FromResult(new ExplorationDecision(true, ExplorationAction.Stop, state.TargetId));
        }
    }

    private static InventoryEvidenceSnapshot Inventory(string root)
    {
        var list = new List<InventoryTarget>(); int i = 0;
        void Add(string p, string? parent)
        {
            string id = "object-" + i++; list.Add(MetadataAccess.Capture(id, parent, p));
            if (Directory.Exists(p)) foreach (var child in Directory.EnumerateFileSystemEntries(p).OrderBy(p => p, StringComparer.Ordinal)) Add(child, id);
        }
        Add(root, null); return new(Guid.NewGuid().ToString("D"), 1, list[0].ObjectId, list);
    }

    private static void Text(string root, string path, string text) { var p = Path.Combine(root, path); Directory.CreateDirectory(Path.GetDirectoryName(p)!); File.WriteAllText(p, text); }

    private static async Task<AnalysisResult> Run(InventoryEvidenceSnapshot snapshot, IExplorationDecider? decider = null)
        => await new BoundedExplorationScheduler().AnalyzeAsync(snapshot, snapshot.RootId, decider ?? new UnavailableDecider());

    private static void MakeJunction(string link, string target)
    {
        var psi = new ProcessStartInfo("cmd.exe") { UseShellExecute = false, CreateNoWindow = true };
        psi.ArgumentList.Add("/c"); psi.ArgumentList.Add("mklink"); psi.ArgumentList.Add("/J"); psi.ArgumentList.Add(link); psi.ArgumentList.Add(target);
        using var p = Process.Start(psi)!; p.WaitForExit();
        if (p.ExitCode != 0 || !Directory.Exists(link)) throw new Exception("Junction creation failed");
    }

    private static Dictionary<string, string> HashFrozen(string baseDir)
    {
        var manifest = Path.GetFullPath(baseDir);
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!File.Exists(manifest)) throw new FileNotFoundException("CallerBuildManifestRequired", manifest);
        using var doc = JsonDocument.Parse(File.ReadAllText(manifest));
        foreach (var e in doc.RootElement.EnumerateArray())
        {
            var path = e.GetProperty("Path").GetString()!; var expected = e.GetProperty("Hash").GetString()!;
            var actual = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
            if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase)) throw new Exception("Frozen source hash mismatch: " + path);
            result[path] = actual;
        }
        return result;
    }

    public static async Task<int> Main(string[] args)
    {
        var baseDir = args[0];
        var evidence = Path.Combine(baseDir, "verification-analysis-" + Guid.NewGuid().ToString("D"));
        Directory.CreateDirectory(evidence);
        var sandbox = TestEvidence.CreateFixture(args[0], "analysis-regression-fixture");
        Directory.CreateDirectory(sandbox);
        File.WriteAllText(Path.Combine(sandbox, ".sandbox-owner"), WindowsIdentity.GetCurrent().User!.Value + "|" + sandbox);
        string? junctionToRemove = null;
        string Case(string name) { var p = Path.Combine(sandbox, name); Directory.CreateDirectory(p); return p; }
        try
        {
            var frozenBefore = HashFrozen(args[1]);
            Assert(frozenBefore.Count > 0 && frozenBefore.ContainsKey(typeof(BoundedExplorationScheduler).Assembly.Location), "CallerBuildManifestIncludesAnalysisAssembly");
            var analysisSha = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(typeof(BoundedExplorationScheduler).Assembly.Location)));
            Assert(analysisSha == frozenBefore[typeof(BoundedExplorationScheduler).Assembly.Location], "AnalysisAssemblyMatchesCallerBuildManifest");

            const string projectXml = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>";

            // A. Model output cannot inject evidence, classifications or targets outside the scheduler's allowed set.
            Begin("A1-ModelClaimCannotMaterializeOrUnprotect");
            var root = Case("inject-claim");
            Text(root, "private.docx", "synthetic private body never read");
            var snap = Inventory(root);
            var docx = snap.Targets.Values.First(t => t.Path.EndsWith("private.docx", StringComparison.OrdinalIgnoreCase));
            var claim = new Claiming(docx.ObjectId, Classification.BuildArtifact);
            var result = await new BoundedExplorationScheduler().AnalyzeAsync(snap, snap.RootId, claim);
            Assert(!result.Suggestions.Any(s => s.Classification == Classification.BuildArtifact), "ClaimedBuildArtifactNotCreated");
            Assert(result.Suggestions.All(s => s.HardProtected && !s.MayPrepareForReview), "ModelCannotUnprotectOrPrepare");
            Assert(result.Suggestions.Any(s => s.TargetId == snap.RootId && s.Classification == Classification.Mixed && s.HardProtected), "ProtectedDirectorySummaryStillPresent");
            Assert(result.Reason == "ProgramPolicyProtectedStop_NotModelDecision" && claim.States.Count == 0, "ProtectedDirectoryStopsBeforeDecider");
            var direct = await new BoundedExplorationScheduler().AnalyzeAsync(snap, docx.ObjectId, claim);
            Assert(direct.Suggestions.Any(s => s.TargetId == docx.ObjectId && s.Classification == Classification.UserData && s.HardProtected && !s.MayPrepareForReview), "DirectProtectedFileStillShowsUserData");
            Assert(direct.Usage.ReadFiles == 0 && direct.Suggestions.All(s => s.CandidateFiles.Count == 0), "DirectProtectedFileHasNoReadOrCandidates");
            Assert(result.Suggestions.All(s => s.CandidateFiles.Count == 0), "NoCandidateFilesFromInjectedClaim");
            Assert(result.Usage.ReadFiles == 0 && result.Usage.SampleBytes == 0, "PrivateDocumentBodyNeverSampled");
            Assert(claim.States.All(s => s.Evidence.All(e => !e.Value.Contains("private.docx", StringComparison.OrdinalIgnoreCase))), "DecisionStateExposesNoFileName");

            Begin("A2-DeciderTargetOutsideAllowedSetRejected");
            var decisionRoot = Case("decision-target");
            Text(decisionRoot, "a/deep.txt", "x"); Text(decisionRoot, "b/shallow.txt", "x");
            var decisionSnap = Inventory(decisionRoot);
            var deep = decisionSnap.Targets.Values.First(t => t.Path.EndsWith("deep.txt", StringComparison.OrdinalIgnoreCase));
            var forged = new Claiming(deep.ObjectId, Classification.Mixed);
            result = await new BoundedExplorationScheduler().AnalyzeAsync(decisionSnap, decisionSnap.RootId, forged);
            Assert(result.Status == AnalysisStatus.InvalidDecision, "GrandchildTargetNotInDecisionSetRejected");
            Assert(result.Suggestions.Count == 0 && result.Usage.HashBytes == 0, "NoSuggestionsOrHashingFromForgedTarget");

            Begin("A3-DeciderClassificationOutsideEnumRejected");
            var bogusClass = new Claiming(decisionSnap.RootId, (Classification)999);
            result = await new BoundedExplorationScheduler().AnalyzeAsync(decisionSnap, decisionSnap.RootId, bogusClass);
            Assert(result.Status == AnalysisStatus.InvalidDecision, "UndefinedClassificationRejected");
            Assert(result.Suggestions.Count == 0 && result.Usage.HashBytes == 0, "NoEffectsFromUndefinedClassification");

            // B. A snapshot path may look in-scope while its physical target escapes the root through a junction.
            Begin("B1-JunctionEscapeCannotBecomeBuildCandidate");
            var junctionRoot = Case("junction-root");
            Text(junctionRoot, "app.csproj", projectXml);
            var external = Path.Combine(sandbox, "junction-target-" + Guid.NewGuid().ToString("D"));
            Directory.CreateDirectory(external);
            File.WriteAllText(Path.Combine(external, "app.dll"), "synthetic external assembly");
            File.WriteAllText(Path.Combine(external, "app.deps.json"), "{}");
            var binPath = Path.Combine(junctionRoot, "bin");
            MakeJunction(binPath, external); junctionToRemove = binPath;
            var rootT = MetadataAccess.Capture("j-root", null, junctionRoot);
            var binT = MetadataAccess.Capture("j-bin", rootT.ObjectId, binPath);
            var dllT = MetadataAccess.Capture("j-dll", binT.ObjectId, Path.Combine(binPath, "app.dll"));
            var depsT = MetadataAccess.Capture("j-deps", binT.ObjectId, Path.Combine(binPath, "app.deps.json"));
            var csprojT = MetadataAccess.Capture("j-csproj", rootT.ObjectId, Path.Combine(junctionRoot, "app.csproj"));
            var junctionSnap = new InventoryEvidenceSnapshot(Guid.NewGuid().ToString("D"), 1, rootT.ObjectId, [rootT, binT, dllT, depsT, csprojT]);
            Assert(MetadataAccess.Within(binT.Path, rootT.Path) && !MetadataAccess.Within(external, rootT.Path), "SnapshotPathInScopeWhilePhysicalTargetOutside");
            var scheduler = new BoundedExplorationScheduler();
            result = await scheduler.AnalyzeAsync(junctionSnap, junctionSnap.RootId, new UnavailableDecider());
            Assert(result.Status == AnalysisStatus.ModelUnavailable && result.Reason == "DeciderUnavailableFactsOnly", "UnsafeOutputRemainsFactsOnly");
            Assert(result.Suggestions.Any(s => s.TargetId == binT.ObjectId && s.Classification == Classification.Mixed && s.HardProtected), "JunctionOutputExplicitlyProtected");
            Assert(result.Usage.ReadFiles == 1 && result.Usage.HashBytes == 0, "OnlyInScopeProjectMarkerReadNotJunctionContents");
            Assert(!result.Suggestions.Any(s => s.Classification == Classification.BuildArtifact), "NoBuildArtifactAcrossJunction");
            Assert(result.Suggestions.All(s => s.CandidateFiles.Count == 0), "NoExternalFileAsCandidate");
            Assert(!result.Suggestions.Any(s => s.MayPrepareForReview), "NothingAcrossJunctionPreparable");
            Assert(result.Evidence.Any(e => e.TargetId == binT.ObjectId && e.Kind == EvidenceKind.Protection && e.Value == "SourceOrPrivateOrPartialInOutput"), "ProtectionEvidenceRecordedForEscape");
            bool absentRejected = false;
            try { await scheduler.AnalyzeAsync(junctionSnap, "object-not-in-snapshot", new UnavailableDecider()); }
            catch (ArgumentException) { absentRejected = true; }
            Assert(absentRejected, "TargetIdOutsideSnapshotRejected");

            // C. Source inside an output directory must invalidate the whole candidate set, even under a valid project marker.
            Begin("C1-SourceInsideBinInvalidatesOutputSet");
            var sourceRoot = Case("source-in-bin");
            Text(sourceRoot, "app.csproj", projectXml);
            Text(sourceRoot, "bin/app.dll", "synthetic assembly");
            Text(sourceRoot, "bin/app.deps.json", "{}");
            Text(sourceRoot, "bin/nested/Handwritten.cs", "synthetic source never execute");
            var sourceSnap = Inventory(sourceRoot);
            var binId = sourceSnap.Targets.Values.First(t => Path.GetFileName(t.Path) == "bin").ObjectId;
            var sourceId = sourceSnap.Targets.Values.First(t => t.Path.EndsWith("Handwritten.cs", StringComparison.OrdinalIgnoreCase)).ObjectId;
            result = await Run(sourceSnap);
            Assert(result.Suggestions.Count == 1 && result.Suggestions[0].TargetId == binId, "SingleMixedOutputSuggestion");
            Assert(result.Suggestions[0].Classification == Classification.Mixed, "SourceMakesOutputMixedNotBuildArtifact");
            Assert(result.Suggestions[0].HardProtected && !result.Suggestions[0].MayPrepareForReview, "MixedOutputNotReviewable");
            Assert(result.Suggestions[0].CandidateFiles.Count == 0, "CandidateSetEmptyWhenSourcePresent");
            Assert(result.Suggestions.All(s => s.Classification != Classification.BuildArtifact), "NoBuildArtifactSuggestionForBin");
            Assert(result.Suggestions.SelectMany(s => s.CandidateFiles).All(f => f.ObjectId != sourceId), "SourceNeverCandidate");
            Assert(result.Usage.ReadFiles == 1, "OnlyProjectMarkerSampled");

            // D. Header validity must be re-established at probe time; stale/rewritten files cannot become duplicates.
            Begin("D1-SameSizeRewriteWithInvalidHeaderNoDuplicate");
            var staleRoot = Case("stale-header-invalid");
            byte[] zip = [0x50, 0x4b, 3, 4, 1, 2, 3, 4, 5, 6];
            File.WriteAllBytes(Path.Combine(staleRoot, "setup-a.zip"), zip);
            File.WriteAllBytes(Path.Combine(staleRoot, "setup-b.zip"), zip);
            var staleSnap = Inventory(staleRoot);
            var staleA = staleSnap.Targets.Values.First(t => t.Path.EndsWith("setup-a.zip", StringComparison.OrdinalIgnoreCase));
            File.WriteAllBytes(staleA.Path, Enumerable.Repeat((byte)0x78, 10).ToArray());
            File.SetLastWriteTimeUtc(staleA.Path, new DateTime(staleA.ModifiedUtcTicks, DateTimeKind.Utc));
            var probe = MetadataAccess.Capture("probe-a", staleA.ParentId, staleA.Path);
            Assert(probe.FileIdentity == staleA.FileIdentity && probe.LogicalBytes == staleA.LogicalBytes && probe.ModifiedUtcTicks == staleA.ModifiedUtcTicks,
                $"SameSizeRewritePreservesSnapshotMetadata[snap={staleA.FileIdentity}/{staleA.LogicalBytes}/{staleA.ModifiedUtcTicks}; probe={probe.FileIdentity}/{probe.LogicalBytes}/{probe.ModifiedUtcTicks}]");
            result = await new BoundedExplorationScheduler().AnalyzeAsync(staleSnap, staleSnap.RootId, new Scripted(ExplorationAction.InspectDuplicates, ExplorationAction.Stop));
            Assert(!result.Suggestions.Any(s => s.Classification == Classification.InstallerDuplicate), "InvalidHeaderAfterRewriteProducesNoDuplicate");
            Assert(result.Usage.HashFiles == 1 && result.Usage.HashBytes == 10, "OnlyStillValidHeaderCopyHashed");
            Assert(!result.Suggestions.Any(s => s.MayPrepareForReview), "NothingPreparableFromStaleHeader");

            Begin("D2-EqualHeaderDifferentContentNoDuplicate");
            var differRoot = Case("header-only-equal");
            byte[] first = [0x50, 0x4b, 3, 4, 1, 1, 1, 1, 1, 1];
            byte[] second = [0x50, 0x4b, 3, 4, 2, 2, 2, 2, 2, 2];
            File.WriteAllBytes(Path.Combine(differRoot, "one-a.zip"), first);
            File.WriteAllBytes(Path.Combine(differRoot, "one-b.zip"), second);
            var differSnap = Inventory(differRoot);
            result = await new BoundedExplorationScheduler().AnalyzeAsync(differSnap, differSnap.RootId, new Scripted(ExplorationAction.InspectDuplicates, ExplorationAction.Stop));
            Assert(!result.Suggestions.Any(s => s.Classification == Classification.InstallerDuplicate), "EqualZipHeaderDifferentContentNoDuplicate");
            Assert(result.Usage.HashFiles == 2 && result.Usage.HashBytes == 20, "BothCopiesFullHashedBeforeComparison");
            Assert(!result.Suggestions.Any(s => s.MayPrepareForReview), "NothingPreparableFromHeaderOnlyMatch");

            // F. Verified duplicates must expose full hash and a single keeper while remaining non-approvable.
            Begin("F1-MsiDuplicateProtectedAndNonApprovable");
            var msiRoot = Case("msi-duplicates");
            byte[] msi = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 0x11, 0x22, 0x33, 0x44, 0x55];
            File.WriteAllBytes(Path.Combine(msiRoot, "setup-a.msi"), msi);
            File.WriteAllBytes(Path.Combine(msiRoot, "setup-b.msi"), msi);
            var msiSnap = Inventory(msiRoot);
            var msiAId = msiSnap.Targets.Values.First(t => t.Path.EndsWith("setup-a.msi", StringComparison.OrdinalIgnoreCase)).ObjectId;
            var msiBId = msiSnap.Targets.Values.First(t => t.Path.EndsWith("setup-b.msi", StringComparison.OrdinalIgnoreCase)).ObjectId;
            result = await new BoundedExplorationScheduler().AnalyzeAsync(msiSnap, msiSnap.RootId, new Scripted(ExplorationAction.InspectDuplicates, ExplorationAction.Stop));
            var msiSuggestion = result.Suggestions.Single();
            Assert(msiSuggestion.Classification == Classification.InstallerDuplicate && msiSuggestion.HardProtected, "MsiDuplicateHardProtected");
            Assert(msiSuggestion.Level == SuggestionLevel.OrganizeOpportunity && !msiSuggestion.MayPrepareForReview && !msiSuggestion.SelectedByDefault, "MsiDuplicateNotApprovableOrSelected");
            Assert(msiSuggestion.Duplicate is { ContentSha256.Length: 64, RetainedChoiceConfirmed: false } && msiSuggestion.Duplicate.RetainedFiles.Count == 1, "MsiDuplicateFullHashSingleKeeper");
            Assert(msiSuggestion.CandidateFiles.Count == 1 && msiSuggestion.Duplicate!.RetainedFiles[0].ContentSha256 == msiSuggestion.Duplicate.ContentSha256, "MsiCandidateAndKeeperShareFullHash");
            Assert(msiSuggestion.CandidateFiles[0].ObjectId != msiSuggestion.Duplicate!.RetainedFiles[0].ObjectId, "MsiCandidateIsNotKeeper");
            Assert(msiSuggestion.TargetId == msiSnap.RootId && msiSuggestion.CandidateFiles.All(f => new[] { msiAId, msiBId }.Contains(f.ObjectId)), "MsiTargetsFromTrustedInventoryIds");
            Assert(result.Usage.HashBytes == 26 && result.Usage.HashFiles == 2, "MsiBothCopiesFullHashed");

            // C2. docs beside a project root must not prevent exact bin/dist subsets, nor enter them.
            Begin("C2-DocsBesideProjectStillExactOutputSubset");
            var docsRoot = Case("docs-beside-project");
            Text(docsRoot, "app.csproj", projectXml);
            Text(docsRoot, "bin/app.dll", "synthetic assembly");
            Text(docsRoot, "bin/app.deps.json", "{}");
            Text(docsRoot, "docs/readme.pdf", "synthetic private body never read");
            var docsSnap = Inventory(docsRoot);
            var docsBin = docsSnap.Targets.Values.First(t => Path.GetFileName(t.Path) == "bin").ObjectId;
            var pdfId = docsSnap.Targets.Values.First(t => t.Path.EndsWith("readme.pdf", StringComparison.OrdinalIgnoreCase)).ObjectId;
            result = await Run(docsSnap);
            var buildSuggestion = result.Suggestions.SingleOrDefault(s => s.Classification == Classification.BuildArtifact);
            Assert(buildSuggestion != null && buildSuggestion.TargetId == docsBin, "BinStillBuildArtifactWithDocsPresent");
            Assert(buildSuggestion!.CandidateFiles.Count == 2 && buildSuggestion.CandidateFiles.All(f => f.ObjectId != pdfId), "DistinctBinSubsetExcludesDocsAndRoot");
            Assert(buildSuggestion.MayPrepareForReview && !docsSnap.Targets.Values.Any(t => t.ObjectId == pdfId && buildSuggestion.CandidateFiles.Any(f => f.ObjectId == pdfId)), "DocsNeverCandidate");
            Assert(result.Suggestions.Single(s => s.TargetId == docsSnap.RootId).Classification == Classification.Mixed, "RootWithDocsRemainsProtectedMixed");
            Assert(result.Usage.ReadFiles == 1, "OnlyProjectMarkerSampledWithDocs");

            // E. Chromium detection requires the exact layout plus index magic; a look-alike header must not yield Cache.
            Begin("E1-ChromiumPseudoMagicRejected");
            var pseudo = Case("chromium-pseudo-magic");
            File.WriteAllBytes(Path.Combine(pseudo, "index"), [0x00, 0x01, 0x02, 0x03, 0, 0, 0, 0]);
            for (int i = 0; i < 4; i++) Text(pseudo, "data_" + i, "synthetic");
            Text(pseudo, "f_abcdef", "synthetic entry");
            result = await Run(Inventory(pseudo));
            Assert(result.Suggestions.Count == 0, "PseudoMagicNotCache");
            Assert(result.Evidence.Any(e => e.Kind == EvidenceKind.Missing && e.Value == "ChromiumIndexHeaderMismatch"), "HeaderMismatchEvidenceRecorded");
            Assert(result.Usage.ReadFiles == 1 && result.Usage.SampleBytes == 8, "OnlyIndexHeaderSampled");

            var frozenAfter = HashFrozen(args[1]);
            Assert(frozenBefore.Count == frozenAfter.Count && frozenBefore.All(kv => frozenAfter.TryGetValue(kv.Key, out var v) && v == kv.Value), "FrozenSourcesUnchangedBeforeAndAfter");

            File.WriteAllText(Path.Combine(evidence, "result.json"), JsonSerializer.Serialize(new
            {
                Passed = true,
                Assertions = assertions,
                Cases = caseNames.Count,
                CaseNames = caseNames,
                Sandbox = sandbox,
                AnalysisSha256 = analysisSha,
                FrozenEntries = frozenBefore.Count,
                FrozenUnchanged = true,
                CompletedUtc = DateTime.UtcNow.ToString("o"),
                Checks = checks
            }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"ANALYSIS REGRESSION PASS {assertions} assertions in {caseNames.Count} cases; evidence {evidence}");
            return 0;
        }
        catch (Exception ex)
        {
            File.WriteAllText(Path.Combine(evidence, "failure.txt"), ex.ToString());
            Console.Error.WriteLine(ex);
            return 1;
        }
        finally
        {
            Console.WriteLine($"Retained fixture: {sandbox}; retained junction: {junctionToRemove ?? "none"}; no cleanup performed");
        }
    }
}
