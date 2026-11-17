using SafeJunkCleaner.Explorer.Application;
using SafeJunkCleaner.Explorer.Analysis;
using SafeJunkCleaner.Explorer.Execution;

int assertions = 0;
void Check(bool value, string message) { assertions++; if (!value) throw new Exception(message); }
void Reject(Action operation, string message) { bool rejected = false; try { operation(); } catch { rejected = true; } Check(rejected, message); }
string task = Guid.NewGuid().ToString("D");
var modified = DateTime.UtcNow.AddHours(-1);
var header = new TrustedTaskHeader(task, 7, Guid.NewGuid().ToString("D"), "scope-v1", "policy-v1", "test-owner", "1", @"E:\adapter-owned-index", "root-identity", "Ready");
InventoryRow[] rows = [new("1", null, header.RootPath, "Directory", "root-identity", null, modified.ToString("O"), 16, 1, "Complete", null),
    new("2", "1", header.RootPath + @"\cache", "Directory", "cache-identity", null, modified.ToString("O"), 16, 1, "Complete", null),
    new("3", "2", header.RootPath + @"\cache\item.tmp", "File", "file-identity", 17, modified.ToString("O"), 0, 1, "Complete", null)];
var index = new Rows(header, rows);
var mapped = new InventorySnapshotAdapter(index, header.OwnerSid).Load(task, 7);
Check(mapped.Evidence.Targets.Count == 3 && index.Pages == 2, "all pages loaded including last page");
Check(mapped.Evidence.Targets["3"].ModifiedUtcTicks == modified.Ticks, "UTC timestamp roundtrip");
string guid = StableIds.Create(task, 7, "suggestion", "suggest-2-Cache");
Check(Guid.TryParseExact(guid, "D", out _) && guid == StableIds.Create(task, 7, "suggestion", "suggest-2-Cache"), "stable GUID-D");
Check(guid != StableIds.Create(task, 8, "suggestion", "suggest-2-Cache") && guid != StableIds.Create(task, 7, "object", "suggest-2-Cache"), "revision and namespace separation");
var evidence = new AnalysisEvidence("e-cache", "2", EvidenceKind.Layout, "test-index-evidence");
var suggestion = new Suggestion("suggest-2-Cache", "2", Classification.Cache, SuggestionLevel.ReviewSuggested,
    [new("3", "file-identity", 17, modified.Ticks)], [evidence.EvidenceId], ["review required"], "Only one exact cache file", false);
