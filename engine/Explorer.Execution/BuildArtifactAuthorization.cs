using System.Security.Cryptography;
using System.Xml;
using System.Xml.Linq;

namespace SafeJunkCleaner.Explorer.Execution;

// Host composition-root capability backed by the current owned task/analysis index, never UI/model JSON.
// ReadCurrent must recheck task/scope/policy/suggestion revisions on EVERY read; stale registrations are not authority.
public interface ITrustedBuildArtifactAuthorizations
{
    BuildArtifactAuthorization? ReadCurrent(string canonicalPath);
}
public sealed record BuildArtifactAuthorization(ApprovalSource CurrentSource, string SuggestionId, FileSnapshot Candidate,
    string ProjectRoot, FileSnapshot ProjectMarker, string OutputEvidenceId, bool TrustedIndexClassifiedBuildArtifact = false);

internal static class BuildArtifactDllException
{
    internal static bool Allows(string path, string ownerSid, ITrustedBuildArtifactAuthorizations? authorizations)
    {
        if (authorizations == null || !Path.GetExtension(path).Equals(".dll", StringComparison.OrdinalIgnoreCase)) return false;
        try
        {
            var proof = authorizations.ReadCurrent(path);
            if (proof == null || !proof.TrustedIndexClassifiedBuildArtifact) return false;
            var source = proof.CurrentSource;
            if (source.OwnerSid != ownerSid || !Guid.TryParseExact(source.TaskId, "D", out _) || !Guid.TryParseExact(source.ScopeId, "D", out _)
                || string.IsNullOrWhiteSpace(source.ScopeRevision) || string.IsNullOrWhiteSpace(source.PolicyRevision) || string.IsNullOrWhiteSpace(source.SuggestionRevision)) return false;
            var candidate = proof.Candidate;
            var project = WindowsFacts.Canonical(proof.ProjectRoot);
            if (!candidate.Path.Equals(path, StringComparison.OrdinalIgnoreCase) || !source.Roots.Any(root => WindowsFacts.Canonical(root) == root && WindowsFacts.Within(project, root))) return false;
            var relative = Path.GetRelativePath(project, path).Split(Path.DirectorySeparatorChar);
            if (relative.Length < 2 || !(relative[0].Equals("bin", StringComparison.OrdinalIgnoreCase) || relative[0].Equals("obj", StringComparison.OrdinalIgnoreCase))) return false;
            var group = source.Suggestions.Single(s => s.SuggestionId == proof.SuggestionId);
            if (group.HardProtected || group.Classification is not (ProcessingClass.ReviewSuggested or ProcessingClass.VerifiedCache)
                || !group.Files.Contains(candidate) || !group.EvidenceIds.Contains(proof.OutputEvidenceId) || string.IsNullOrWhiteSpace(proof.OutputEvidenceId)) return false;
            var marker = proof.ProjectMarker;
            if (!string.Equals(Path.GetDirectoryName(marker.Path), project, StringComparison.OrdinalIgnoreCase)
                || Path.GetExtension(marker.Path).ToLowerInvariant() is not (".csproj" or ".fsproj" or ".vbproj") || marker.Size is <= 0 or > 65536) return false;
            using var candidateGuard = WindowsFacts.Guard(Path.GetDirectoryName(path)!);
            using var markerGuard = WindowsFacts.Guard(project);
            WindowsFacts.LocalVolume(path);
            using var markerStream = OpenVerified(marker);
            using var reader = XmlReader.Create(markerStream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 65536 });
            var xml = XDocument.Load(reader);
            var sdk = xml.Root?.Attribute("Sdk")?.Value;
            if (xml.Root?.Name.LocalName != "Project" || sdk == null || !(sdk == "Microsoft.NET.Sdk" || sdk.StartsWith("Microsoft.NET.Sdk.", StringComparison.Ordinal))) return false;
            using var candidateStream = OpenVerified(candidate);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or XmlException or System.ComponentModel.Win32Exception)
        { return false; }
    }
    private static FileStream OpenVerified(FileSnapshot expected)
    {
        if (expected.ContentSha256 is not { Length: 64 } || !expected.ContentSha256.All(Uri.IsHexDigit)) throw new InvalidOperationException("BuildAuthorizationRequiresHash");
        var before = WindowsFacts.Read(expected.Path);
        if ((before.Attributes & (WindowsFacts.UnsafeAttributes | 16 | 1 | 0x200)) != 0 || before.Links != 1 || before.Identity != expected.Identity
            || before.LogicalBytes != expected.Size || before.ModifiedUtc != expected.ModifiedUtc) throw new InvalidOperationException("BuildAuthorizationChanged");
        var stream = new FileStream(expected.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
        try
        {
            var hash = Convert.ToHexString(SHA256.HashData(stream));
            if (hash != expected.ContentSha256.ToUpperInvariant() || WindowsFacts.Read(expected.Path) != before) throw new InvalidOperationException("BuildAuthorizationHashChanged");
            stream.Position = 0; return stream;
        }
        catch { stream.Dispose(); throw; }
    }
}
