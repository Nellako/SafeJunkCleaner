using SafeJunkCleaner.Explorer.Analysis;

namespace SafeJunkCleaner.Explorer.Host;

internal static class SuggestionReasons
{
    internal sealed record Reason(string Category, string Code, string Hint);
    internal static Reason For(AnalysisResult result, Suggestion suggestion, bool eligible, bool proofBudget)
    {
        var facts = result.Evidence.Where(e => suggestion.EvidenceIds.Contains(e.EvidenceId)).Select(e => e.Value).ToArray();
        if (eligible) return new("Reviewable", "ExactSetReviewable", "InspectExactListBeforeConfirmation");
        if (proofBudget || suggestion.Doubts.Contains(ProofHashSession.BudgetReason)) return new("Budget", "ProofHashBudgetExceeded", "ChooseSmallerRangeAndReanalyze");
        if (facts.Any(f => f.Contains("Budget", StringComparison.Ordinal)) || suggestion.Doubts.Any(f => f.Contains("Budget", StringComparison.Ordinal))) return new("Budget", "InvestigationBudgetExceeded", "ChooseSmallerRangeAndReanalyze");
        if (facts.Any(f => f.StartsWith("ChromiumSimpleCache", StringComparison.Ordinal)))
        {
            string code = facts.Any(f => f == "ChromiumSimpleCacheRecognized") ? "SimpleCacheStructureOnly" : facts.FirstOrDefault(f => f != "ChromiumSimpleCacheDisplayOnlyNoContentCrc") ?? "SimpleCacheUnproven";
            return new("UnsupportedLayout", code, "StructureNotProcessingAuthorization");
        }
        if (facts.Any(f => f.StartsWith("IncompleteDirectIndex", StringComparison.Ordinal) || f.Contains("PartialIndex", StringComparison.Ordinal) || f == "InventoryCoverageIncomplete")) return new("Coverage", "IncompleteCoverageOrIndex", "ReinventoryAccessibleSmallerRange");
        if (suggestion.Classification is Classification.UserData or Classification.Portable || facts.Any(f => f.Contains("Personal", StringComparison.Ordinal) || f.Contains("Portable", StringComparison.Ordinal))) return new("Protected", "UserDataSourceOrPortable", "KeepProtectedContent");
        if (facts.Any(f => f.Contains("SourceOrPrivateOrPartial", StringComparison.Ordinal))) return new("MixedMembers", "UnexpectedOrProtectedMembers", "KeepWholeMixedGroup");
        if (suggestion.Classification is Classification.InstallerDuplicate or Classification.SpaceOnly) return new("OrganizeOnly", "OrganizationEvidenceNotDisposal", "ReviewManuallyOutsideAutomaticRecycling");
        if (suggestion.HardProtected) return new("Protected", "DeterministicProtection", "KeepProtectedContent");
        return new("UnsupportedLayout", "InsufficientSupportedEvidence", "NoProcessingAuthorization");
    }
}
