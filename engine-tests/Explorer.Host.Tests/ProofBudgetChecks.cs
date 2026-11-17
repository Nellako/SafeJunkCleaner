using System.Text.Json;
using SafeJunkCleaner.Explorer;
using SafeJunkCleaner.Explorer.Application;
using SafeJunkCleaner.Explorer.Execution;
using SafeJunkCleaner.Explorer.Host;

internal static class ProofBudgetChecks
{
    internal static async Task<int> Run(string local)
    {
        int count = 0;
        void Assert(bool value, string name) { if (!value) throw new Exception(name); count++; }
        string project = Path.Combine(local, "proof-budget-project"); Directory.CreateDirectory(Path.Combine(project, "bin"));
        File.WriteAllText(Path.Combine(project, "proof.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk\" />");
        string file = Path.Combine(project, "bin", "proof.dll"); File.WriteAllBytes(file, Enumerable.Range(0, 37).Select(i => (byte)i).ToArray());
        File.WriteAllText(Path.Combine(project, "bin", "proof.deps.json"), "{}");
        var fact = WindowsFacts.Read(file); var expected = new FileSnapshot(Guid.NewGuid().ToString("D"), file, fact.Identity, fact.LogicalBytes, fact.ModifiedUtc);
        using (var hashes = new ProofHashSession(100, 2, new(0, 0, 0, 0, 0, 0), CancellationToken.None))
        {
            var first = hashes.Bind(expected); var second = hashes.Bind(expected);
            Assert(first?.ContentSha256 is { Length: 64 } && second == first && hashes.HashFiles == 1 && hashes.HashBytes == 37, "actual small DLL is read/charged once and cache reuses exact proof");
            bool sharingDenied = false; try { using var write = new FileStream(file, FileMode.Open, FileAccess.Write, FileShare.Read); } catch (IOException) { sharingDenied = true; }
            Assert(sharingDenied, "held proof handle prevents same-metadata content writes during canonical binding");
            hashes.Sealed = true; Assert(hashes.Bind(expected) == first && hashes.HashFiles == 1, "sealed canonical revalidation uses held hash without extra reads");
        }
        using (var exhausted = new ProofHashSession(36, 1, new(0, 0, 0, 0, 0, 0), CancellationToken.None))
            Assert(exhausted.Bind(expected) == null && exhausted.HashFiles == 0 && exhausted.HashBytes == 0 && exhausted.DeniedIdentities.Contains(fact.Identity), "insufficient byte budget rejects before reading file content");
        using (var exhausted = new ProofHashSession(100, 1, new(0, 0, 0, 0, 1, 1), CancellationToken.None))
            Assert(exhausted.Bind(expected) == null && exhausted.HashFiles == 0 && exhausted.HashBytes == 0, "scheduler hash file usage reduces proof budget before read");
        using (var token = new CancellationTokenSource())
        {
            token.Cancel(); using var cancelled = new ProofHashSession(100, 1, new(0, 0, 0, 0, 0, 0), token.Token);
            bool stopped = false; try { cancelled.Bind(expected); } catch (OperationCanceledException) { stopped = true; }
            Assert(stopped && cancelled.HashFiles == 0, "proof cancellation precedes file read");
        }
        string state = Path.Combine(local, "proof-budget-state"); using var engine = new InventoryEngine(state); var rows = new HostInventoryRows(engine);
        using var store = new WindowsApprovalStore(Path.Combine(local, "proof-budget-approvals")); var baseFacts = new WindowsExecutionFacts(state); ExplorerCoordinator? c = null;
        var provider = new HostBuildArtifactProvider(rows, () => c!); var facts = new WindowsExecutionFacts(state, provider);
        using var coordinator = c = new(rows, facts.OwnerSid, store, facts, new NoRecycle(), snapshots => { var source = new ApprovalSourceAdapter(rows, snapshots, baseFacts, provider.BindCandidateHash); provider.Bind(source); return source; }, provider.Register, investigationHashBytes: 36);
        string task = engine.CreateInventory(project);
        for (int i = 0; i < 1000 && engine.ReadTaskHeader(task).State == "Inventory"; i++) await Task.Delay(5);
        var header = rows.ReadHeader(task); string id = JsonSerializer.SerializeToElement(c.Analyze(task, null, header.Revision, "Scope")).GetProperty("AnalysisId").GetString()!;
        JsonElement progress = default;
        for (int i = 0; i < 2000; i++) { progress = JsonSerializer.SerializeToElement(c.GetAnalysisProgress(task, id)); if (progress.GetProperty("Status").GetString() != "Running") break; await Task.Delay(5); }
        Assert(progress.GetProperty("Status").GetString() == "BudgetExhausted" && progress.GetProperty("Reason").GetString()!.StartsWith(ProofHashSession.BudgetReason, StringComparison.Ordinal), "proof budget exhaustion is visible as partial completion");
        Assert(progress.GetProperty("HasResult").GetBoolean(), "published budget-limited suggestion snapshot explicitly has a result");
        Assert(progress.GetProperty("Usage").GetProperty("HashFiles").GetInt32() == 0 && progress.GetProperty("Usage").GetProperty("HashBytes").GetInt64() == 0, "budget blocked first display reports zero actual proof reads");
        var suggestions = JsonSerializer.SerializeToElement(c.QuerySuggestions(task, id, null, 64)).GetProperty("Items");
        var build = suggestions.EnumerateArray().Single(s => s.GetProperty("Classification").GetString() == "BuildArtifact");
        Assert(!build.GetProperty("MayPrepareForReview").GetBoolean() && build.GetProperty("HardProtected").GetBoolean() && build.GetProperty("ApprovalBlockedReason").GetString() == ProofHashSession.BudgetReason && build.GetProperty("CandidateCount").GetInt32() == 2, "whole proof group remains display-only with explicit hash budget reason, no remainder authorization");
        bool rejected = false; try { c.PrepareApproval(task, id, [build.GetProperty("SuggestionId").GetString()!], header.Revision); } catch (InvalidOperationException) { rejected = true; }
        Assert(rejected, "budget denied whole group cannot prepare approval");
        return count;
    }
    private sealed class NoRecycle : IRecycleOnly
    {
        public bool IsAvailable => false; public string UnavailableReason => "SyntheticNoExecution";
        public RecycleResult Recycle(FileSnapshot expected, CancellationToken token) => throw new Exception("UnexpectedRecycle");
    }
}