var result = new AnalysisResult(task, 7, AnalysisStatus.Complete, [evidence], [suggestion], [], new(0, 0, 0, 0, 0, 0), "test");
var analysis = new Analysis(result); var facts = new Facts();
var adapter = new ApprovalSourceAdapter(index, analysis, facts);
var approval = adapter.Read(task);
Check(approval.OwnerSid == "test-owner" && approval.Roots.Single() == header.RootPath && approval.PolicyRevision == "policy-v1", "trusted task bindings");
Check(approval.Suggestions.Single().SuggestionId == guid && !approval.Suggestions.Single().HardProtected, "eligible mapped suggestion GUID");
Check(approval.Suggestions.Single().Files.Single().Path == rows[2].Path && approval.Suggestions.Single().Files.Single().Identity == "file-identity", "path resolved from inventory only");
Check(approval.Suggestions.Single().Files.Single().ModifiedUtc == modified.ToString("O"), "exact execution timestamp");
Check(approval.Suggestions.Single().Files.Single().ObjectId == StableIds.Create(task, 7, "object", "3"), "object GUID mapping");
Check(adapter.Read(task).SuggestionRevision == approval.SuggestionRevision, "unchanged source deterministic");
using (adapter.BeginReadScope())
{
    var scopedFirst = adapter.Read(task); int scopedPages = index.Pages;
    Check(ReferenceEquals(scopedFirst, adapter.Read(task)) && index.Pages == scopedPages, "one prepare operation reuses only immutable canonical mapping, not filesystem safety results");
    index.Header = header with { Revision = header.Revision + 1 };
    Reject(() => adapter.Read(task), "operation-local mapping invalidates on changed trusted header"); index.Header = header;
}
int pagesAfterScope = index.Pages;
Check(!ReferenceEquals(approval, adapter.Read(task)) && index.Pages > pagesAfterScope, "canonical mapping never survives operation scope");
analysis.Value = result with { Suggestions = [suggestion with { Impact = "changed impact" }] };
Check(adapter.Read(task).SuggestionRevision != approval.SuggestionRevision, "suggestion content change invalidates binding"); analysis.Value = result;
analysis.Value = result with { Suggestions = [suggestion with { CandidateFiles = [new("3", "wrong-identity", 17, modified.Ticks)] }] };
Reject(() => adapter.Read(task), "candidate metadata must match trusted index"); analysis.Value = result;
analysis.Value = result with { Suggestions = [suggestion with { EvidenceIds = ["missing-evidence"] }] };
Reject(() => adapter.Read(task), "unbound evidence rejected"); analysis.Value = result;
analysis.Value = result with { Suggestions = [suggestion with { HardProtected = true }] };
Check(adapter.Read(task).Suggestions.Single().HardProtected, "hard protection never elevated"); analysis.Value = result;
analysis.Value = result with { Suggestions = [suggestion with { Classification = Classification.InstallerDuplicate, Duplicate = new(new string('A', 64), [], true) }] };
Reject(() => adapter.Read(task), "missing per-copy duplicate proof rejected");
var keeperRow = new InventoryRow("4", "2", header.RootPath + @"\cache\retained.tmp", "File", "keeper-identity", 17, modified.ToString("O"), 0, 1, "Complete", null);
index.Value = [.. rows, keeperRow];
analysis.Value = result with { Suggestions = [suggestion with { Classification = Classification.InstallerDuplicate,
    CandidateFiles = [new("3", "file-identity", 17, modified.Ticks, new string('A', 64))],
    Duplicate = new(new string('A', 64), [new("4", "keeper-identity", 17, modified.Ticks, new string('A', 64))], true) }] };
var duplicate = adapter.Read(task).Suggestions.Single();
Check(duplicate.HardProtected && duplicate.Classification == ProcessingClass.Unknown && duplicate.RetainedCopies.Single().Path == keeperRow.Path, "duplicate kept display-only despite claimed confirmation");
Check(duplicate.Files.Single().ContentSha256 == new string('A', 64), "full hash preserved"); analysis.Value = result;
index.Value = [.. rows, new("4", "1", header.RootPath + @"\unavailable", "Unknown", null, null, null, null, null, "NotCovered", "Denied")];
var partial = new InventorySnapshotAdapter(index, header.OwnerSid).Load(task, 7);
Check(partial.Evidence.Targets.Count == 3 && partial.Coverage.Count == 4 && !partial.Coverage.Single(c => c.ObjectId == "4").Analyzable, "null skipped evidence not a fabricated target");
Check(partial.Evidence.Targets["1"].Coverage == Coverage.Partial, "skipped evidence makes ancestor partial");
Check(adapter.Read(task).Suggestions.Single().HardProtected, "incomplete ancestry cannot produce executable source");
// Real inventories preserve unsafe names as unknown coverage rows, not executable targets.
// This shape reproduces the former NonCanonicalPath failure without opening private files.
var opaque = new InventoryRow("4", "1", header.RootPath + @"\unsupported.", "Unknown", null, null, null, null, null,
    "NotCovered", "MetadataUnavailable:InvalidOperationException");
index.Value = [.. rows, opaque];
var opaqueSnapshot = new InventorySnapshotAdapter(index, header.OwnerSid).Load(task, 7);
Check(opaqueSnapshot.Coverage.Count == 4 && opaqueSnapshot.Evidence.Targets.Count == 3
    && !opaqueSnapshot.Coverage.Single(c => c.ObjectId == "4").Analyzable, "unsupported raw name retained as coverage gap, never a probe target");
Check(opaqueSnapshot.Evidence.Targets["1"].Coverage == Coverage.Partial && adapter.Read(task).Suggestions.Single().HardProtected,
    "opaque gap preserves ancestor incompleteness and cannot grant approval");
