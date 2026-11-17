using System.Security.Cryptography;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;

namespace SafeJunkCleaner.Explorer.Analysis;

internal sealed partial class ProbeContext(InventoryEvidenceSnapshot snapshot, BudgetMeter meter, CancellationToken cancellation, InventoryIndex? inventoryIndex = null, bool heuristic = false, bool untilComplete = false)
{
    internal InventoryEvidenceSnapshot Snapshot { get; } = snapshot;
    internal BudgetMeter Meter { get; } = meter;
    internal readonly List<AnalysisEvidence> Evidence = [];
    internal readonly List<Suggestion> Suggestions = [];
    private readonly HashSet<string> emitted = [];
    private readonly HashSet<string> evidenceTargets = new(StringComparer.Ordinal);
    private readonly HashSet<string> suggestionTargets = new(StringComparer.Ordinal);
    private readonly HashSet<string> reviewTargets = new(StringComparer.Ordinal);
    private readonly HashSet<string> reviewParents = new(StringComparer.Ordinal);
    private readonly HashSet<string> duplicateHashes = new(StringComparer.Ordinal);
    private readonly HashSet<(string, Classification)> suggested = [];
    private readonly HashSet<(string, Classification)> omittedSuggestions = [];
    private int spaceSuggestions;
    internal bool HasSuggestion(string targetId) => suggestionTargets.Contains(targetId);
    internal bool HasReviewSuggestion(string targetId) => reviewTargets.Contains(targetId);
    internal bool HasReviewChild(string targetId) => reviewParents.Contains(targetId);
    internal int OmittedSuggestionCount => omittedSuggestions.Count;
    private InventoryIndex? index = inventoryIndex;
    private InventoryIndex Index => index ??= new InventoryIndex(Snapshot, Meter);
    private readonly Dictionary<string, byte[]> samples = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> hashes = new(StringComparer.Ordinal);
    private readonly HashSet<string> candidateIdentities = new(StringComparer.Ordinal);
    private readonly HashSet<string> candidateObjects = new(StringComparer.Ordinal);
    internal IEnumerable<InventoryTarget> Descendants(InventoryTarget target) => Index.Descendants(target);
    internal List<InventoryTarget> Children(InventoryTarget target)
    {
        var result = new List<InventoryTarget>();
        foreach (var t in Index.Direct(target)) { cancellation.ThrowIfCancellationRequested(); Meter.Metadata(); result.Add(t); }
        return result;
    }
    internal void Validate(InventoryTarget target) => MetadataAccess.Validate(Snapshot, target, Index, Meter);
    internal string Fact(InventoryTarget target, EvidenceKind kind, string value)
    {
        string key = target.ObjectId + "|" + kind + "|" + value;
        string id = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Snapshot.TaskId + "|" + Snapshot.Revision + "|" + key)))[..24];
        if (emitted.Add(key)) { Evidence.Add(new(id, target.ObjectId, kind, value)); evidenceTargets.Add(target.ObjectId); } return id;
    }
    private bool ProtectedByInventory(InventoryTarget target) => Index.Blocked(target);
    internal byte[] Sample(InventoryTarget target, int maximum)
    {
        cancellation.ThrowIfCancellationRequested();
        if (target.Kind != TargetKind.File || target.LogicalBytes is null || target.LogicalBytes < 0 || maximum is < 0 or > 8192 || Protected(target) || ProtectedByInventory(target)) throw new IOException("SamplingNotAllowed");
        if (heuristic && target.LogicalBytes >= Meter.Limits.LargeFileBytes) throw new IOException("LargeFileMetadataOnly");
        int length = (int)Math.Min(target.LogicalBytes.Value, maximum);
        if (samples.TryGetValue(target.FileIdentity, out var cached) && cached.Length >= length)
        { Validate(target); return cached.AsSpan(0, length).ToArray(); }
        Meter.Sample(length);
        using var guard = MetadataAccess.Guard(Snapshot, target, Index, Meter); using var stream = MetadataAccess.ReadContent(Snapshot, target, Meter);
        byte[] bytes = new byte[length]; stream.ReadExactly(bytes); samples[target.FileIdentity] = bytes; return bytes;
    }
    internal string HashInstaller(InventoryTarget target)
    {
        cancellation.ThrowIfCancellationRequested(); Meter.Check();
        if (Protected(target) || ProtectedByInventory(target) || target.LinkCount != 1 || target.LogicalBytes is null || (heuristic && target.LogicalBytes >= Meter.Limits.LargeFileBytes)) throw new IOException("HashingNotAllowed");
        if (hashes.TryGetValue(target.FileIdentity, out var cached)) { Validate(target); return cached; }
        Meter.Hash(target.LogicalBytes!.Value);
        using var guard = MetadataAccess.Guard(Snapshot, target, Index, Meter); using var stream = MetadataAccess.ReadContent(Snapshot, target, Meter);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256); var buffer = new byte[65536]; long read = 0;
        while (read < target.LogicalBytes)
        {
            cancellation.ThrowIfCancellationRequested(); Meter.Check(); int n = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, target.LogicalBytes.Value - read));
            if (n == 0) throw new IOException("FileChanged"); hash.AppendData(buffer, 0, n); read += n;
        }
        if (stream.ReadByte() != -1) throw new IOException("FileChanged"); var value = Convert.ToHexString(hash.GetHashAndReset()); hashes[target.FileIdentity] = value; return value;
    }
    // Coverage is a separate permission: partial directories can be trusted ancestors only when
    // their own enumeration explicitly completed. They never become candidate targets or files.
    internal static bool AncestorCoverageAllowed(InventoryTarget t) => t.Coverage == Coverage.Complete ||
        t.Kind == TargetKind.Directory && t.Coverage == Coverage.Partial && t.DirectoryEnumerationComplete == true;
    internal static bool Protected(InventoryTarget t) => t.Coverage != Coverage.Complete || HardProtection(t);
    internal static bool HardProtection(InventoryTarget t)
    {
        string name = Path.GetFileName(t.Path).ToLowerInvariant();
        return t.HardProtected || (t.Attributes & (0x400 | 0x1000 | 0x40000 | 0x80000 | 0x400000)) != 0 || name.Contains("backup", StringComparison.Ordinal) || name.Contains("备份", StringComparison.Ordinal) ||
            new[] { ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".pdf", ".jpg", ".jpeg", ".png", ".heic", ".raw", ".dng", ".mp4", ".mov", ".bak", ".backup", ".vhd", ".vhdx", ".db", ".sqlite", ".sqlite3", ".mdb", ".pst" }.Contains(Path.GetExtension(name));
    }
    internal static bool Source(InventoryTarget t) => new[] { ".cs", ".fs", ".vb", ".py", ".ps1", ".sh", ".c", ".h", ".cpp", ".rs", ".go", ".java", ".ts", ".tsx", ".jsx", ".vue", ".sln", ".csproj", ".fsproj", ".vbproj" }.Contains(Path.GetExtension(t.Path).ToLowerInvariant());
    private static bool DotnetGenerated(InventoryTarget t)
    {
        string name = Path.GetFileName(t.Path), ext = Path.GetExtension(t.Path).ToLowerInvariant();
        return ext is ".dll" or ".pdb" or ".cache" || name == "project.assets.json" || name.EndsWith(".deps.json", StringComparison.OrdinalIgnoreCase) || name.EndsWith(".runtimeconfig.json", StringComparison.OrdinalIgnoreCase) || name.EndsWith(".nuget.dgspec.json", StringComparison.OrdinalIgnoreCase);
    }
    private static bool FrontendGenerated(InventoryTarget t, InventoryTarget output)
    {
        if (t.ParentId == output.ObjectId) return Path.GetFileName(t.Path) == "index.html";
        return Path.GetFileName(Path.GetDirectoryName(t.Path)) == "assets" && System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(t.Path), @"^[\w.-]+-[A-Za-z0-9_-]{6,}\.(js|css)$");
    }
    internal bool SafeSet(InventoryTarget target, IReadOnlyList<InventoryTarget> files)
    {
        if (!Index.Get(target).SubtreeComplete || Protected(target) || ProtectedByInventory(target) || files.Count == 0 || files.Any(t => Protected(t) || ProtectedByInventory(t) || Source(t) || t.LinkCount != 1 || t.LogicalBytes is null || (heuristic && t.LogicalBytes >= Meter.Limits.LargeFileBytes))) return false;
        foreach (var t in files) Validate(t);
        return true;
    }
    internal void Suggest(InventoryTarget target, Classification classification, SuggestionLevel level, IEnumerable<InventoryTarget> files, IEnumerable<string> evidence, bool protectedSet, params string[] doubts)
    {
        var key = (target.ObjectId, classification);
        if (suggested.Contains(key)) return;
        // Leave room below Application's 10k result gate. Omission is explicitly summarized by
        // the scheduler; it never changes a candidate set or grants authorization.
        if (heuristic && !untilComplete && (Suggestions.Count >= 9000 || classification == Classification.SpaceOnly && spaceSuggestions >= 128))
        { omittedSuggestions.Add(key); return; }
        var candidates = files.Where(t => t.Kind == TargetKind.File).Select(t => new CandidateFile(t.ObjectId, t.FileIdentity, t.LogicalBytes ?? 0, t.ModifiedUtcTicks)).ToArray();
        // Preserve the entire detector-proven set or reject it BEFORE exact filesystem enumeration.
        // A rejected overlap must not consume the expensive revalidation allowance.
        if (candidates.Length > 0 && (candidates.Select(f => f.FileIdentity).Distinct(StringComparer.Ordinal).Count() != candidates.Length ||
            candidates.Any(f => candidateIdentities.Contains(f.FileIdentity) || candidateObjects.Contains(f.ObjectId))))
        { Fact(target, EvidenceKind.Missing, "CandidateSetOverlapsExistingEvidence"); return; }
        if (candidates.Length > 0 && (Protected(target) || ProtectedByInventory(target) || !Index.Get(target).SubtreeComplete))
            throw new IOException("IncompleteOrProtectedCandidateSubtree");
        if (heuristic && candidates.Length > 0)
        {
            using var guard = MetadataAccess.Guard(Snapshot, target, Index, Meter);
            var expected = candidates.Select(f => f.ObjectId).ToHashSet(StringComparer.Ordinal);
            var pending = new Stack<InventoryTarget>(); pending.Push(target);
            while (pending.TryPop(out var directory))
            {
                Validate(directory);
                foreach (var path in Directory.EnumerateFileSystemEntries(directory.Path))
                {
                    Meter.Metadata(); var observed = Index.AtPath(path);
                    if (observed == null || observed.ParentId != directory.ObjectId) throw new IOException("ExactOutputMembershipChanged");
                    Validate(observed);
                    if (observed.Kind == TargetKind.Directory) pending.Push(observed);
                    else if (!expected.Remove(observed.ObjectId)) throw new IOException("UnexpectedOutputMember");
                }
            }
            if (expected.Count != 0) throw new IOException("MissingOutputMember");
        }
        var refs = evidence.Distinct().ToArray();
        foreach (var f in candidates) { candidateIdentities.Add(f.FileIdentity); candidateObjects.Add(f.ObjectId); }
        var id = "suggest-" + target.ObjectId + "-" + classification;
        string impact = classification switch
        {
            Classification.BuildArtifact => "Exact generated output files only; removing them would require a rebuild/redeployment and may break launch until rebuilt; project/source excluded",
            Classification.Cache => "Exact recognized cache files only; future removal may cause cache regeneration, slower first load or loss of offline cached resources; application must be closed",
            Classification.UserData or Classification.Mixed => "Personal/source/database/backup or incomplete mixture; display only, no processing candidates",
            Classification.Portable => "Portable executable and settings may be the complete application; display only, not abandoned residue",
            _ => "Space organization display only; size does not establish disposability"
        };
        suggested.Add(key);
        if (classification == Classification.SpaceOnly) spaceSuggestions++;
        var suggestion = new Suggestion(id, target.ObjectId, classification, level, candidates, refs, doubts, impact, protectedSet);
        Suggestions.Add(suggestion); suggestionTargets.Add(target.ObjectId);
        if (suggestion.MayPrepareForReview)
        {
            reviewTargets.Add(target.ObjectId);
            if (target.ParentId != null) reviewParents.Add(target.ParentId);
        }
    }
    internal void Run(ExplorationAction action, InventoryTarget target)
    {
        Meter.Check(); Validate(target);
        switch (action)
        {
            case ExplorationAction.InspectLayout: Layout(target); break;
            case ExplorationAction.InspectOwnership: Ownership(target); break;
            case ExplorationAction.InspectDuplicates: Duplicates(target); break;
            default: throw new InvalidOperationException("NotAProbe");
        }
    }
    private void Layout(InventoryTarget target)
    {
        // Run has already revalidated the real target and every ancestor. A direct-index gap is
        // diagnostic-only: do not copy children, walk descendants, open members or propose a set.
        var summary = Index.Get(target);
        if (heuristic && summary.IncompleteDirectIndexDiagnostic)
        {
            Fact(target, EvidenceKind.Missing,
                $"IncompleteDirectIndexMetadataOnly;IndexedDirectObjects={summary.IndexedDirectObjects};ExpectedDirectObjects={summary.ExpectedDirectObjects};OmittedDirectObjects={summary.ExpectedDirectObjects - summary.IndexedDirectObjects};NoProcessingAuthorization");
            return;
        }
        if (target.Kind == TargetKind.File)
        {
            if (ProtectedByInventory(target) || Protected(target)) { var p = Fact(target, EvidenceKind.Protection, "PersonalOrDatabaseMetadataOnly"); Suggest(target, Classification.UserData, SuggestionLevel.OrganizeOpportunity, [], [p], true, "Never classify protected data as cache"); }
            else if (target.LogicalBytes >= Meter.Limits.LargeFileBytes) { var p = Fact(target, EvidenceKind.Space, "LargeObservedFile"); Suggest(target, Classification.SpaceOnly, SuggestionLevel.OrganizeOpportunity, [], [p], true, "Space does not imply junk"); }
            return;
        }
        // Simple cache is an independent, display-only format probe. Its complete-scope gate
        // must run before any manifest/legacy cache sampling in this directory.
        if (summary.SimpleCache) { SimpleCacheLayout(target); return; }
        // Summaries already ruled out all supported layouts. Unknown branches still get a fair
        // metadata-only action, but do not pay again to copy their direct membership. Large files
        // and protected children have their own scheduler work/summary; clues never grant safety.
        var children = heuristic && !Index.Get(target).LayoutClue ? new List<InventoryTarget>() : Children(target);
        // The heuristic scheduler explores descendants independently. Do not re-enumerate the whole
        // subtree for each ancestor; only the exact output under review needs a descendant walk.
        var descendants = heuristic ? children : Descendants(target).ToList();
        var files = descendants.Where(t => t.Kind == TargetKind.File).ToList();
        var personal = files.Where(Protected).ToList();
        if (personal.Count > 0 || (ProtectedByInventory(target) && !Index.Get(target).Portable) || (heuristic && (Index.Get(target).PrivateFiles > 0 || Index.Get(target).SourceFiles > 0)))
        {
            var p = Fact(target, EvidenceKind.Protection, "PersonalDatabaseBackupOrIncompleteMixed");
            var refs = new List<string> { p };
            if (target.Coverage != Coverage.Complete || !Index.Get(target).DirectComplete) refs.Add(Fact(target, EvidenceKind.Missing, "InventoryCoverageIncomplete"));
            Suggest(target, Classification.Mixed, SuggestionLevel.OrganizeOpportunity, [], refs, true, "Private data/incomplete coverage blocks processing");
        }
        if (Index.Get(target).Portable)
        {
            var p = Fact(target, EvidenceKind.Protection, "PortableExecutableAndPortableMarker");
            Suggest(target, Classification.Portable, SuggestionLevel.OrganizeOpportunity, [], [p], true, "Portable layout is not abandoned software"); return;
        }
        if (ProtectedByInventory(target)) return;
        bool portable = children.Any(t => t.Kind == TargetKind.File && Path.GetExtension(t.Path).Equals(".exe", StringComparison.OrdinalIgnoreCase)) && children.Any(t => Path.GetFileName(t.Path).Equals("portable.ini", StringComparison.OrdinalIgnoreCase) || Path.GetFileName(t.Path).Equals("portable.dat", StringComparison.OrdinalIgnoreCase));
        if (portable)
        {
            var p = Fact(target, EvidenceKind.Protection, "PortableExecutableAndPortableMarker"); Suggest(target, Classification.Portable, SuggestionLevel.OrganizeOpportunity, [], [p], true, "Portable layout is not abandoned software"); return;
        }
        foreach (var f in files.Where(t => t.LogicalBytes >= Meter.Limits.LargeFileBytes))
        {
            var p = Fact(f, EvidenceKind.Space, "LargeObservedFile"); Suggest(f, Classification.SpaceOnly, SuggestionLevel.OrganizeOpportunity, [], [p], true, "Large file is display only");
        }
        var project = children.FirstOrDefault(t => t.Kind == TargetKind.File && new[] { ".csproj", ".fsproj", ".vbproj" }.Contains(Path.GetExtension(t.Path).ToLowerInvariant()));
        if (project != null && (!heuristic || !ProtectedByInventory(project)) &&
            children.Any(t => t.Kind == TargetKind.Directory && Path.GetFileName(t.Path) is "bin" or "obj") && ValidDotnetProject(project))
        {
            var projectFact = Fact(target, EvidenceKind.Layout, "DotNetProjectSdkMarkerNotOutput");
            foreach (var output in children.Where(t => t.Kind == TargetKind.Directory && Path.GetFileName(t.Path) is "bin" or "obj"))
            {
                var set = (heuristic ? Descendants(output) : descendants.Where(t => MetadataAccess.Within(t.Path, output.Path))).Where(t => t.Kind == TargetKind.File).ToList();
                bool outputMarker = set.Any(t => Path.GetFileName(t.Path) == "project.assets.json" || t.Path.EndsWith(".deps.json", StringComparison.OrdinalIgnoreCase) || t.Path.EndsWith(".runtimeconfig.json", StringComparison.OrdinalIgnoreCase)) && set.Any(t => Path.GetExtension(t.Path) is ".dll" or ".cache" || Path.GetFileName(t.Path) == "project.assets.json");
                if (!outputMarker) { Fact(output, EvidenceKind.Missing, "DotNetOutputMarkersMissing"); continue; }
                var marker = Fact(output, EvidenceKind.Layout, "DotNetGeneratedOutputMarkers"); bool safe = SafeSet(output, set) && set.All(DotnetGenerated);
                var protection = Fact(output, safe ? EvidenceKind.Layout : EvidenceKind.Protection, safe ? "ExactOutputFilesNoSource" : "SourceOrPrivateOrPartialInOutput");
                Suggest(output, safe ? Classification.BuildArtifact : Classification.Mixed, safe ? SuggestionLevel.ReviewSuggested : SuggestionLevel.OrganizeOpportunity, safe ? set : [], [projectFact, marker, protection], !safe, "Build may be required again; no execution/project evaluation performed");
            }
        }
        var package = children.FirstOrDefault(t => Path.GetFileName(t.Path) == "package.json" && t.Kind == TargetKind.File);
        if (package != null && children.Any(t => t.Kind == TargetKind.Directory && Path.GetFileName(t.Path) == "dist") && FrontendBuildMarker(package))
        {
            var p = Fact(target, EvidenceKind.Layout, "PackageViteOrTscBuildMarkerNotOutput");
            foreach (var output in children.Where(t => t.Kind == TargetKind.Directory && Path.GetFileName(t.Path) == "dist"))
            {
                var set = (heuristic ? Descendants(output) : descendants.Where(t => MetadataAccess.Within(t.Path, output.Path))).Where(t => t.Kind == TargetKind.File).ToList();
                bool generated = set.Any(t => Path.GetFileName(t.Path) == "index.html") && set.Any(t => Path.GetFileName(Path.GetDirectoryName(t.Path)) == "assets" && System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(t.Path), @"^[\w.-]+-[A-Za-z0-9_-]{6,}\.(js|css)$"));
                if (!generated) { Fact(output, EvidenceKind.Missing, "DistGeneratedMarkersMissing"); continue; }
                var m = Fact(output, EvidenceKind.Layout, "DistIndexAndHashedAssets"); bool safe = SafeSet(output, set) && set.All(t => FrontendGenerated(t, output));
                Suggest(output, safe ? Classification.BuildArtifact : Classification.Mixed, safe ? SuggestionLevel.ReviewSuggested : SuggestionLevel.OrganizeOpportunity, safe ? set : [], [p, m], !safe, "Restricted dist evidence only; custom scripts never executed");
            }
        }
        // Chromium legacy block cache layout works at custom names/locations.
        bool chromium = children.Any(t => Path.GetFileName(t.Path) == "index" && t.Kind == TargetKind.File) && Enumerable.Range(0, 4).All(i => children.Any(t => Path.GetFileName(t.Path) == "data_" + i && t.Kind == TargetKind.File)) && children.Any(t => System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(t.Path), "^f_[0-9a-fA-F]{6,}$") && t.Kind == TargetKind.File);
        if (chromium)
        {
            var p = Fact(target, EvidenceKind.Layout, "ChromiumBlockIndexData0To3AndEntry");
            bool structurallySafe = personal.Count == 0 && (!heuristic || children.All(t => t.Kind == TargetKind.File)) && descendants.All(t => t.ParentId == target.ObjectId) && files.All(t => Path.GetFileName(t.Path) == "index" || System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(t.Path), "^(data_[0-3]|f_[0-9a-fA-F]{6,})$")) && SafeSet(target, files);
            if (!structurallySafe)
            {
                var denied = Fact(target, EvidenceKind.Protection, "SourceOrPrivateOrPartialInCache");
                Suggest(target, Classification.Mixed, SuggestionLevel.OrganizeOpportunity, [], [p, denied], true,
                    "Counterexample rejects the complete set before any cache content read"); return;
            }
            var index = children.First(t => Path.GetFileName(t.Path) == "index"); var header = Sample(index, 8);
            if (header.Length >= 4 && header.AsSpan(0, 4).SequenceEqual(new byte[] { 0xc3, 0xca, 0x03, 0xc1 }))
            {
                var h = Fact(target, EvidenceKind.Layout, "ChromiumIndexHeaderMagic");
                bool safe = structurallySafe;
                Suggest(target, safe ? Classification.Cache : Classification.Mixed, safe ? SuggestionLevel.ReviewSuggested : SuggestionLevel.OrganizeOpportunity, safe ? files : [], [p, h], !safe, "Application may still depend on live cache; close and revalidate before future approval");
            }
            else Fact(target, EvidenceKind.Missing, "ChromiumIndexHeaderMismatch");
        }
        if (!evidenceTargets.Contains(target.ObjectId)) Fact(target, EvidenceKind.Missing, "InsufficientLayoutEvidence");
    }
    private bool ValidDotnetProject(InventoryTarget project)
    {
        if (project.LogicalBytes > 8192) return false;
        var bytes = Sample(project, 8192);
        try
        {
            using var reader = XmlReader.Create(new MemoryStream(bytes), new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 8192 });
            var xml = XDocument.Load(reader); return xml.Root?.Name.LocalName == "Project" && xml.Root.Attribute("Sdk")?.Value.StartsWith("Microsoft.NET.Sdk", StringComparison.Ordinal) == true;
        }
        catch (XmlException) { return false; }
    }
    private bool FrontendBuildMarker(InventoryTarget package)
    {
        if (package.LogicalBytes > 8192) return false;
        try
        {
            using var json = JsonDocument.Parse(Sample(package, 8192), new JsonDocumentOptions { MaxDepth = 12 });
            return json.RootElement.TryGetProperty("scripts", out var scripts) && scripts.ValueKind == JsonValueKind.Object && scripts.TryGetProperty("build", out var build) && build.ValueKind == JsonValueKind.String && build.GetString() is "vite build" or "tsc && vite build";
        }
        catch (JsonException) { return false; }
    }
    private void Ownership(InventoryTarget target)
    {
        using var guard = MetadataAccess.Guard(Snapshot, target, Index, Meter);
        Fact(target, EvidenceKind.Ownership, MetadataAccess.OwnedByCurrentUser(target) ? "CurrentUserOwnsObjectNotCleanupAuthorization" : "OtherOwnerNotCleanupAuthorization");
    }
    private bool PackageHeader(InventoryTarget file)
    {
        var ext = Path.GetExtension(file.Path).ToLowerInvariant();
        if (ext is not (".zip" or ".msi")) return false;
        var bytes = Sample(file, 8);
        return ext == ".zip" ? bytes.Length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b && bytes[2] is 3 or 5 or 7 && bytes[3] is 4 or 6 or 8 : bytes.AsSpan().SequenceEqual(new byte[] { 0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1 });
    }
    private void Duplicates(InventoryTarget target)
    {
        if (Protected(target) || ProtectedByInventory(target) || !Index.Get(target).SubtreeComplete)
        { Fact(target, EvidenceKind.Missing, "IncompleteOrProtectedDuplicateScope"); return; }
        var files = (target.Kind == TargetKind.Directory ? Descendants(target) : [target]).Where(t => t.Kind == TargetKind.File && !Protected(t) && !ProtectedByInventory(t) && t.LinkCount == 1 && t.LogicalBytes > 0 && (!heuristic || t.LogicalBytes < Meter.Limits.LargeFileBytes) && Path.GetExtension(t.Path).ToLowerInvariant() is ".zip" or ".msi").ToList();
        bool found = false;
        foreach (var sizeGroup in files.GroupBy(t => t.LogicalBytes).Where(g => g.Select(t => t.FileIdentity).Distinct().Count() > 1))
        {
            var hashes = new Dictionary<string, List<InventoryTarget>>();
            foreach (var file in sizeGroup)
            {
                if (!PackageHeader(file)) continue;
                var hash = HashInstaller(file); if (!hashes.TryGetValue(hash, out var set)) hashes[hash] = set = []; set.Add(file);
            }
            foreach (var pair in hashes.Where(p => p.Value.Select(t => t.FileIdentity).Distinct().Count() > 1))
            {
                var set = pair.Value;
                // Confirm every retained/candidate copy still matches Inventory, not merely same hash once.
                foreach (var file in set) Validate(file);
                if (duplicateHashes.Contains(pair.Key)) { found = true; continue; }
                var p = Fact(target, EvidenceKind.Duplicate, "PackageSizeHeaderAndFullSha256Equal"); var retained = set.OrderBy(t => t.ObjectId, StringComparer.Ordinal).First();
                var r = Fact(retained, EvidenceKind.Duplicate, "RetainedCopyIdentityAndMetadataReconfirmed");
                var candidates = set.Where(t => t.ObjectId != retained.ObjectId).Select(t => new CandidateFile(t.ObjectId, t.FileIdentity, t.LogicalBytes!.Value, t.ModifiedUtcTicks, pair.Key)).ToArray();
                var keeper = new CandidateFile(retained.ObjectId, retained.FileIdentity, retained.LogicalBytes!.Value, retained.ModifiedUtcTicks, pair.Key);
                Suggestions.Add(new("duplicate-" + pair.Key[..24], target.ObjectId, Classification.InstallerDuplicate,
                    SuggestionLevel.OrganizeOpportunity, candidates, [p, r],
                    ["Retained copy is an unconfirmed display choice, not user approval", "Generic archives may hold private data; MSI compound header alone is not package provenance; organize only"],
                    "Exact duplicate copies only; no delete/recycle authorization", true, false, new(pair.Key, [keeper])));
                duplicateHashes.Add(pair.Key); suggestionTargets.Add(target.ObjectId); found = true;
            }
        }
        if (!found) Fact(target, EvidenceKind.Missing, "NoVerifiedPackageDuplicates");
    }
}
