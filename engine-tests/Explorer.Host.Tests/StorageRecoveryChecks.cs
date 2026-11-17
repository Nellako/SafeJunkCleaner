using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using SafeJunkCleaner.Explorer;
using SafeJunkCleaner.Explorer.Application;
using SafeJunkCleaner.Explorer.Execution;
using SafeJunkCleaner.Explorer.Host;

internal static class StorageRecoveryChecks
{
    internal static async Task<int> Run(string local)
    {
        string state = Path.Combine(local, "budget-recovery-state"), tree = Path.Combine(local, "budget-recovery-empty-tree");
        Directory.CreateDirectory(tree);
        string task;
        using (var initial = new InventoryEngine(state))
        {
            task = initial.CreateInventory(tree);
            for (int i = 0; i < 2000 && initial.ReadTaskHeader(task).State == "Inventory"; i++) await Task.Delay(5);
            if (initial.ReadTaskHeader(task).State != "Ready") throw new Exception("Recovery fixture not Ready");
        }
        using (var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(state, "inventory.db"), Pooling = false }.ToString()))
        {
            db.Open(); using var command = db.CreateCommand();
            command.CommandText = "DROP INDEX task_objects;VACUUM;PRAGMA wal_checkpoint(TRUNCATE)"; command.ExecuteNonQuery();
        }
        long smallLimit = Directory.GetFiles(state).Sum(p => new FileInfo(p).Length) + 4096;
        using var engine = new InventoryEngine(state, new ExplorerLimits(MaxStateBytes: smallLimit));
        var rows = new HostInventoryRows(engine);
        using var store = new WindowsApprovalStore(Path.Combine(local, "budget-recovery-approvals"));
        var facts = new WindowsExecutionFacts(state);
        using var coordinator = new ExplorerCoordinator(rows, facts.OwnerSid, store, facts, new UnavailableWindowsRecycler(),
            snapshots => new ApprovalSourceAdapter(rows, snapshots, facts));
        using var input = new MemoryStream();
        void Request(string op, object payload)
        {
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { ProtocolVersion = 1, RequestId = Guid.NewGuid().ToString("D"), TaskId = (string?)null, Operation = op, Payload = payload }) + "\n");
            input.Write(bytes);
        }
        Request("GetStorageInfo", new { });
        Request("ListTasks", new { AfterTaskId = (string?)null, PageSize = 64 });
        Request("CreateInventory", new { SelectedPath = tree });
        Request("ConfigureStorageBudget", new { Mebibytes = 512, Confirmed = false });
        Request("GetStorageInfo", new { });
        Request("ConfigureStorageBudget", new { Mebibytes = 512, Confirmed = true });
        Request("GetStorageInfo", new { });
        Request("ListTasks", new { AfterTaskId = (string?)null, PageSize = 64 });
        input.Position = 0; using var output = new StringWriter();
        await HostProtocol.RunAsync(engine, coordinator, engine.ListTasks, input, output);
        var replies = output.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => JsonDocument.Parse(line).RootElement.Clone()).ToArray();
        int count = 0;
        void Check(bool ok, string reason) { if (!ok) throw new Exception(reason); count++; }
        Check(replies.Length == 8 && replies.Where((_, i) => i is not (2 or 3)).All(r => r.GetProperty("Ok").GetBoolean()), "Host recovery protocol remains usable");
        Check(replies[0].GetProperty("Result").GetProperty("IndexRepairPending").GetBoolean() && replies[0].GetProperty("Result").GetProperty("MaxStateBytes").GetInt64() == smallLimit,
            "Host reports deferred optional access path without raising quota");
        Check(replies[1].GetProperty("Result").GetProperty("Items")[0].GetProperty("TaskId").GetString() == task, "Host lists legacy inventory before repair");
        Check(!replies[2].GetProperty("Ok").GetBoolean() && replies[2].GetProperty("Error").GetProperty("Code").GetString() == "IndexQuotaExceededReleaseCompletedTask", "Host does not bypass quota while index deferred");
        Check(!replies[3].GetProperty("Ok").GetBoolean() && replies[3].GetProperty("Error").GetProperty("Code").GetString() == "ExplicitStorageBudgetConfirmationRequired", "Host requires explicit budget confirmation");
        Check(replies[4].GetProperty("Result").GetProperty("MaxStateBytes").GetInt64() == smallLimit && replies[4].GetProperty("Result").GetProperty("IndexRepairPending").GetBoolean(), "Host refusal does not change budget or access path");
        Check(!replies[5].GetProperty("Result").GetProperty("IndexRepairPending").GetBoolean() && replies[5].GetProperty("Result").GetProperty("SessionOnly").GetBoolean(), "Host explicit budget request repairs optional index");
        Check(!replies[6].GetProperty("Result").GetProperty("IndexRepairPending").GetBoolean() && replies[7].GetProperty("Result").GetProperty("Items").GetArrayLength() == 1 &&
            replies[7].GetProperty("Result").GetProperty("Items")[0].GetProperty("TaskId").GetString() == task, "Host repair preserves exact task history without generation");
        File.WriteAllText(Path.Combine(local, "storage-recovery-protocol.json"), output.ToString());
        return count;
    }
}
