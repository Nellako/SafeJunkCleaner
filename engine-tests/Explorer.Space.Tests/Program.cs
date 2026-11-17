using System.Diagnostics;
using SafeJunkCleaner.Explorer;

int assertions = 0;
void Check(bool value, string message) { assertions++; if (!value) throw new Exception(message); }
SpaceObservation[] rows =
[
    new(1, null, @"E:\synthetic", "Directory", "root", null, null, 1, "Partial", "Done"),
    new(2, 1, @"E:\synthetic\a", "Directory", "dir-a", null, null, 1, "Complete", "Done"),
    new(3, 1, @"E:\synthetic\b", "Directory", "dir-b", null, null, 1, "Complete", "Done"),
    new(4, 2, @"E:\synthetic\a\one", "File", "shared", 100, 4096, 3, "Complete", "Done"),
    new(5, 2, @"E:\synthetic\a\two", "File", "shared", 100, 4096, 3, "Complete", "Done"),
    new(6, 3, @"E:\synthetic\b\one", "File", "shared", 100, 4096, 3, "Complete", "Done"),
    new(7, 3, @"E:\synthetic\b\unknown-allocation", "File", "unknown-allocation", 50, null, 1, "Complete", "Done"),
    new(8, 1, @"E:\synthetic\denied", "Unknown", null, null, null, 0, "NotCovered", "Done"),
    new(9, 1, @"E:\synthetic\empty", "Directory", "empty", null, null, 1, "Complete", "Done"),
    new(10, 1, @"E:\synthetic\pending", "Directory", "pending", null, null, 1, "Pending", "Pending")
];
var values = ObservedSpaceIndex.Build(rows).ToDictionary(i => i.ObjectId);
Check(values["1"].ObservedLogicalBytes == 150 && values["1"].ObservedAllocatedBytes == 4096, "scope totals deduplicate file identity across sibling directories");
Check(values["2"].ObservedLogicalBytes == 100 && values["2"].ObservedAllocatedBytes == 4096 && values["2"].HardLinkedFiles == 1, "directory deduplicates same identity within subtree");
Check(values["3"].ObservedLogicalBytes == 150 && values["3"].UnknownAllocationObjects == 1, "partial allocation sum preserves unknown count");
Check(values["1"].UnknownAllocationObjects == 3 && values["1"].HardLinkedFiles == 1, "scope unknowns include unobserved object and pending directory");
Check(values["8"].ObservedLogicalBytes == null && values["8"].ObservedAllocatedBytes == null && values["8"].Coverage == "NotCovered", "coverage gap never fabricated as zero");
Check(values["9"].ObservedLogicalBytes == 0 && values["9"].ObservedAllocatedBytes == 0, "observed complete empty directory is exactly zero");
Check(values["10"].ObservedLogicalBytes == null && values["10"].ObservedAllocatedBytes == null, "unscanned directory remains unknown");
var sparse = ObservedSpaceIndex.Build([rows[0] with { Coverage = "Complete" }, rows[6] with { Parent = 1, Allocated = 0 }]);
Check(sparse.Single(i => i.ObjectId == "1").ObservedAllocatedBytes == 0, "known sparse allocation zero retained");
var inherited = ObservedSpaceIndex.Build([rows[0] with { Coverage = "Complete" }, rows[7]]);
Check(inherited.Single(i => i.ObjectId == "1").Coverage == "Partial" && inherited.Single(i => i.ObjectId == "1").ObservedLogicalBytes == null, "incomplete descendants propagate coverage without false zero");
var wide = new List<SpaceObservation> { rows[0] with { Coverage = "Complete" } };
for (int i = 2; i <= 100001; i++) wide.Add(new(i, 1, "synthetic-" + i, "File", "id-" + i, i, i, 1, "Complete", "Done"));
var timer = Stopwatch.StartNew(); var wideResult = ObservedSpaceIndex.Build(wide); timer.Stop();
Check(wideResult.Length == wide.Count && wideResult.Single(i => i.ObjectId == "1").ObservedLogicalBytes == wide.Skip(1).Sum(i => i.Logical), "100k wide index exact aggregation");
var deep = new List<SpaceObservation>();
for (int i = 1; i <= 10000; i++) deep.Add(new(i, i == 1 ? null : i - 1, "deep-" + i, "Directory", "dir-" + i, null, null, 1, "Complete", "Done"));
deep.Add(new(10001, 10000, "leaf", "File", "leaf-id", 42, 4096, 1, "Complete", "Done"));
var deepResult = ObservedSpaceIndex.Build(deep);
Check(deepResult.Single(i => i.ObjectId == "1").ObservedLogicalBytes == 42, "10k deep tree avoids managed stack recursion");
Check(ObservedSpaceIndex.Build(rows).Select(i => i.ObjectId).SequenceEqual(ObservedSpaceIndex.Build(rows.Reverse().ToArray()).Select(i => i.ObjectId)), "stable sorting independent of source enumeration");
Console.WriteLine($"PASS {assertions} space assertions; 100k aggregation {timer.ElapsedMilliseconds}ms; synthetic metadata only; no filesystem or recycle");