foreach (var invalid in new[] { opaque with { Kind = "File" }, opaque with { Coverage = "Complete" },
    opaque with { SkippedReason = "Denied" }, opaque with { FileIdentity = "forged" },
    opaque with { Attributes = 0 }, opaque with { LogicalBytes = 1 }, opaque with { DirectoryEnumerationComplete = true },
    opaque with { ParentId = "2" }, opaque with { Path = @"E:\outside\unsupported." } })
{
    index.Value = [.. rows, invalid];
    Reject(() => new InventorySnapshotAdapter(index, header.OwnerSid).Load(task, 7), "unsupported path exception restricted to exact trusted coverage-only shape");
}
index.Value = [rows[0] with { Path = header.RootPath + "." }, rows[1], rows[2]];
Reject(() => new InventorySnapshotAdapter(index, header.OwnerSid).Load(task, 7), "root never receives unsupported-name exception");
index.Value = rows;
var secondEvidence = evidence with { EvidenceId = "e-root", TargetId = "1" };
var overlapping = suggestion with { SuggestionId = "root-overlap", TargetId = "1", EvidenceIds = [secondEvidence.EvidenceId] };
analysis.Value = result with { Evidence = [evidence, secondEvidence], Suggestions = [suggestion, overlapping] };
var disjoint = adapter.Read(task);
Check(disjoint.Suggestions.Sum(s => s.Files.Length) == 1 && disjoint.Suggestions.SelectMany(s => s.Files).Select(f => f.Identity).Distinct().Count() == 1, "multi-target review members deduplicated globally");
analysis.Value = result with { Suggestions = [suggestion with { CandidateFiles = [suggestion.CandidateFiles[0], suggestion.CandidateFiles[0]] }] };
Check(adapter.Read(task).Suggestions.Single().Files.Length == 1, "repeated identical candidate is canonicalized once");
index.Value = [.. rows, keeperRow];
var extra = new CandidateFile("4", "keeper-identity", 17, modified.Ticks);
var largeGroup = suggestion with { SuggestionId = "a-whole-group", CandidateFiles = [suggestion.CandidateFiles[0], extra] };
var partialOverlap = suggestion with { SuggestionId = "z-overlap-group", CandidateFiles = [extra] };
analysis.Value = result with { Suggestions = [largeGroup, partialOverlap] };
var whole = adapter.Read(task);
Check(whole.Suggestions.Length == 1 && whole.Suggestions.Single().Files.Length == 2, "overlap rejects whole review group instead of arbitrary member subtraction");
var thirdRow = keeperRow with { ObjectId = "5", Path = header.RootPath + @"\cache\third.tmp", FileIdentity = "third-identity" };
index.Value = [.. rows, keeperRow, thirdRow];
var partialLarge = suggestion with { SuggestionId = "b-second-proof", CandidateFiles = [extra, new("5", "third-identity", 17, modified.Ticks)] };
analysis.Value = result with { Suggestions = [largeGroup, partialLarge] };
var noRemainder = adapter.Read(task);
Check(noRemainder.Suggestions.Length == 1 && noRemainder.Suggestions.Single().Files.All(f => f.Identity != "third-identity"), "unique remainder from overlapping proof never becomes an execution candidate");
index.Value = [.. rows, keeperRow with { FileIdentity = "file-identity" }];
analysis.Value = result with { Suggestions = [largeGroup with { CandidateFiles = [suggestion.CandidateFiles[0], extra with { FileIdentity = "file-identity" }] }] };
Check(adapter.Read(task).Suggestions.Length == 0, "different objects claiming same identity reject whole review proof");
index.Value = rows;
analysis.Value = result with { Suggestions = [suggestion with { CandidateFiles = [suggestion.CandidateFiles[0], suggestion.CandidateFiles[0] with { ContentSha256 = new string('A', 64) }] }] };
Reject(() => adapter.Read(task), "same-object conflicting candidate metadata still rejected");
analysis.Value = result;
index.Value = [.. rows, keeperRow, thirdRow];
using (var cancelled = new CancellationTokenSource())
{
    cancelled.Cancel(); int before = index.Pages;
    Reject(() => new InventorySnapshotAdapter(index, header.OwnerSid).Load(task, 7, cancelled.Token), "cancelled snapshot export rejected before page access");
    Check(index.Pages == before, "cancelled snapshot export performs no page reads");
}
analysis.Value = result;
index.Value = [rows[0], rows[1], rows[2] with { LinkCount = 2 }];
Check(adapter.Read(task).Suggestions.Single().HardProtected, "hard-linked file never reviewable");
index.Value = [rows[0], rows[1], rows[2] with { Attributes = 1 }];
Check(adapter.Read(task).Suggestions.Single().HardProtected, "read-only file never reviewable");
index.Value = rows;
analysis.Value = result with { Reason = "same evidence|HostAnalysis:" + Guid.NewGuid().ToString("D") };
string firstGeneration = adapter.Read(task).SuggestionRevision;
analysis.Value = result with { Reason = "same evidence|HostAnalysis:" + Guid.NewGuid().ToString("D") };
Check(adapter.Read(task).SuggestionRevision != firstGeneration, "fresh analysis generation changes approval revision without frozen hash expectations");
analysis.Value = result;
index.Header = header with { OwnerSid = "another-owner" };
Reject(() => adapter.Read(task), "owner mismatch rejected"); index.Header = header;
index.ChangeHeaderOnSecondRead = true;
Reject(() => new InventorySnapshotAdapter(index, header.OwnerSid).Load(task, 7), "revision changes during paging rejected"); index.ChangeHeaderOnSecondRead = false;
index.RepeatCursor = true;
Reject(() => new InventorySnapshotAdapter(index, header.OwnerSid).Load(task, 7), "cursor loops rejected"); index.RepeatCursor = false;
index.Value = [.. rows, rows[2] with { ObjectId = "4", Path = @"E:\outside\bad.tmp" }];
Reject(() => new InventorySnapshotAdapter(index, header.OwnerSid).Load(task, 7), "out-of-scope rows rejected");
Console.WriteLine($"PASS {assertions} application adapter assertions; synthetic trusted rows only; no file operations, no real recycle");

