namespace SafeJunkCleaner.Explorer.Analysis;

// A single charged inventory pass builds adjacency and summaries. Descendant walks never scan Targets.
internal sealed class InventoryIndex
{
    private readonly Dictionary<string, List<InventoryTarget>> children = new(StringComparer.Ordinal);
    private readonly Dictionary<string, InventoryTarget> paths = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Summary> summaries = new(StringComparer.Ordinal);
    private readonly Dictionary<string, bool> blocked = new(StringComparer.Ordinal);
    private readonly BudgetMeter meter;
    internal sealed class Summary
    {
        internal long Bytes;
        internal int Files, Directories, PrivateFiles, SourceFiles, PackageFiles;
        internal bool Portable, Project, Package, Chromium, SimpleCache, DuplicateSizes, DotnetOutput, FrontendOutput;
        internal bool DirectComplete, SubtreeComplete, IncompleteDirectIndexDiagnostic;
        internal int ExpectedDirectObjects, IndexedDirectObjects;
        internal bool LayoutClue => Chromium || SimpleCache || Project && DotnetOutput || Package && FrontendOutput;
    }
    internal bool Complete { get; }
    internal int IndexedObjects => summaries.Count;
    internal InventoryIndex(InventoryEvidenceSnapshot snapshot, BudgetMeter meter, InventoryTarget? selectedRoot = null, int? indexLimit = null)
    {
        this.meter = meter;
        // Count only trusted snapshot parent references, including omitted rows. This performs no
        // filesystem/content reads and does not ingest omitted members into the charged index.
        var expectedChildren = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var t in snapshot.Targets.Values)
        {
            meter.Check();
            if (t.ParentId != null) expectedChildren[t.ParentId] = expectedChildren.GetValueOrDefault(t.ParentId) + 1;
        }
        var included = new HashSet<string>(StringComparer.Ordinal);
        bool AddWithAncestors(InventoryTarget target)
        {
            var ancestors = new Stack<InventoryTarget>();
            for (InventoryTarget? t = target; t != null && !included.Contains(t.ObjectId); t = t.ParentId != null ? snapshot.Targets[t.ParentId] : null)
            { meter.Check(); ancestors.Push(t); }
            if (indexLimit.HasValue && included.Count + ancestors.Count > indexLimit.Value) return false;
            while (ancestors.TryPop(out var t))
            {
                meter.Metadata(); included.Add(t.ObjectId); paths.Add(t.Path, t); summaries.Add(t.ObjectId, new());
                if (t.ParentId != null)
                {
                    if (!children.TryGetValue(t.ParentId, out var list)) children[t.ParentId] = list = [];
                    list.Add(t);
                }
            }
            return true;
        }
        if (!AddWithAncestors(selectedRoot ?? snapshot.Targets[snapshot.RootId])) throw new BudgetExceededException("IndexAncestorBudget");
        foreach (var t in snapshot.Targets.Values)
        {
            meter.Check();
            if (!AddWithAncestors(t)) break;
        }
        Complete = included.Count == snapshot.Targets.Count;
        var ordered = new List<InventoryTarget>(); var stack = new Stack<(InventoryTarget, bool)>();
        stack.Push((snapshot.Targets[snapshot.RootId], false));
        while (stack.TryPop(out var entry))
        {
            meter.Check(); var (t, inherited) = entry; ordered.Add(t);
            var direct = Direct(t); var s = summaries[t.ObjectId];
            s.ExpectedDirectObjects = expectedChildren.GetValueOrDefault(t.ObjectId); s.IndexedDirectObjects = direct.Count;
            s.DirectComplete = s.IndexedDirectObjects == s.ExpectedDirectObjects;
            s.SubtreeComplete = s.DirectComplete && t.Coverage == Coverage.Complete;
            s.Portable = direct.Any(f => f.Kind == TargetKind.File && Path.GetExtension(f.Path).Equals(".exe", StringComparison.OrdinalIgnoreCase)) && direct.Any(f => Path.GetFileName(f.Path).Equals("portable.ini", StringComparison.OrdinalIgnoreCase) || Path.GetFileName(f.Path).Equals("portable.dat", StringComparison.OrdinalIgnoreCase));
            s.Project = direct.Any(f => f.Kind == TargetKind.File && Path.GetExtension(f.Path).ToLowerInvariant() is ".csproj" or ".fsproj" or ".vbproj");
            s.Package = direct.Any(f => f.Kind == TargetKind.File && Path.GetFileName(f.Path) == "package.json");
            s.DotnetOutput = direct.Any(f => f.Kind == TargetKind.Directory && Path.GetFileName(f.Path) is "bin" or "obj");
            s.FrontendOutput = direct.Any(f => f.Kind == TargetKind.Directory && Path.GetFileName(f.Path) == "dist");
            var names = direct.Where(f => f.Kind == TargetKind.File).Select(f => Path.GetFileName(f.Path)).ToHashSet(StringComparer.Ordinal);
            s.Chromium = names.Contains("index") && Enumerable.Range(0, 4).All(i => names.Contains("data_" + i)) && names.Any(n => System.Text.RegularExpressions.Regex.IsMatch(n, "^f_[0-9a-fA-F]{6,}$"));
            s.SimpleCache = names.Any(SimpleCacheFormat.IsClue);
            s.DuplicateSizes = direct.Where(IsPackage).GroupBy(f => f.LogicalBytes).Any(g => g.Select(f => f.FileIdentity).Distinct(StringComparer.Ordinal).Skip(1).Any());
            // An incomplete direct index could hide portable/private ancestor markers. Only unrelated
            // descendant gaps may be isolated; unknown direct membership still closes the whole branch.
            bool protection = inherited || ProbeContext.HardProtection(t) || !ProbeContext.AncestorCoverageAllowed(t) || s.Portable;
            s.IncompleteDirectIndexDiagnostic = t.Kind == TargetKind.Directory && !s.DirectComplete && !protection;
            bool deny = protection || !s.DirectComplete;
            blocked[t.ObjectId] = deny;
            foreach (var child in direct) stack.Push((child, deny));
        }
        // Every indexed item was charged on ingestion. A complete subtree needs every direct count
        // to match the FULL snapshot and every member's coverage to be complete, not merely its root.
        for (int i = ordered.Count - 1; i >= 0; i--)
        {
            meter.Check(); var t = ordered[i]; var s = summaries[t.ObjectId];
            if (t.Kind == TargetKind.Directory) s.Directories++;
            if (t.Kind == TargetKind.File)
            {
                s.Bytes = Math.Max(0, t.LogicalBytes ?? 0); s.Files = 1;
                s.PrivateFiles = ProbeContext.Protected(t) ? 1 : 0; s.SourceFiles = ProbeContext.Source(t) ? 1 : 0;
                s.PackageFiles = IsPackage(t) ? 1 : 0;
            }
            if (t.ParentId != null)
            {
                var p = summaries[t.ParentId]; p.Bytes = s.Bytes > long.MaxValue - p.Bytes ? long.MaxValue : p.Bytes + s.Bytes;
                p.Files += s.Files; p.Directories += s.Directories; p.PrivateFiles += s.PrivateFiles; p.SourceFiles += s.SourceFiles; p.PackageFiles += s.PackageFiles;
                p.SubtreeComplete &= s.SubtreeComplete;
            }
        }
    }
    internal static bool IsPackage(InventoryTarget t) => t.Kind == TargetKind.File && t.LogicalBytes > 0 && Path.GetExtension(t.Path).ToLowerInvariant() is ".zip" or ".msi";
    internal IReadOnlyList<InventoryTarget> Direct(InventoryTarget target) => children.TryGetValue(target.ObjectId, out var list) ? list : [];
    internal Summary Get(InventoryTarget target) => summaries[target.ObjectId];
    internal bool Blocked(InventoryTarget target) => blocked[target.ObjectId];
    internal InventoryTarget? AtPath(string path) => paths.GetValueOrDefault(path);
    internal IEnumerable<InventoryTarget> Descendants(InventoryTarget target)
    {
        var stack = new Stack<IEnumerator<InventoryTarget>>(); stack.Push(Direct(target).GetEnumerator());
        try
        {
            while (stack.Count > 0)
            {
                meter.Check(); var iterator = stack.Peek();
                if (!iterator.MoveNext()) { iterator.Dispose(); stack.Pop(); continue; }
                var next = iterator.Current; meter.Metadata(); yield return next;
                if (next.Kind == TargetKind.Directory) stack.Push(Direct(next).GetEnumerator());
            }
        }
        finally { foreach (var iterator in stack) iterator.Dispose(); }
    }
}
