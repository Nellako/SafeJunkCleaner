using System.Buffers.Binary;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SafeJunkCleaner.Explorer.Analysis;

internal static class Program
{
    const ulong Initial = 0xfcfb6d1ba7725c30UL, Final = 0xf4fa6f45970d41d8UL;
    const string Hash = "0123456789abcdef", Sentinel = "SENSITIVE-PRIVATE-URL-KEY-AND-HTTP-BODY-NEVER-EXPORT";
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateHardLink(string path, string existing, IntPtr security);
    sealed record Scenario(string Name, bool Positive = false, bool ZeroReads = false, string? Reason = null,
        Action<string>? Setup = null, Func<InventoryEvidenceSnapshot, InventoryEvidenceSnapshot>? Transform = null,
        Action<string>? AfterCapture = null, HeuristicBudget? Budget = null, long? ExactBytes = null, int? ExactFiles = null);
    sealed class Sink(Action<HeuristicProgress> callback) : IProgress<HeuristicProgress>
    { public void Report(HeuristicProgress value) => callback(value); }
    static void U32(byte[] b, int at, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(at), value);
    static byte[] Footer(uint flags = 0, uint size = 0)
    {
        byte[] b = new byte[24]; BinaryPrimitives.WriteUInt64LittleEndian(b, Final); U32(b, 8, flags); U32(b, 16, size); return b;
    }
    // Independent fixture: header24 + key + stream1 + EOF1 + stream0 + optional keySHA32 + EOF0.
    // _1 holds stream2 only. No production format helper is called to construct expected bytes.
    static byte[] Entry(bool one = false, bool sha = false)
    {
        byte[] key = Encoding.ASCII.GetBytes(Sentinel + "-KEY"), body = Encoding.ASCII.GetBytes(Sentinel + "-STREAM1"), stream0 = Encoding.ASCII.GetBytes(Sentinel + "-HTTP"), b = new byte[24];
        BinaryPrimitives.WriteUInt64LittleEndian(b, Initial); U32(b, 8, 5); U32(b, 12, (uint)key.Length); U32(b, 16, 0xa1234567);
        using var m = new MemoryStream(); m.Write(b); m.Write(key); m.Write(body);
        if (!one) { m.Write(Footer(1)); m.Write(stream0); if (sha) m.Write(SHA256.HashData(key)); m.Write(Footer(sha ? 3u : 1u, (uint)stream0.Length)); }
        else m.Write(Footer(1));
        return m.ToArray();
    }
    static string Zero(string root) => Path.Combine(root, Hash + "_0");
    static void Put(string root, string name, byte[] bytes) => File.WriteAllBytes(Path.Combine(root, name), bytes);
    static void Mutate(string root, Action<byte[]> action) { var b = File.ReadAllBytes(Zero(root)); action(b); File.WriteAllBytes(Zero(root), b); }
    static InventoryEvidenceSnapshot Capture(string root)
    {
        var targets = new List<InventoryTarget>();
        void Add(string p, string? parent)
        {
            var t = MetadataAccess.Capture("t" + targets.Count, parent, p); targets.Add(t);
            if (t.Kind == TargetKind.Directory && (t.Attributes & 0x400) == 0)
                foreach (var child in Directory.EnumerateFileSystemEntries(p).OrderBy(x => x, StringComparer.Ordinal)) Add(child, t.ObjectId);
        }
        Add(root, null); return new(Guid.NewGuid().ToString("D"), 1, targets[0].ObjectId, targets);
    }
    static InventoryEvidenceSnapshot Change(InventoryEvidenceSnapshot s, Func<InventoryTarget, InventoryTarget> map) => new(s.TaskId, s.Revision, s.RootId, s.Targets.Values.Select(map));
    static async Task<int> Main(string[] args)
    {
        string evidence = Path.GetFullPath(args[0]); Directory.CreateDirectory(evidence);
        string fixture = Path.Combine(evidence, "private-fixture-" + Guid.NewGuid().ToString("D")); Directory.CreateDirectory(fixture);
        var scenarios = new List<Scenario>
        {
            new("positive-zero", true, Reason: "Recognized", ExactBytes: 72, ExactFiles: 1),
            new("positive-sha", true, Reason: "Recognized", Setup: r => Put(r, Hash + "_0", Entry(sha: true)), ExactBytes: 72, ExactFiles: 1),
            new("positive-pair-index", true, Reason: "Recognized", Setup: r => { Put(r, Hash + "_1", Entry(one:true)); Put(r,"index",Encoding.ASCII.GetBytes(Sentinel)); Directory.CreateDirectory(Path.Combine(r,"index-dir")); Put(Path.Combine(r,"index-dir"),"the-real-index",Encoding.ASCII.GetBytes(Sentinel)); }, ExactBytes: 120, ExactFiles: 2),
            new("negative-version", Reason:"UnknownVersion", Setup:r=>Mutate(r,b=>U32(b,8,9))),
            new("negative-magic", Reason:"MalformedHeader", Setup:r=>Mutate(r,b=>b[0]^=1)),
            new("negative-footer", Reason:"MalformedFooter", Setup:r=>Mutate(r,b=>b[^24]^=1)),
            new("negative-eof1", Reason:"MalformedFooter", Setup:r=>Mutate(r,b=>b[24+Encoding.ASCII.GetByteCount(Sentinel+"-KEY")+Encoding.ASCII.GetByteCount(Sentinel+"-STREAM1")]^=1)),
            new("negative-flags", Reason:"UnknownFlags", Setup:r=>Mutate(r,b=>U32(b,b.Length-16,4))),
            new("negative-truncation", ZeroReads:true, Reason:"Truncated", Setup:r=>Put(r,Hash+"_0",new byte[71])),
            new("negative-arithmetic", Reason:"MalformedArithmetic", Setup:r=>Mutate(r,b=>U32(b,b.Length-8,0x7ffffffe))),
            new("negative-key-overflow", Reason:"MalformedHeader", Setup:r=>Mutate(r,b=>U32(b,12,uint.MaxValue))),
            new("negative-sparse", ZeroReads:true, Reason:"UnsupportedMember", Setup:r=>Put(r,Hash+"_s",Encoding.ASCII.GetBytes(Sentinel))),
            new("negative-todelete", ZeroReads:true, Reason:"UnsupportedMember", Setup:r=>Put(r,"todelete_"+Hash+"_0",Entry())),
            new("negative-one-without-zero", ZeroReads:true, Reason:"UnsupportedMember", Setup:r=>File.Move(Zero(r),Path.Combine(r,Hash+"_1"))),
            new("negative-extra-unknown", ZeroReads:true, Reason:"UnsupportedMember", Setup:r=>Put(r,"unexpected.xyz",Encoding.ASCII.GetBytes(Sentinel))),
            new("protected-private", ZeroReads:true, Setup:r=>Put(r,"holiday.jpg",Encoding.ASCII.GetBytes(Sentinel))),
            new("protected-source", ZeroReads:true, Setup:r=>Put(r,"code.cs",Encoding.ASCII.GetBytes(Sentinel))),
            new("protected-backup", ZeroReads:true, Setup:r=>Put(r,"personal.backup",Encoding.ASCII.GetBytes(Sentinel))),
            new("protected-portable", ZeroReads:true, Setup:r=> { Put(r,"app.exe",Encoding.ASCII.GetBytes(Sentinel)); Put(r,"portable.ini",Encoding.ASCII.GetBytes(Sentinel)); }),
            new("protected-hardlink", ZeroReads:true, Setup:r=> { if(!CreateHardLink(Path.Combine(r,"fedcba9876543210_0"),Zero(r),IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }),
            new("protected-junction", ZeroReads:true, Setup:r=> { string target=Path.Combine(evidence,"junction-target-"+Guid.NewGuid().ToString("D")); Directory.CreateDirectory(target); var p=Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{Path.Combine(r,"index-dir")}\" \"{target}\"") { UseShellExecute=false, RedirectStandardOutput=true, RedirectStandardError=true })!; string output=p.StandardOutput.ReadToEnd()+p.StandardError.ReadToEnd(); p.WaitForExit(); if(p.ExitCode!=0) throw new Exception(output); }),
            new("protected-coverage-root", ZeroReads:true, Transform:s=>Change(s,t=>t.ObjectId==s.RootId?t with {Coverage=Coverage.Partial}:t)),
            new("protected-coverage-member", ZeroReads:true, Transform:s=>Change(s,t=>t.Kind==TargetKind.File?t with {Coverage=Coverage.NotCovered}:t)),
            new("protected-explicit", ZeroReads:true, Transform:s=>Change(s,t=>t.ObjectId==s.RootId?t with {HardProtected=true}:t)),
            new("negative-changedmember", ZeroReads:true, AfterCapture:r=>File.AppendAllText(Zero(r),"changed")),
            new("negative-newmember", ZeroReads:true, AfterCapture:r=>Put(r,"new-private.jpg",Encoding.ASCII.GetBytes(Sentinel))),
            new("negative-byte-budget", ZeroReads:true, Reason:"BudgetExceeded", Budget:new(MaxSampleBytes:71)),
            new("negative-file-budget", ZeroReads:true, Reason:"BudgetExceeded", Setup:r=>Put(r,Hash+"_1",Entry(one:true)), Budget:new(MaxReadFiles:1)),
        };
        var rows = new List<object>(); int pass=0, fail=0, blocked=0, tp=0,tn=0,fp=0,fn=0;
        foreach(var c in scenarios)
        {
            string root=Path.Combine(fixture,c.Name); Directory.CreateDirectory(root); Put(root,Hash+"_0",Entry());
            try
            {
                c.Setup?.Invoke(root); var s=Capture(root); if(c.Transform!=null) s=c.Transform(s); c.AfterCapture?.Invoke(root);
                var result=await new HeuristicExplorationScheduler().ExploreAsync(s,budget:c.Budget);
                bool recognized=result.Evidence.Any(e=>e.Value=="ChromiumSimpleCacheRecognized");
                if(c.Positive) { if(recognized)tp++;else fn++; } else {if(recognized)fp++;else tn++;}
                string serialized=JsonSerializer.Serialize(result); var errors=new List<string>();
                if(recognized!=c.Positive) errors.Add("recognition mismatch");
                if(result.Suggestions.Any(x=>x.MayPrepareForReview||x.CandidateFiles.Count!=0||x.SelectedByDefault)) errors.Add("processing authorization escaped");
                if(c.ZeroReads&&(result.Usage.ReadFiles!=0||result.Usage.SampleBytes!=0))errors.Add("protected/preflight content read");
                long bound=s.Targets.Values.Where(t=>t.Kind==TargetKind.File).Sum(t=>t.Path.EndsWith("_0")?72L:t.Path.EndsWith("_1")?48L:0L);
                if(result.Usage.SampleBytes>bound||result.Usage.HashBytes!=0||result.Usage.HashFiles!=0)errors.Add("fixed read bound/hash violation");
                if(c.ExactBytes.HasValue&&result.Usage.SampleBytes!=c.ExactBytes.Value) errors.Add("exact byte count mismatch");
                if(c.ExactFiles.HasValue&&result.Usage.ReadFiles!=c.ExactFiles.Value) errors.Add("exact file count mismatch");
                if(c.Reason!=null&&!result.Evidence.Any(e=>e.Value=="ChromiumSimpleCache"+c.Reason))errors.Add("expected diagnostic missing: "+c.Reason);
                if(serialized.Contains(Sentinel,StringComparison.Ordinal))errors.Add("sensitive sentinel exported");
                if(c.Positive&&!result.Suggestions.Any(x=>x.Classification==Classification.Cache&&x.Level==SuggestionLevel.OrganizeOpportunity&&x.HardProtected))errors.Add("display-only Cache suggestion missing");
                bool ok=errors.Count==0; if(ok)pass++;else fail++;
                rows.Add(new {c.Name,ExpectedRecognized=c.Positive,ActualRecognized=recognized,ExpectedZeroReads=c.ZeroReads,ExpectedReadBytes=c.ExactBytes,ActualReadBytes=result.Usage.SampleBytes,result.Usage.ReadFiles,result.Usage.MetadataObjects,Status=result.Status.ToString(),Outcome=ok?"PASS":"FAIL",Errors=errors,Evidence=result.Evidence, Suggestions=result.Suggestions});
                Console.WriteLine($"{(ok?"PASS":"FAIL")} {c.Name} expected={c.Positive} actual={recognized} bytes={result.Usage.SampleBytes} files={result.Usage.ReadFiles} metadata={result.Usage.MetadataObjects} {string.Join(";",errors)}");
            }
            catch(Exception ex) { blocked++; rows.Add(new {c.Name,Outcome="BLOCKED",Error=ex.ToString()}); Console.WriteLine($"BLOCKED {c.Name} {ex}"); }
        }
        string dll=typeof(HeuristicExplorationScheduler).Assembly.Location;
        var report=new {TimestampUtc=DateTime.UtcNow,FixtureRoot=fixture,Assembly=dll,AssemblySha256=Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(dll))),Planned=scenarios.Count,Executed=pass+fail,Passed=pass,Failed=fail,Blocked=blocked,Skipped=0,ConfusionMatrix=new{TP=tp,TN=tn,FP=fp,FN=fn},ReadEvidenceScope="Actual public classifier BudgetUsage; sentinel absence checks export, not independent OS read-offset tracing",Rows=rows};
        File.WriteAllText(Path.Combine(evidence,"simple-cache-results.json"),JsonSerializer.Serialize(report,new JsonSerializerOptions {WriteIndented=true}));
        Console.WriteLine($"TOTAL planned={scenarios.Count} pass={pass} fail={fail} blocked={blocked} TP={tp} TN={tn} FP={fp} FN={fn}");
        return fail+blocked==0?0:1;
    }
}