sealed class Rows(TrustedTaskHeader header, InventoryRow[] rows) : ITrustedInventoryRows
{
    public TrustedTaskHeader Header = header;
    public InventoryRow[] Value = rows;
    public int Pages;
    public bool RepeatCursor, ChangeHeaderOnSecondRead;
    private int reads;
    public TrustedTaskHeader ReadHeader(string taskId)
    {
        reads++;
        return ChangeHeaderOnSecondRead && reads % 2 == 0 ? Header with { Revision = Header.Revision + 1 } : Header;
    }
    public InventoryPage ReadPage(string taskId, long revision, string? after, int size)
    {
        Pages++;
        int offset = after == null ? 0 : int.Parse(after);
        var part = Value.Skip(offset).Take(2).ToArray();
        return new(part, RepeatCursor ? "0" : offset + part.Length < Value.Length ? (offset + part.Length).ToString() : null);
    }
}
sealed class Analysis(AnalysisResult result) : ITrustedAnalysisSnapshots
{
    public AnalysisResult Value = result;
    public AnalysisResult Read(string taskId, long revision) => Value;
}
sealed class Facts : IExecutionFacts
{
    public string OwnerSid => "test-owner";
    public void ValidateLocalPath(string path) { if (!path.StartsWith(@"E:\", StringComparison.Ordinal)) throw new Exception("unsupported"); }
    public string? HardProtection(string path) => null;
    public AncestorSnapshot[] Ancestors(string path) => throw new NotSupportedException("Execution alone captures fresh ancestors");
    public CurrentFile Read(string path, bool verifyContent) => throw new NotSupportedException("Adapter never reads file content");
    public IDisposable GuardAncestors(string path, AncestorSnapshot[] expected) => throw new NotSupportedException();
    public IDisposable GuardRetainedCopy(FileSnapshot expected) => throw new NotSupportedException();
}
