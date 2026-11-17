using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using SafeJunkCleaner.Explorer.Analysis;
using SafeJunkCleaner.Explorer.Model;
using ModelProbe = SafeJunkCleaner.Explorer.Model.ExecutedProbe;

namespace SafeJunkCleaner.Explorer.Host;

internal sealed record HostModelDecision(string Status, string Reason, string Action, string TargetId, string[] EvidenceIds, double LatencyMs);
internal sealed class HostModelBridge
{
    internal static string ComponentRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SafeJunkCleaner", "ModelComponents", "qwen25-15b-q8-b12233");
    private readonly Task<bool> availability;
    internal HostModelBridge()
    {
        availability = Task.Run(async () => { try { await PackagedModelBootstrap.EnsureAsync(CancellationToken.None); return true; } catch { return false; } });
    }
    internal bool Available => availability.IsCompletedSuccessfully && availability.Result;
    internal string AvailabilityStatus => !availability.IsCompleted ? "Checking" : Available ? "Verified" : "Unavailable";
    internal IExplorationDecider Create(InventoryEvidenceSnapshot snapshot, List<HostModelDecision> decisions)
    {
        if (!Available) return new UnavailableDecider();
        var parent = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SafeJunkCleaner", "model-host-work");
        if (!Directory.Exists(parent)) Directory.CreateDirectory(parent);
        using (WindowsFacts.Guard(parent))
            if (Directory.EnumerateDirectories(parent).Take(9).Count() >= 8) throw new InvalidOperationException("ModelWorkQuotaReleaseCompletedAnalysis");
        string root = Path.Combine(parent, Guid.NewGuid().ToString("D"));
        using (WindowsFacts.Guard(parent))
        {
            var sid = WindowsIdentity.GetCurrent().User!; var acl = new DirectorySecurity(); acl.SetOwner(sid); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            FileSystemAclExtensions.CreateDirectory(acl, root);
        }
        var native = new NativeProcessExplorationDecider(new(ComponentRoot, root, TimeSpan.FromSeconds(60), state => Context(snapshot, state)));
        return new RecordingDecider(native, root, decisions, snapshot);
    }
    private static ModelDecisionContext Context(InventoryEvidenceSnapshot snapshot, AnalysisState state)
    {
        if (state.ExecutedActions == null || state.CurrentUsage == null || state.Budget == null || !snapshot.Targets.TryGetValue(state.TargetId, out var target)) throw new InvalidOperationException("MissingTrustedSchedulerContext");
        bool readable = false;
        try
        {
            using var guard = WindowsFacts.Guard(target.Kind == TargetKind.Directory ? target.Path : Path.GetDirectoryName(target.Path)!);
            var fact = WindowsFacts.Read(target.Path);
            readable = fact.Identity == target.FileIdentity && (fact.Attributes & WindowsFacts.UnsafeAttributes) == 0;
            if (readable)
            {
                _ = target.Kind == TargetKind.Directory ? new DirectoryInfo(target.Path).GetAccessControl().GetOwner(typeof(SecurityIdentifier)) : new FileInfo(target.Path).GetAccessControl().GetOwner(typeof(SecurityIdentifier));
                // ACL availability is not application ownership; do not claim that capability.
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or InvalidOperationException) { }
        bool Protected(InventoryTarget t)
        {
            for (InventoryTarget? p = t; p != null; p = p.ParentId == null ? null : snapshot.Targets[p.ParentId])
                if (p.HardProtected || p.Coverage != Coverage.Complete || (p.Attributes & WindowsFacts.UnsafeAttributes) != 0) return true;
            return new[] { ".doc", ".docx", ".jpg", ".png", ".bak", ".db", ".sqlite" }.Contains(Path.GetExtension(t.Path).ToLowerInvariant());
        }
        var files = snapshot.Targets.Values.Where(t => t.Kind == TargetKind.File && WindowsFacts.Within(t.Path, target.Path) && !Protected(t) && t.LinkCount == 1 && t.LogicalBytes > 0 && Path.GetExtension(t.Path).ToLowerInvariant() is ".zip" or ".msi").ToArray();
        var pairs = files.GroupBy(t => t.LogicalBytes).Where(g => g.Select(t => t.FileIdentity).Distinct().Count() > 1).ToArray();
        bool same = pairs.Length > 0;
        long minimumPairBytes = same ? pairs.Min(g => checked(g.Key!.Value * 2)) : long.MaxValue;
        bool hashed = state.ExecutedActions.Any(e => e.TargetId == state.TargetId && e.Action == ExplorationAction.InspectDuplicates);
        bool hashAllowed = readable && !Protected(target) && !hashed && same && state.Budget.MaxHashFiles - state.CurrentUsage.HashFiles >= 2 && state.Budget.MaxHashBytes - state.CurrentUsage.HashBytes >= minimumPairBytes && state.Budget.MaxReadFiles - state.CurrentUsage.ReadFiles >= 2;
        var executed = state.ExecutedActions.Select(e => new ModelProbe(e.TargetId, e.Action)).ToArray();
        return new(executed, same && !hashed ? [new(state.TargetId, ProbeFact.SameSizeDifferentIdentityPackagesNotHashed)] : [],
            new(target.Coverage, readable, false, hashAllowed, same, Math.Max(1, state.Budget.MaxSteps - state.CurrentUsage.Steps)));
    }
    private sealed class RecordingDecider(NativeProcessExplorationDecider native, string root, List<HostModelDecision> decisions, InventoryEvidenceSnapshot snapshot) : IExplorationDecider, IDisposable
    {
        public void Dispose()
        {
            try
            {
                using (WindowsFacts.Guard(root))
                {
                    var entries = Directory.EnumerateFileSystemEntries(root).ToArray();
                    foreach (var entry in entries)
                    {
                        if (Path.GetFileName(entry) == "attempts.jsonl" && File.Exists(entry)) { if ((WindowsFacts.Read(entry).Attributes & WindowsFacts.UnsafeAttributes) != 0) return; }
                        else if (Guid.TryParseExact(Path.GetFileName(entry), "D", out _) && Directory.Exists(entry))
                        {
                            using var guard = WindowsFacts.Guard(entry);
                            if (Directory.EnumerateFileSystemEntries(entry).Any(p => Path.GetFileName(p) != "decision.gbnf" || (WindowsFacts.Read(p).Attributes & (WindowsFacts.UnsafeAttributes | 16)) != 0)) return;
                        }
                        else return;
                    }
                }
                foreach (var entry in Directory.EnumerateFileSystemEntries(root))
                    if (Directory.Exists(entry)) { File.Delete(Path.Combine(entry, "decision.gbnf")); Directory.Delete(entry); } else File.Delete(entry);
                Directory.Delete(root);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception) { Console.Error.WriteLine("Model work release skipped: " + ex.GetType().Name); }
        }
        public async ValueTask<ExplorationDecision> DecideAsync(AnalysisState state, CancellationToken token)
        {
            var context = Context(snapshot, state);
            var allowed = state.AllowedActions.Where(a => a is ExplorationAction.Stop or ExplorationAction.AskUser || a == ExplorationAction.InspectDuplicates && context.Metadata?.HashAllowed == true).ToArray();
            if (decisions.Count >= 2 || !allowed.Any(a => a is not (ExplorationAction.Stop or ExplorationAction.AskUser)))
            {
                lock (decisions) decisions.Add(new("ProgramPolicy", decisions.Count >= 2 ? "ModelCallBudgetReached" : "SkippedNoUsefulChoice", "Stop", state.TargetId, [], 0));
                return new(true, ExplorationAction.Stop, state.TargetId);
            }
            var decision = await native.DecideAsync(state with { AllowedActions = allowed, ExistingTargetIds = [state.TargetId] }, token);
            var attempt = native.LastAttempt;
            var summary = new HostModelDecision(attempt?.Status ?? "Unavailable", attempt?.Reason ?? "NoAttempt", decision.Action.ToString(), decision.TargetId, attempt?.EvidenceIds.ToArray() ?? [], attempt?.LatencyMs ?? 0);
            lock (decisions) decisions.Add(summary);
            // Bounded private diagnostics only; never stream prompts/raw output to JSONL/UI.
            string log = Path.Combine(root, "attempts.jsonl");
            string record = JsonSerializer.Serialize(new { Summary = summary, attempt?.InputHash, attempt?.PromptTokens, attempt?.OutputTokens });
            if ((!File.Exists(log) || new FileInfo(log).Length < 65536) && record.Length <= 8192) File.AppendAllText(log, record + "\n");
            return decision;
        }
    }
}
