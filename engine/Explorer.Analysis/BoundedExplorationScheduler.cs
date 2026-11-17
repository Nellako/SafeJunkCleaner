namespace SafeJunkCleaner.Explorer.Analysis;

public sealed class BoundedExplorationScheduler
{
    public async ValueTask<AnalysisResult> AnalyzeAsync(InventoryEvidenceSnapshot snapshot, string targetId,
        IExplorationDecider decider, AnalysisBudget? budget = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(snapshot); ArgumentNullException.ThrowIfNull(decider);
        if (!snapshot.Targets.TryGetValue(targetId, out var target)) throw new ArgumentException("TargetNotInInventory");
        var meter = new BudgetMeter(budget ?? new()); var probes = new ProbeContext(snapshot, meter, cancellationToken);
        var actions = new List<ExplorationAction>(); var executed = new List<ExecutedProbe>(); var visited = new HashSet<(string, ExplorationAction)>();
        AnalysisStatus status = AnalysisStatus.Complete; string reason = "ExplicitStop";
        try
        {
            // Facts remain available without a model. Subsequent checks are selected, not explanations.
            meter.Steps++; probes.Run(ExplorationAction.InspectLayout, target); actions.Add(ExplorationAction.InspectLayout); visited.Add((targetId, ExplorationAction.InspectLayout)); executed.Add(new(targetId, ExplorationAction.InspectLayout));
            bool policyStop = target.HardProtected || target.Coverage != Coverage.Complete ||
                probes.Suggestions.Any(s => s.TargetId == targetId && s.HardProtected && s.Classification is Classification.UserData or Classification.Mixed or Classification.Portable) ||
                probes.Evidence.Any(e => e.Kind == EvidenceKind.Missing && e.Value == "ProbeUnavailableOrInventoryChanged");
            if (policyStop) { reason = "ProgramPolicyProtectedStop_NotModelDecision"; actions.Add(ExplorationAction.Stop); }
            while (!policyStop && meter.Steps < meter.Limits.MaxSteps)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var ids = snapshot.Targets.Values.Where(t => t.ObjectId == targetId || t.ParentId == targetId).Select(t => t.ObjectId).Take(meter.Limits.MaxDecisionTargets).ToArray();
                if (!ids.Contains(targetId, StringComparer.Ordinal)) ids = [targetId];
                var evidence = probes.Evidence.TakeLast(meter.Limits.MaxStateEvidence).Select(e => new StateEvidence(e.EvidenceId, e.Kind, e.Value)).ToArray();
                var remaining = Enum.GetValues<ExplorationAction>().Where(a => a is ExplorationAction.Stop or ExplorationAction.AskUser || ids.Any(id => !visited.Contains((id, a)))).ToArray();
                var state = new AnalysisState(snapshot.TaskId, snapshot.Revision, targetId, evidence, ids,
                    remaining, Enum.GetValues<Classification>(), executed.ToArray(), meter.Usage, meter.Limits);
                var decision = await decider.DecideAsync(state, cancellationToken);
                meter.Steps++;
                if (!decision.Available) { status = AnalysisStatus.ModelUnavailable; reason = "DeciderUnavailableFactsOnly"; break; }
                if (!state.AllowedActions.Contains(decision.Action) || !state.AllowedClassifications.Contains(decision.Classification) || !ids.Contains(decision.TargetId, StringComparer.Ordinal))
                { status = AnalysisStatus.InvalidDecision; reason = "DecisionOutsideAllowedSet"; break; }
                if (decision.Action == ExplorationAction.Stop) { reason = "DeciderStopped"; actions.Add(decision.Action); break; }
                if (decision.Action == ExplorationAction.AskUser)
                {
                    probes.Fact(snapshot.Targets[decision.TargetId], EvidenceKind.Question, "UserReviewRequiredNoAuthorization");
                    actions.Add(decision.Action); status = AnalysisStatus.AskedUser; reason = "AwaitingUserNoExecution"; break;
                }
                if (!visited.Add((decision.TargetId, decision.Action))) { status = AnalysisStatus.NoProgress; reason = "RepeatedTargetAction"; break; }
                int before = probes.Evidence.Count;
                probes.Run(decision.Action, snapshot.Targets[decision.TargetId]); actions.Add(decision.Action); executed.Add(new(decision.TargetId, decision.Action));
                if (probes.Evidence.Count == before) { status = AnalysisStatus.NoProgress; reason = "ProbeProducedNoNewEvidence"; break; }
                if (meter.Steps == meter.Limits.MaxSteps) { status = AnalysisStatus.BudgetExhausted; reason = "StepBudget"; }
            }
            if (meter.Steps >= meter.Limits.MaxSteps && reason == "ExplicitStop") { status = AnalysisStatus.BudgetExhausted; reason = "StepBudget"; }
        }
        catch (BudgetExceededException) { status = AnalysisStatus.BudgetExhausted; reason = "ReadMetadataOrHashBudget"; }
        catch (OperationCanceledException) { status = AnalysisStatus.Cancelled; reason = "ExplicitCancellation"; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            probes.Fact(target, EvidenceKind.Missing, "ProbeUnavailableOrInventoryChanged"); status = AnalysisStatus.NoProgress; reason = "ReadOnlyProbeRejected";
        }
        // Model labels never rewrite deterministic protection or candidate membership.
        return new(snapshot.TaskId, snapshot.Revision, status, probes.Evidence.AsReadOnly(), probes.Suggestions.AsReadOnly(), actions.AsReadOnly(), meter.Usage, reason);
    }
}
