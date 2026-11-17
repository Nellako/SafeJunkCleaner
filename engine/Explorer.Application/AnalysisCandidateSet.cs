using SafeJunkCleaner.Explorer.Analysis;

namespace SafeJunkCleaner.Explorer.Application;

// The same canonical set is used for Host display and execution source mapping.
// Deduplication never changes a classification or promotes a protected category.
public static class AnalysisCandidateSet
{
    public const string Sort = "review-logical-desc-stableid-v1";
    public static int ReviewRank(Suggestion suggestion) => suggestion.MayPrepareForReview && suggestion.Classification is Classification.Cache or Classification.BuildArtifact ? 0
        : suggestion.Level == SuggestionLevel.OrganizeOpportunity ? 1 : 2;
    public static long LogicalBytes(Suggestion suggestion) => checked(suggestion.CandidateFiles.Sum(f => f.LogicalBytes));
    // Shared by display normalization and approval-source mapping. Ancestor trust is deliberately
    // separate from candidate eligibility: Partial+true never appears in the returned set.
    public static HashSet<string> GetUsableTargets(InventoryEvidenceSnapshot snapshot)
    {
        var privateExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".pdf", ".jpg", ".jpeg", ".png", ".heic", ".raw", ".dng", ".mp4", ".mov", ".bak", ".backup", ".vhd", ".vhdx", ".db", ".sqlite", ".sqlite3", ".mdb", ".pst" };
        var portableMarkers = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var target in snapshot.Targets.Values)
        {
            if (target.ParentId == null) continue;
            string name = Path.GetFileName(target.Path);
            int marker = target.Kind == TargetKind.File && Path.GetExtension(name).Equals(".exe", StringComparison.OrdinalIgnoreCase) ? 1 : 0;
            if (name.Equals("portable.ini", StringComparison.OrdinalIgnoreCase) || name.Equals("portable.dat", StringComparison.OrdinalIgnoreCase)) marker |= 2;
            if (marker != 0) portableMarkers[target.ParentId] = portableMarkers.GetValueOrDefault(target.ParentId) | marker;
        }
        var usableAncestors = new HashSet<string>(StringComparer.Ordinal);
        var usableCandidates = new HashSet<string>(StringComparer.Ordinal);
        foreach (var target in snapshot.Targets.Values.OrderBy(t => t.Path.Length))
        {
            string name = Path.GetFileName(target.Path);
            if (target.HardProtected || (target.Attributes & WindowsFacts.UnsafeAttributes) != 0
                || name.Contains("backup", StringComparison.OrdinalIgnoreCase) || name.Contains("备份", StringComparison.Ordinal)
                || privateExtensions.Contains(Path.GetExtension(name)) || portableMarkers.GetValueOrDefault(target.ObjectId) == 3
                || target.ParentId != null && !usableAncestors.Contains(target.ParentId)) continue;
            if (target.Kind == TargetKind.Directory && (target.Coverage == Coverage.Complete
                || target.Coverage == Coverage.Partial && target.DirectoryEnumerationComplete == true)) usableAncestors.Add(target.ObjectId);
            if (target.Coverage == Coverage.Complete) usableCandidates.Add(target.ObjectId);
        }
        return usableCandidates;
    }
    public static AnalysisResult Normalize(AnalysisResult result, InventoryEvidenceSnapshot snapshot)
    {
        if (result.TaskId != snapshot.TaskId || result.Revision != snapshot.Revision
            || result.Suggestions.Select(s => s.SuggestionId).Distinct(StringComparer.Ordinal).Count() != result.Suggestions.Count
            || result.Evidence.Select(e => e.EvidenceId).Distinct(StringComparer.Ordinal).Count() != result.Evidence.Count
            || result.Suggestions.Sum(s => (long)s.CandidateFiles.Count + (s.Duplicate?.RetainedFiles.Count ?? 0)) > InventorySnapshotAdapter.MaximumObjects)
            throw new InvalidOperationException("InvalidAnalysisSnapshot");
        var evidence = result.Evidence.ToDictionary(e => e.EvidenceId, StringComparer.Ordinal);
        if (evidence.Values.Any(e => !snapshot.Targets.ContainsKey(e.TargetId))) throw new InvalidOperationException("EvidenceTargetNotInInventory");
        foreach (var s in result.Suggestions)
        {
            if (string.IsNullOrWhiteSpace(s.SuggestionId) || !snapshot.Targets.TryGetValue(s.TargetId, out var target) || s.EvidenceIds.Any(id => !evidence.ContainsKey(id))) throw new InvalidOperationException("UnboundSuggestionEvidence");
            foreach (var f in s.CandidateFiles.Concat(s.Duplicate?.RetainedFiles ?? []))
            {
                if (!snapshot.Targets.TryGetValue(f.ObjectId, out var item) || item.Kind != TargetKind.File || item.LogicalBytes == null
                    || item.FileIdentity != f.FileIdentity || item.LogicalBytes != f.LogicalBytes || item.ModifiedUtcTicks != f.ModifiedUtcTicks
                    || f.ContentSha256 != null && (f.ContentSha256.Length != 64 || !f.ContentSha256.All(Uri.IsHexDigit))) throw new InvalidOperationException("CandidateDoesNotMatchInventory");
            }
            if (s.CandidateFiles.Any(f => !WindowsFacts.Within(snapshot.Targets[f.ObjectId].Path, target.Path))) throw new InvalidOperationException("CandidateOutsideSuggestionTarget");
            if (s.Duplicate != null)
            {
                var d = s.Duplicate;
                if (d.RetainedFiles.Count == 0 || d.ContentSha256.Length != 64 || !d.ContentSha256.All(Uri.IsHexDigit)
                    || s.CandidateFiles.Concat(d.RetainedFiles).Any(f => f.ContentSha256 == null || !f.ContentSha256.Equals(d.ContentSha256, StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("MissingDuplicateProof");
                var candidateIds = s.CandidateFiles.Select(f => f.FileIdentity).ToHashSet(StringComparer.Ordinal);
                if (d.RetainedFiles.Any(f => candidateIds.Contains(f.FileIdentity))) throw new InvalidOperationException("OverlappingCandidateOrKeeperSet");
            }
        }
        var usableCandidates = GetUsableTargets(snapshot);
        var normalizedInput = result.Suggestions.Select(s => s with
        {
            HardProtected = s.HardProtected || !usableCandidates.Contains(s.TargetId) || s.CandidateFiles.Any(f => !usableCandidates.Contains(f.ObjectId)
                || snapshot.Targets[f.ObjectId].LinkCount != 1 || (snapshot.Targets[f.ObjectId].Attributes & 1) != 0)
        });
        var usedObjects = new HashSet<string>(StringComparer.Ordinal);
        var usedIdentities = new HashSet<string>(StringComparer.Ordinal);
        var suggestions = new List<Suggestion>();
        foreach (var s in normalizedInput.OrderBy(ReviewRank).ThenByDescending(LogicalBytes).ThenBy(s => s.SuggestionId, StringComparer.Ordinal))
        {
            var ownObjects = new Dictionary<string, CandidateFile>(StringComparer.Ordinal);
            var ownIdentities = new HashSet<string>(StringComparer.Ordinal);
            var files = new List<CandidateFile>();
            bool review = ReviewRank(s) == 0, overlap = false;
            foreach (var f in s.CandidateFiles.OrderBy(f => f.ObjectId, StringComparer.Ordinal))
            {
                if (ownObjects.TryGetValue(f.ObjectId, out var previous)) { if (previous != f) throw new InvalidOperationException("ConflictingCandidateReference"); continue; }
                ownObjects.Add(f.ObjectId, f);
                if (!ownIdentities.Add(f.FileIdentity) || usedObjects.Contains(f.ObjectId) || usedIdentities.Contains(f.FileIdentity)) overlap = true;
                files.Add(f);
            }
            // A probe establishes a proof for the WHOLE exact subset. Never turn
            // overlapping build/cache groups into an arbitrary remainder subset.
            if (review && overlap) continue;
            if (review)
            {
                foreach (var f in files) { usedObjects.Add(f.ObjectId); usedIdentities.Add(f.FileIdentity); }
            }
            suggestions.Add(s with { CandidateFiles = files.ToArray(), SelectedByDefault = false });
        }
        return result with { Suggestions = suggestions.ToArray() };
    }
}
