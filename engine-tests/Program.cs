using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using SafeJunkCleaner.Explorer;

internal static class Program
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateHardLink(string name, string existing, IntPtr reserved);
    private static int assertions;
    private static readonly List<object> checks = [];
    private static void Assert(bool value, string name) { if (!value) throw new Exception(name); assertions++; checks.Add(new { Name = name, Passed = true }); }
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value);
    private static string Status(InventoryEngine e, string task) => Json(e.GetProgress(task)).GetProperty("Task").GetProperty("State").GetString()!;
    private static void Wait(InventoryEngine e, string task, string expected)
    {
        for (int i = 0; i < 1000 && Status(e, task) == "Inventory"; i++) Thread.Sleep(5);
        Assert(Status(e, task) == expected, "State=" + expected);
    }
    private static void Reject(Action action, string name) { try { action(); } catch { Assert(true, name); return; } throw new Exception("Not rejected: " + name); }
    public static async Task<int> Main(string[] args)
    {
        var run = TestEvidence.CreateFixture(args[0], "boundary"); Directory.CreateDirectory(run);
        string files = Path.Combine(run, "files"); Directory.CreateDirectory(files);
        var localTestRoot = TestEvidence.CreateFixture(args[0], "core-fixture");
        Directory.CreateDirectory(localTestRoot);
        File.WriteAllText(Path.Combine(localTestRoot, ".sandbox-owner"), $"{WindowsIdentity.GetCurrent().User!.Value}|{localTestRoot}");
        if (new DirectoryInfo(localTestRoot).GetAccessControl().GetOwner(typeof(SecurityIdentifier))?.Value != WindowsIdentity.GetCurrent().User!.Value) throw new Exception("Synthetic sandbox owner mismatch");
        string root = Path.Combine(localTestRoot, "state");
        checks.Add(new { Name = "RegisteredSyntheticPrivateState", Path = localTestRoot });
        try
        {
            File.WriteAllBytes(Path.Combine(files, "original.bin"), new byte[12345]);
            Assert(CreateHardLink(Path.Combine(files, "hardlink.bin"), Path.Combine(files, "original.bin"), IntPtr.Zero), "SyntheticHardlinkCreated");
            var offline = Path.Combine(files, "offline.bin"); File.WriteAllText(offline, "synthetic offline attribute"); File.SetAttributes(offline, FileAttributes.Offline);
            bool linkCreated = false;
            try { Directory.CreateSymbolicLink(Path.Combine(files, "link"), files); linkCreated = true; }
            catch (Exception ex) { checks.Add(new { Name = "SyntheticSymlink", Skipped = ex.GetType().Name }); }
            using (var e = new InventoryEngine(root))
            {
                var task = e.CreateInventory(files); Wait(e, task, "Partial");
                var evidence = Json(e.QueryEvidence(task, 0, 64, null)).GetProperty("Items");
                Assert(evidence.EnumerateArray().Any(x => x.GetProperty("LinkCount").ValueKind == JsonValueKind.Number && x.GetProperty("LinkCount").GetInt64() == 2), "HardLinksRecorded");
                Assert(evidence.EnumerateArray().Any(x => x.GetProperty("Path").GetString() == offline && x.GetProperty("SkippedReason").GetString() == "ReparseOfflineOrCloudPlaceholder" && x.GetProperty("LogicalBytes").ValueKind == JsonValueKind.Null), "OfflineMetadataSkippedNoZero");
                if (linkCreated) Assert(evidence.EnumerateArray().Any(x => x.GetProperty("Path").GetString()!.EndsWith("\\link") && x.GetProperty("Coverage").GetString() == "NotCovered"), "ReparseSkipped");
                Assert(Json(e.GetProgress(task)).GetProperty("Coverage").GetProperty("ObservedLogicalBytes").GetInt64() == 12345, "HardLinkTotalDeduplicated");
                var space = e.QuerySpace(task, null, 64); var rootSpace = space.Items.Single(i => i.Path == files);
                Assert(rootSpace.ObservedLogicalBytes == 12345 && rootSpace.HardLinkedFiles == 1 && rootSpace.Coverage == "Partial" && rootSpace.UnknownAllocationObjects >= 1, "RecursiveSpaceHardLinkAndGapSemantics");
                Assert(space.Items.Single(i => i.Path == offline).ObservedLogicalBytes == null, "SpaceOfflineGapNotZero");
                Assert(Json(e.QueryGroups(task, 0, 64)).GetProperty("Items")[0].GetProperty("Coverage").GetString() == "Partial", "PartialCoveragePropagated");
                Reject(() => e.Resume(task), "ResumeTerminalRejected");
                Reject(() => e.GetProgress(Guid.NewGuid().ToString("D")), "UnknownTaskRejected");
                Reject(() => e.CreateInventory(root), "StateScopeRejected");
                foreach (var path in new[] { @"\\server\share", @"\\?\C:\", @"C:\a\..\b", @"C:\a:stream", @"C:\a.\b" }) Reject(() => WindowsFacts.Canonical(path), "PathRejected:" + path);
                // Strict protocol rejects malformed/oversized input without losing framing.
                var id = Guid.NewGuid().ToString("D");
                string health = JsonSerializer.Serialize(new { ProtocolVersion = 1, RequestId = id, TaskId = (string?)null, Operation = "Health", Payload = new { } });
                string input = health + "\n" + health + "\n" + new string('x', JsonProtocol.MaxMessageBytes + 1) + "\n" + "{\"ProtocolVersion\":1,\"RequestId\":\"" + Guid.NewGuid().ToString("D") + "\",\"TaskId\":null,\"Operation\":\"Health\",\"Payload\":{},\"extra\":1}\n";
                using var stream = new MemoryStream(Encoding.UTF8.GetBytes(input)); using var output = new StringWriter();
                await JsonProtocol.RunAsync(e, stream, output); var lines = output.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries);
                File.WriteAllText(Path.Combine(run, "protocol-boundaries.jsonl"), output.ToString());
                Assert(lines.Length == 4, "OneResponsePerLine"); Assert(lines.All(x => Encoding.UTF8.GetByteCount(x) <= JsonProtocol.MaxResponseBytes), "ResponseBound");
                Assert(JsonDocument.Parse(lines[1]).RootElement.GetProperty("Error").GetProperty("Code").GetString() == "DuplicateRequestId", "DuplicateRequestRejected");
                Assert(JsonDocument.Parse(lines[2]).RootElement.GetProperty("Error").GetProperty("Code").GetString() == "MessageTooLarge", "OversizeDrained");
                Assert(!JsonDocument.Parse(lines[3]).RootElement.GetProperty("Ok").GetBoolean(), "UnknownFieldRejected");
                e.ReleaseTask(task);
            }
            // Only self-created synthetic directories; never enumerate real application data.
            var many = Path.Combine(run, "many"); Directory.CreateDirectory(many);
            for (int i = 0; i < 1000; i++) { var d = Path.Combine(many, i.ToString()); Directory.CreateDirectory(d); File.WriteAllText(Path.Combine(d, "fixture.txt"), "synthetic"); }
            string paused;
            using (var e = new InventoryEngine(root))
            {
                paused = e.CreateInventory(many); e.Pause(paused); Wait(e, paused, "Paused");
                Reject(() => e.ReleaseTask(paused), "PausedReleaseRejected");
            }
            TestEvidence.MoveWithManifest(run, Path.Combine(many, "0", "fixture.txt"), Path.Combine(run, "retained-original-fixture.txt")); File.WriteAllText(Path.Combine(many, "new.txt"), "new-generation");
            using (var e = new InventoryEngine(root))
            {
                Assert(Status(e, paused) == "Paused", "RestartPreservesPaused"); e.Resume(paused); Wait(e, paused, "Ready");
                long cursor = 0; bool stale = false, added = false; int count = 0;
                while (true)
                {
                    var page = Json(e.QueryEvidence(paused, cursor, 64, null));
                    foreach (var item in page.GetProperty("Items").EnumerateArray()) { var p = item.GetProperty("Path").GetString(); stale |= p == Path.Combine(many, "0", "fixture.txt"); added |= p == Path.Combine(many, "new.txt"); count++; }
                    if (page.GetProperty("NextAfter").ValueKind == JsonValueKind.Null) break; cursor = page.GetProperty("NextAfter").GetInt64();
                }
                Assert(!stale && added && count == 2001, "ResumeRebuildRefreshesGeneration"); e.ReleaseTask(paused);
                var cancel = e.CreateInventory(many); e.Cancel(cancel); Wait(e, cancel, "Cancelled"); Reject(() => e.Resume(cancel), "CancelledResumeRejected"); e.ReleaseTask(cancel);
                var shutdown = e.CreateInventory(many); checks.Add(new { Name = "ShutdownTask", TaskId = shutdown });
            }
            using (var e = new InventoryEngine(root))
            {
                var acl = new DirectoryInfo(root).GetAccessControl();
                var altered = new DirectoryInfo(root).GetAccessControl();
                altered.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-1-0"), FileSystemRights.Read, AccessControlType.Allow));
                new DirectoryInfo(root).SetAccessControl(altered);
                try { Reject(() => e.GetProgress(paused), "StateAclTamperRejected"); } finally { new DirectoryInfo(root).SetAccessControl(acl); }
                Reject(() => new InventoryEngine(root), "ExclusiveStateLock");
            }
            var unknown = Path.Combine(root, "unknown.file"); File.WriteAllText(unknown, "leave unknown intact");
            Reject(() => new InventoryEngine(root), "UnknownStateFileRejected"); Assert(File.Exists(unknown), "UnknownStateFileNotDeleted");
            var quotaRoot = Path.Combine(localTestRoot, "quota-state");
            using (var e = new InventoryEngine(quotaRoot, new ExplorerLimits(MaxObjectsPerTask: 3)))
            { var task = e.CreateInventory(many); Wait(e, task, "Partial"); Assert(Json(e.GetProgress(task)).GetProperty("Task").GetProperty("Reason").GetString() == "IndexQuotaExceeded", "QuotaPartialNotSuccess"); }
            Assert(new ExplorerLimits().MaxTasks == 0, "DefaultHistoryCountUnlimited");
            var historyRoot = Path.Combine(localTestRoot, "history-state");
            var historyIds = new List<string>();
            using (var e = new InventoryEngine(historyRoot))
            {
                for (int i = 0; i < 65; i++) { var task = e.CreateInventory(files); Wait(e, task, "Partial"); historyIds.Add(task); Thread.Sleep(10); }
                var first = Json(e.ListTasks(null, 64));
                var second = Json(e.ListTasks(first.GetProperty("NextAfterTaskId").GetString(), 64));
                var ids = first.GetProperty("Items").EnumerateArray().Concat(second.GetProperty("Items").EnumerateArray()).Select(x => x.GetProperty("TaskId").GetString()!).ToArray();
                Assert(first.GetProperty("Items").GetArrayLength() == 64 && second.GetProperty("Items").GetArrayLength() == 1 && ids.Distinct().Count() == 65 && ids.ToHashSet().SetEquals(historyIds), "UnlimitedHistoryPagesExact");
            }
            using (var e = new InventoryEngine(historyRoot))
            {
                Assert(Json(e.ListTasks(null, 64)).GetProperty("Items").GetArrayLength() == 64, "HistorySurvivesRestart");
                var task = e.CreateInventory(files); Wait(e, task, "Partial"); Assert(!historyIds.Contains(task), "NewHistoryAfterRestart");
            }
            var bytesRoot = Path.Combine(localTestRoot, "byte-quota-state"); long byteLimit;
            using (var e = new InventoryEngine(bytesRoot)) { byteLimit = Directory.EnumerateFiles(bytesRoot).Sum(p => new FileInfo(p).Length) + 1; }
            using (var e = new InventoryEngine(bytesRoot, new ExplorerLimits(MaxStateBytes: byteLimit)))
            {
                Reject(() => e.CreateInventory(files), "StateByteQuotaStillEnforced");
                Assert(Directory.EnumerateFiles(bytesRoot).Sum(p => new FileInfo(p).Length) <= byteLimit, "StateByteQuotaRejectsBeforeGrowth");
            }
            File.WriteAllText(Path.Combine(run, "result.json"), JsonSerializer.Serialize(new { Passed = true, Assertions = assertions, FixtureRoot = run, CoreSha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(typeof(InventoryEngine).Assembly.Location))), Checks = checks }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"BOUNDARY SELFTEST PASS {assertions} assertions; evidence {run}"); return 0;
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(run, "failure.txt"), ex.ToString()); Console.Error.WriteLine(ex); return 1; }
    }
}
