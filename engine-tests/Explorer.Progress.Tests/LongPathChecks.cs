using System.Runtime.InteropServices;
using System.Text.Json;
using SafeJunkCleaner.Explorer;

internal static class LongPathChecks
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLink(string file, string existing, IntPtr security);

    internal static void Run(string root, Action<bool, string> check)
    {
        string tree = Path.Combine(root, "long-tree"), nested = tree;
        Directory.CreateDirectory(tree);
        while (nested.Length < 280) nested = Path.Combine(nested, "nested");
        Directory.CreateDirectory(nested);
        string file = Path.Combine(nested, "kept.tmp"), link = Path.Combine(nested, "other.tmp");
        File.WriteAllText(file, "artificial long path");
        check(CreateHardLink(@"\\?\" + link, @"\\?\" + file, IntPtr.Zero), "Owned long-path hard link created");
        var fact = WindowsFacts.Read(file);
        check(file.Length > 260 && WindowsFacts.Read(link).Identity == fact.Identity && fact.Links == 2, "Long-path metadata preserves hard-link identity");
        using (WindowsFacts.Guard(nested))
        {
            bool rejected = false;
            try { using var guard = WindowsFacts.Guard(nested, "wrong-identity"); }
            catch (InvalidOperationException ex) when (ex.Message == "DirectoryIdentityChanged") { rejected = true; }
            check(rejected, "Long-path Guard rejects changed directory identity");
            check(WindowsFacts.Read(nested).Identity.Length > 0, "Long-path directory remains identifiable while guarded");
        }
        foreach (string input in new[] { @"\\?\E:\unsafe", @"\\.\E:\unsafe", @"\\server\share", "relative", @"E:\tree\..\escape", @"E:\tree\file:stream", @"E:\trailing.\file" })
        {
            bool rejected = false;
            try { WindowsFacts.Read(input); }
            catch (InvalidOperationException ex) when (ex.Message is "UnsupportedPath" or "NonCanonicalPath") { rejected = true; }
            check(rejected, "Public metadata input rejects device or noncanonical syntax");
        }
        using var engine = new InventoryEngine(Path.Combine(root, "long-state"));
        string task = engine.CreateInventory(tree);
        var end = DateTime.UtcNow.AddSeconds(30);
        JsonElement progress;
        do
        {
            Thread.Sleep(5);
            progress = JsonSerializer.SerializeToElement(engine.GetProgress(task));
        } while (progress.GetProperty("Task").GetProperty("State").GetString() == "Inventory" && DateTime.UtcNow < end);
        check(progress.GetProperty("Task").GetProperty("State").GetString() == "Ready", "Actual long-path inventory is complete");
        check(progress.GetProperty("Coverage").GetProperty("SkippedObjects").GetInt64() == 0, "Long path does not become unknown metadata");
        check(progress.GetProperty("Coverage").GetProperty("ObservedLogicalBytes").GetInt64() == fact.LogicalBytes, "Actual hard-link progress bytes are deduplicated");
        check(File.ReadAllText(file) == "artificial long path" && File.ReadAllText(link) == "artificial long path", "Both owned long-path inputs retained unchanged");
    }
}
