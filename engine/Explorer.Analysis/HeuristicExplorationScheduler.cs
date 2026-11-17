namespace SafeJunkCleaner.Explorer.Analysis;

/// <summary>Offline, evidence-led bounded exploration. Priority never grants cleanup eligibility.</summary>
public sealed class HeuristicExplorationScheduler
{
    private sealed record Work(InventoryTarget Target, ExplorationAction Action, bool Unknown);

    public ValueTask<AnalysisResult> ExploreAsync(InventoryEvidenceSnapshot snapshot, string? targetId = null,
        HeuristicBudget? budget = null, IProgress<HeuristicProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!snapshot.Targets.TryGetValue(targetId ?? snapshot.RootId, out var root)) throw new ArgumentException("TargetNotInInventory");
        var limits = budget ?? new(); var meter = new BudgetMeter(limits, cancellationToken);
        ProbeContext? probes = null; var actions = new List<ExplorationAction>();
        var visited = new HashSet<string>(StringComparer.Ordinal); var executed = new HashSet<(string, ExplorationAction)>();
        var best = new PriorityQueue<Work, (double, string, int)>(); var fair = new Queue<Work>();
        int queued = 0, completed = 0, noEvidence = 0; string? current = null;
        AnalysisStatus status = AnalysisStatus.Complete; string reason = "NoUsefulChecksRemaining";
        var protectedGroups = new Dictionary<string, (InventoryTarget Target, bool Portable, int Branches, int Files, int Directories)>(StringComparer.Ordinal);
        int protectedBranches = 0, protectedFiles = 0, protectedDirectories = 0, omittedBranches = 0;
        var omittedGroupIds = new HashSet<string>(StringComparer.Ordinal);
        int notIndexed = 0, omittedGroups = 0;
        bool protectionFinalized = false;
        void FinalizeProtection()
        {
            if (protectionFinalized || probes == null) return;
            protectionFinalized = true;
            foreach (var group in protectedGroups.Values)
            {
                var p = probes.Fact(group.Target, EvidenceKind.Protection,
                    $"ProtectedBranchMetadataOnly;Branches={group.Branches};ObservedFiles={group.Files};ObservedDirectories={group.Directories}");
                var refs = new List<string> { p };
                if (group.Target.Coverage != Coverage.Complete) refs.Add(probes.Fact(group.Target, EvidenceKind.Missing, "InventoryCoverageIncomplete"));
                probes.Suggest(group.Target, group.Portable ? Classification.Portable : Classification.Mixed,
                    SuggestionLevel.OrganizeOpportunity, [], refs, true,
                    "Known protection closes these observed branches without a content probe; aggregate is not processing authorization");
            }
            if (protectedBranches > 0 || notIndexed > 0)
                probes.Fact(root, EvidenceKind.Protection,
                    $"ProtectionSummary;ObservedBranches={protectedBranches};ObservedFiles={protectedFiles};ObservedDirectories={protectedDirectories};DisplayedGroups={protectedGroups.Count};OmittedDisplayGroups={omittedGroups};OmittedDisplayBranches={omittedBranches};NotCoveredInventoryObjects={notIndexed}");
        }
        void Report(string why, bool more) => progress?.Report(new(visited.Count, queued, completed, current, why, more));
        try
        {
            Report("BuildingChargedInventoryIndex", true);
            // Reserve a real probe allowance rather than spend all 250k units merely copying a
            // maximum-size inventory. An incomplete index is always reported as partial, and the
            // exact-member gate rejects any omitted member before a suggestion can be issued.
            int reserve = Math.Min(32768, limits.MaxMetadataObjects / 4);
            var index = new InventoryIndex(snapshot, meter, root, limits.UntilComplete ? null : limits.MaxMetadataObjects - reserve);
            probes = new(snapshot, meter, cancellationToken, index, true, limits.UntilComplete);
            notIndexed = snapshot.Targets.Count - index.IndexedObjects;
            if (!index.Complete)
            {
                status = AnalysisStatus.BudgetExhausted; reason = "PartialIndexMetadataBudget";
                if (reserve == 0) throw new BudgetExceededException(reason);
            }
            var stack = new Stack<InventoryTarget>(); stack.Push(root);
            while (stack.TryPop(out var t))
            {
                meter.Check(); var summary = index.Get(t);
                if (index.Blocked(t))
                {
                    // Individual private files are summarized at their parent, not expanded into
                    // thousands of suggestions. Directory protection closes and summarizes its branch.
                    var groupTarget = t.Kind == TargetKind.File && t.ObjectId != root.ObjectId && t.ParentId != null ? snapshot.Targets[t.ParentId] : t;
                    int directories = summary.Directories;
                    protectedBranches++; protectedFiles += summary.Files; protectedDirectories += directories;
                    if (protectedGroups.TryGetValue(groupTarget.ObjectId, out var previous))
                        protectedGroups[groupTarget.ObjectId] = (previous.Target, previous.Portable, previous.Branches + 1, previous.Files + summary.Files, previous.Directories + directories);
                    else if (protectedGroups.Count < 128)
                        protectedGroups.Add(groupTarget.ObjectId, (groupTarget, summary.Portable, 1, summary.Files, directories));
                    else { omittedBranches++; if (omittedGroupIds.Add(groupTarget.ObjectId)) omittedGroups++; }
                    // Only the requested scope may spend one real guarded metadata action reporting
                    // its direct-index gap. This never reopens its branch or probes omitted members.
                    if (t.ObjectId == root.ObjectId && summary.IncompleteDirectIndexDiagnostic)
                    { best.Enqueue(new(t, ExplorationAction.InspectLayout, false), (0, t.ObjectId, 0)); queued++; }
                    continue;
                }
                if (t.Kind == TargetKind.Directory || t.ObjectId == root.ObjectId ||
                    t.LogicalBytes >= limits.LargeFileBytes)
                {
                    // A manifest without an output sibling cannot establish any supported layout.
                    // Keep unknowns out of best-first so sheer size cannot outrank concrete clues.
                    bool unknown = t.Kind == TargetKind.Directory && !summary.LayoutClue;
                    double clues = summary.Chromium ? 400 : summary.LayoutClue ? 350 : 0;
                    double yield = Math.Log2(1d + summary.Bytes);
                    double cost = Math.Log2(2d + index.Direct(t).Count) + (summary.LayoutClue && !summary.Chromium ? 4 : 0);
                    var work = new Work(t, ExplorationAction.InspectLayout, unknown);
                    if (unknown) fair.Enqueue(work);
                    else best.Enqueue(work, (-(clues + yield - cost), t.ObjectId, 0));
                    queued++;
                }
                // A hard/unsafe/portable ancestor closes its subtree, unlike ordinary source/docs in a parent.
                foreach (var child in index.Direct(t)) { meter.Check(); stack.Push(child); }
            }
            FinalizeProtection();
            // One scope-level duplicate probe sees copies in separate branches. It is intentionally
            // below strong layout evidence, and is never an ownership/application provenance probe.
            if (root.Kind == TargetKind.Directory && !index.Blocked(root) && index.Get(root).SubtreeComplete && index.Get(root).PackageFiles > 1)
            {
                best.Enqueue(new(root, ExplorationAction.InspectDuplicates, false), (-20, root.ObjectId, 1)); queued++;
            }
            Report(index.Complete ? "EvidencePriorityQueueReady" : "PartialIndexProbeAllowanceReserved", queued > 0);
            while (queued > 0)
            {
                meter.Check(); Work? work = null;
                // Every fourth real action reserves a slot for an unclassified branch, not just big/named targets.
                if (completed % 4 == 3)
                    while (fair.TryDequeue(out var candidate))
                        if (!executed.Contains((candidate.Target.ObjectId, candidate.Action))) { work = candidate; break; }
                if (work == null)
                    while (best.TryDequeue(out var candidate, out _))
                        if (!executed.Contains((candidate.Target.ObjectId, candidate.Action))) { work = candidate; break; }
                if (work == null)
                    while (fair.TryDequeue(out var candidate))
                        if (!executed.Contains((candidate.Target.ObjectId, candidate.Action))) { work = candidate; break; }
                if (work == null) break;
                var t = work.Target; current = t.ObjectId;
                if (work.Action == ExplorationAction.InspectLayout && probes.HasReviewSuggestion(t.ObjectId))
                { executed.Add((t.ObjectId, work.Action)); queued--; Report("ExactSetEvidenceSkipsRedundantLayout", queued > 0); continue; }
                if (!limits.UntilComplete && ((!visited.Contains(t.ObjectId) && visited.Count >= limits.MaxTargets) || meter.Steps >= limits.MaxActions))
                { status = AnalysisStatus.BudgetExhausted; reason = meter.Steps >= limits.MaxActions ? "ActionBudget" : "TargetBudget"; break; }
                executed.Add((t.ObjectId, work.Action)); queued--; visited.Add(t.ObjectId);
                meter.Steps++; actions.Add(work.Action); int before = probes.Evidence.Count;
                Report(work.Unknown ? "UnknownFairExploration" : "EvidenceYieldCostBestFirst", true);
                try { probes.Run(work.Action, t); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
                { probes.Fact(t, EvidenceKind.Missing, "ProbeUnavailableOrInventoryChanged"); }
                completed++;
                if (probes.Evidence.Count == before) noEvidence++;
                // Unknown is visible but never selected, never a candidate, and never authorizes another read.
                if (!probes.HasSuggestion(t.ObjectId) && work.Action == ExplorationAction.InspectLayout &&
                    !probes.HasReviewChild(t.ObjectId))
                {
                    var missing = probes.Fact(t, EvidenceKind.Missing, "InsufficientIndependentEvidenceForReview");
                    probes.Suggest(t, Classification.Unknown, SuggestionLevel.Undetermined, [], [missing], true,
                        "Unknown or failed read; no processing authorization");
                }
                Report(probes.Evidence.Count > before ? "EvidenceRecorded" : "NoNewEvidenceStopBranch", queued > 0);
            }
            if (status == AnalysisStatus.Complete && completed > 0 && noEvidence == completed)
            { status = AnalysisStatus.NoProgress; reason = "NoNewProbeEvidence"; }
        }
        catch (BudgetExceededException ex) { status = AnalysisStatus.BudgetExhausted; reason = ex.Message; }
        catch (OperationCanceledException) { status = AnalysisStatus.Cancelled; reason = "ExplicitCancellation"; }
        FinalizeProtection();
        if (probes?.OmittedSuggestionCount > 0)
        {
            probes.Fact(root, EvidenceKind.Missing, $"SuggestionDisplayLimit;OmittedSuggestions={probes.OmittedSuggestionCount};NotCoveredForDisplayOnly;NoAuthorization");
            if (status is AnalysisStatus.Complete or AnalysisStatus.NoProgress)
            { status = AnalysisStatus.BudgetExhausted; reason = "SuggestionDisplayBudget"; }
        }
        current = null; Report(reason, status == AnalysisStatus.BudgetExhausted || status == AnalysisStatus.Cancelled);
        return ValueTask.FromResult(new AnalysisResult(snapshot.TaskId, snapshot.Revision, status,
            probes?.Evidence.AsReadOnly() ?? (IReadOnlyList<AnalysisEvidence>)Array.Empty<AnalysisEvidence>(),
            probes?.Suggestions.AsReadOnly() ?? (IReadOnlyList<Suggestion>)Array.Empty<Suggestion>(),
            actions.AsReadOnly(), meter.Usage, reason));
    }
}
