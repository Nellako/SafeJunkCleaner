using SafeJunkCleaner.Explorer;

internal static class BatchLifecycle
{
    public static void Run(string root, Action<bool, string> check)
    {
        string tree = Path.Combine(root, "lifecycle-tree");
        Directory.CreateDirectory(tree);
        for (int i = 0; i < 6000; i++) File.WriteAllText(Path.Combine(tree, i.ToString("D5") + ".tmp"), "owned synthetic only");
        string state = Path.Combine(root, "lifecycle-state"), batch, task;
        long revision;
        static void Settled(InventoryEngine engine, string task)
        {
            var end = DateTime.UtcNow.AddSeconds(30);
            while (engine.ReadTaskHeader(task).State == "Inventory" && DateTime.UtcNow < end) Thread.Sleep(5);
            if (engine.ReadTaskHeader(task).State == "Inventory") throw new TimeoutException("Owned worker did not settle");
            Thread.Sleep(25);
        }
        using (var engine = new InventoryEngine(state))
        {
            var snapshot = engine.CreateBatch(Guid.NewGuid().ToString("D"), [tree]);
            batch = snapshot.BatchId;
            var started = engine.StartBatchEntry(batch, 0, snapshot.Revision);
            task = started.TaskId!;
            check(engine.ReadTaskHeader(task).State == "Inventory", "Actual worker active before pause");
            engine.PauseBatch(batch, engine.GetBatch(batch).Revision);
            Settled(engine, task);
            check(engine.ReadTaskHeader(task).State == "Paused", "Actual worker pauses");
            revision = engine.ReadTaskHeader(task).EvidenceRevision;
            bool rejected = false;
            try { engine.Resume(task); } catch (InvalidOperationException ex) when (ex.Message == "BatchEntryStartRequired") { rejected = true; }
            check(rejected, "Legacy Resume cannot bypass batch confirmation");
            rejected = false;
            try { engine.CreateInventory(tree); } catch (InvalidOperationException ex) when (ex.Message == "BatchActive") { rejected = true; }
            check(rejected, "Paused batch blocks unrelated inventory");
            rejected = false;
            try { engine.CompactState(true); } catch (StateCompactionException ex) when (ex.Message == "InventoryActive") { rejected = true; }
            catch (InvalidOperationException ex) when (ex.Message == "InventoryActive") { rejected = true; }
            check(rejected, "Paused batch blocks compaction");
        }
        using (var engine = new InventoryEngine(state))
        {
            var snapshot = engine.GetBatch(batch);
            check(snapshot.State == "Interrupted" && engine.ReadTaskHeader(task).State == "Paused", "Reopen preserves inactive interrupted batch");
            long before = engine.ReadTaskHeader(task).EvidenceRevision;
            Thread.Sleep(150);
            check(engine.ReadTaskHeader(task).EvidenceRevision == before && engine.ReadTaskHeader(task).State == "Paused", "Reopen and wait cannot start a worker");
            bool rejected = false;
            try { engine.ContinueBatch(batch, snapshot.Revision, false); } catch (InvalidOperationException ex) when (ex.Message == "ExplicitBatchContinuationRequired") { rejected = true; }
            check(rejected, "False confirmation cannot continue");
            snapshot = engine.ContinueBatch(batch, snapshot.Revision, true);
            var started = engine.StartBatchEntry(batch, 0, snapshot.Revision);
            check(started.TaskId == task && engine.ReadTaskHeader(task).EvidenceRevision > revision, "Explicit continue rebuilds same task revision");
            engine.CancelBatch(batch, engine.GetBatch(batch).Revision);
            Settled(engine, task);
            check(engine.ReadTaskHeader(task).State == "Cancelled", "Actual worker cancellation persists");
        }
        using (var engine = new InventoryEngine(state))
            check(engine.ReadTaskHeader(task).State == "Cancelled" && !engine.GetBatch(batch).CanContinue, "Cancelled sole item never auto resumes");
        check(Directory.GetFiles(tree).Length == 6000 && Directory.GetFiles(tree).All(path => File.ReadAllText(path) == "owned synthetic only"), "Lifecycle input tree remains unchanged");
    }
}
