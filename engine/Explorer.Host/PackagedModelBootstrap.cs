using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using SafeJunkCleaner.Explorer.Model;

namespace SafeJunkCleaner.Explorer.Host;

internal static class PackagedModelBootstrap
{
    internal static async Task EnsureAsync(CancellationToken token)
    {
        string destination = HostModelBridge.ComponentRoot;
        if (Directory.Exists(destination)) { await new ModelComponent(destination).VerifyAsync(token); return; }
        string source = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "model"));
        await EnsureFromPackageAsync(source, destination, token);
    }
    // Internal seam only; production always supplies its fixed sibling package/cache paths.
    internal static async Task EnsureFromPackageAsync(string source, string destination, CancellationToken token)
    {
        source = WindowsFacts.Canonical(source); destination = WindowsFacts.Canonical(destination);
        string permitted = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SafeJunkCleaner", "ModelComponents");
        if (!WindowsFacts.Within(destination, permitted) || destination == permitted) throw new IOException("BootstrapDestinationNotPrivateModelRoot");
        if (Directory.Exists(destination)) throw new IOException("BootstrapDestinationAlreadyExists");
        if (!Directory.Exists(source)) throw new IOException("PackagedModelNotPresent");
        using var sourceGuard = WindowsFacts.Guard(source);
        string manifestPath = Path.Combine(source, "component-manifest.json");
        var manifestFact = WindowsFacts.Read(manifestPath);
        if (manifestFact.LogicalBytes is <= 0 or > 65536 || (manifestFact.Attributes & WindowsFacts.UnsafeAttributes) != 0 || manifestFact.Links != 1) throw new IOException("UnsafePackagedManifest");
        var manifest = JsonSerializer.Deserialize<ModelComponentManifest>(await File.ReadAllTextAsync(manifestPath, token)) ?? throw new IOException("MissingPackagedManifest");
        if (manifest.SchemaVersion != 1 || manifest.ModelRevision != ModelComponent.Revision || manifest.ModelSha256 != ModelComponent.WeightHash || manifest.RuntimeCommit != ModelComponent.RuntimeCommit || manifest.TemplateSha256 != ModelComponent.TemplateHash || manifest.Files.Length is < 6 or > 100) throw new IOException("PackagedModelVersionMismatch");
        string parent = Path.GetDirectoryName(destination)!; Directory.CreateDirectory(parent); using var parentGuard = WindowsFacts.Guard(parent);
        string temp = Path.Combine(parent, ".bootstrap-" + Guid.NewGuid().ToString("D"));
        var sid = WindowsIdentity.GetCurrent().User!; var acl = new DirectorySecurity(); acl.SetOwner(sid); acl.SetAccessRuleProtection(true, false); acl.AddAccessRule(new(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        FileSystemAclExtensions.CreateDirectory(acl, temp);
        long copied = 0;
        foreach (var file in manifest.Files)
        {
            token.ThrowIfCancellationRequested();
            string from = WindowsFacts.Canonical(Path.GetFullPath(Path.Combine(source, file.Path.Replace('/', '\\'))));
            if (Path.IsPathRooted(file.Path) || !WindowsFacts.Within(from, source) || from == source || file.Sha256.Length != 64) throw new IOException("PackagedModelPathRejected");
            using var guard = WindowsFacts.Guard(Path.GetDirectoryName(from)!); var fact = WindowsFacts.Read(from);
            if ((fact.Attributes & (WindowsFacts.UnsafeAttributes | 16)) != 0 || fact.Links != 1 || fact.LogicalBytes < 0 || copied + fact.LogicalBytes > 2500000000L) throw new IOException("PackagedModelFileRejected");
            string to = Path.Combine(temp, file.Path.Replace('/', '\\')); Directory.CreateDirectory(Path.GetDirectoryName(to)!);
            await using var input = new FileStream(from, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.Asynchronous | FileOptions.SequentialScan);
            await using (var output = new FileStream(to, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1048576, FileOptions.Asynchronous)) await input.CopyToAsync(output, token);
            await using var verify = new FileStream(to, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.Asynchronous);
            if (!Convert.ToHexString(await SHA256.HashDataAsync(verify, token)).Equals(file.Sha256, StringComparison.OrdinalIgnoreCase)) throw new IOException("PackagedModelCopyHashMismatch"); copied += fact.LogicalBytes;
        }
        File.Copy(manifestPath, Path.Combine(temp, "component-manifest.json"), false);
        await new ModelComponent(temp).VerifyAsync(token); // fixed official native/weight/template hashes, not merely manifest self-consistency
        Directory.Move(temp, destination); // destination must still be absent; never overwrite a current component
    }
}
