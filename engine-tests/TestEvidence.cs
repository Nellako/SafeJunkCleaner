using System.Security.Cryptography;
using System.Text.Json;

// Test-only fixtures and reversible file displacement. Never deletes or invokes Shell.
internal static class TestEvidence
{
    public static string CreateFixture(string parent, string prefix)
    {
        parent = Path.GetFullPath(parent);
        if (!Directory.Exists(parent) || parent == Path.GetPathRoot(parent)) throw new InvalidOperationException("ExplicitExistingEvidenceParentRequired");
        var root = Path.Combine(parent, prefix + "-" + Guid.NewGuid().ToString("D"));
        Directory.CreateDirectory(root);
        File.WriteAllText(Path.Combine(root, ".fixture-owner"), Environment.ProcessId + "|" + root);
        return root;
    }

    public static void MoveWithManifest(string root, string source, string destination)
    {
        root = Path.GetFullPath(root); source = Path.GetFullPath(source); destination = Path.GetFullPath(destination);
        if (File.ReadAllText(Path.Combine(root, ".fixture-owner")) != Environment.ProcessId + "|" + root) throw new InvalidOperationException("FixtureOwnerMismatch");
        foreach (var path in new[] { source, destination })
        {
            if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("MoveOutsideFixture");
            for (var parent = Path.GetDirectoryName(path); parent != null; parent = Path.GetDirectoryName(parent))
            {
                if ((File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("MoveThroughReparsePoint");
                if (string.Equals(parent, root, StringComparison.OrdinalIgnoreCase)) break;
            }
        }
        if (!File.Exists(source) || File.Exists(destination) || Directory.Exists(destination) || (File.GetAttributes(source) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("UnsafeFixtureMove");
        var entry = new { Source = source, Destination = destination, Length = new FileInfo(source).Length, Sha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(source))), CreatedUtc = DateTime.UtcNow, Reversible = true };
        var manifest = Path.Combine(root, "move-manifest-" + Guid.NewGuid().ToString("D") + ".json");
        using (var stream = new FileStream(manifest, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
        {
            JsonSerializer.Serialize(stream, new[] { entry }); stream.Flush(true);
        }
        File.Move(source, destination, false);
    }
}
