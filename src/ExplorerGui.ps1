# 星梦雨垃圾清理器：探索工作台（开发候选）。入口位于主窗口。
# 盘点/启发式分析只读；回收必须经过精确复核、两次用户确认与独立 Host 执行检查。
# 协议：UTF-8 无 BOM 的 JSONL（ProtocolVersion=1），一次只发一个请求，由 SjcExplorerBridge 在后台读取 stdout。
# 响应先由 SjcJsonGuard（JsonReaderWriterFactory 流式遍历）拒绝重复字段，再由 JavaScriptSerializer 解析，并按 Operation 校验 Result 必需字段。
# 单实例容器：模块加载时只创建一次，窗口关闭后清空。
$script:SjcExplorerSingleton = @{Window=$null}
$script:SjcExplorerBridgeSource = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Xml;


public static class SjcJsonGuard
{
    // 用 JsonReaderWriterFactory 流式遍历：同一对象内出现重复成员名即拒绝；返回 null 表示未发现问题。
    public static string Check(string text)
    {
        try
        {
            byte[] bytes = new UTF8Encoding(false).GetBytes(text);
            XmlDictionaryReaderQuotas q = new XmlDictionaryReaderQuotas();
            q.MaxDepth = 12; q.MaxStringContentLength = 262144; q.MaxArrayLength = 16384;
            q.MaxBytesPerRead = 4096; q.MaxNameTableCharCount = 262144;
            Stack<HashSet<string>> stack = new Stack<HashSet<string>>();
            using (XmlDictionaryReader r = JsonReaderWriterFactory.CreateJsonReader(bytes, 0, bytes.Length, Encoding.UTF8, q, null))
            {
                while (r.Read())
                {
                    if (r.NodeType == XmlNodeType.Element)
                    {
                        HashSet<string> parent = stack.Count > 0 ? stack.Peek() : null;
                        if (parent != null)
                        {
                            string key = r.LocalName;
                            if (key == "item") { string alias = r.GetAttribute("item"); if (alias != null) key = alias; }
                            if (!parent.Add(key)) return "ResponseDuplicateKey";
                        }
                        if (!r.IsEmptyElement) stack.Push(r.GetAttribute("type") == "object" ? new HashSet<string>(StringComparer.Ordinal) : null);
                    }
                    else if (r.NodeType == XmlNodeType.EndElement)
                    {
                        if (stack.Count == 0) return "ResponseJsonInvalid";
                        stack.Pop();
                    }
                }
            }
            if (stack.Count != 0) return "ResponseJsonInvalid";
            new JavaScriptSerializer().DeserializeObject(text);
            return null;
        }
        catch (Exception) { return "ResponseJsonInvalid"; }
    }
}

public static class SjcHostVerifier
{
    // 后台逐个核对：相对路径限定在 root 内、无重解析点、字节数（sizes[i] 为负数则不校验）与 SHA-256。
    // checkAncestors：root 的所有上级目录也不能是重解析点；checkExtras：root 内不得有清单之外的文件（allowedExtra 例外）。
    public static Task<string> VerifyAsync(string root, string[] relPaths, string[] sha256, long[] sizes, bool rejectLinks, bool checkExtras, bool checkAncestors, string allowedExtra)
    {
        return Task.Factory.StartNew<string>(delegate { return Verify(root, relPaths, sha256, sizes, rejectLinks, checkExtras, checkAncestors, allowedExtra); });
    }

    private static bool Linked(string path)
    {
        return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
    }

    public static string Verify(string root, string[] relPaths, string[] sha256, long[] sizes, bool rejectLinks, bool checkExtras, bool checkAncestors, string allowedExtra)
    {
        try
        {
            if (relPaths == null || relPaths.Length == 0 || relPaths.Length != sha256.Length || relPaths.Length != sizes.Length) return "ManifestEmpty";
            string rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
            if (!Directory.Exists(rootFull)) return "RootMissing";
            for (string a = rootFull; rejectLinks && a != null; a = Path.GetDirectoryName(a))
            {
                if (!checkAncestors && !string.Equals(a, rootFull, StringComparison.OrdinalIgnoreCase)) break;
                if (Linked(a)) return "RootOrAncestorLinked";
            }
            HashSet<string> listed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (SHA256 sha = SHA256.Create())
            {
                for (int i = 0; i < relPaths.Length; i++)
                {
                    string rel = relPaths[i];
                    string full = Path.GetFullPath(Path.Combine(rootFull, rel.Replace('/', Path.DirectorySeparatorChar)));
                    if (!full.StartsWith(rootFull + "\\", StringComparison.OrdinalIgnoreCase)) return "ComponentOutsideRoot:" + rel;
                    if (!listed.Add(full)) return "ComponentDuplicate:" + rel;
                    for (string d = full; rejectLinks && d != null && d.Length > rootFull.Length; d = Path.GetDirectoryName(d))
                    {
                        try { if (Linked(d)) return "ComponentLinked:" + rel; } catch (Exception) { return "ComponentMissing:" + rel; }
                    }
                    FileInfo fi = new FileInfo(full);
                    if (!fi.Exists) return "ComponentMissing:" + rel;
                    if (sizes[i] >= 0 && fi.Length != sizes[i]) return "ComponentSizeMismatch:" + rel;
                    byte[] h;
                    using (FileStream fs = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.Read)) h = sha.ComputeHash(fs);
                    string hex = BitConverter.ToString(h).Replace("-", "");
                    if (!string.Equals(hex, sha256[i], StringComparison.OrdinalIgnoreCase)) return "ComponentHashMismatch:" + rel;
                }
            }
            if (checkExtras)
            {
                string allowedFull = string.IsNullOrEmpty(allowedExtra) ? null : Path.GetFullPath(Path.Combine(rootFull, allowedExtra));
                foreach (string f in Directory.EnumerateFiles(rootFull, "*", SearchOption.AllDirectories))
                {
                    if (listed.Contains(f)) continue;
                    if (allowedFull != null && string.Equals(f, allowedFull, StringComparison.OrdinalIgnoreCase)) continue;
                    return "UnlistedFile:" + f.Substring(rootFull.Length + 1);
                }
            }
            return null;
        }
        catch (Exception ex) { return "VerifyFailed:" + ex.GetType().Name; }
    }
}

public static class SjcResultSchema
{
    // 按 Operation 校验 Result 必需字段与类型；允许额外字段（向后兼容扩展），拒绝缺失或类型错误。
    private static Exception Bad(string code) { return new InvalidOperationException(code); }
    private static bool IsInt(object v) { return v is int || v is long; }
    private static long ToLong(object v) { return v is int ? (int)v : (long)v; }
    private static bool IsText(object v, int max) { string s = v as string; return s != null && s.Length <= max; }
    private static bool IsNullableText(object v, int max) { return v == null || IsText(v, max); }
    private static bool IsNullableInt(object v) { return v == null || IsInt(v); }
    private static bool IsId(object v) { Guid g; string s = v as string; return s != null && Guid.TryParseExact(s, "D", out g) && g != Guid.Empty; }

    private static object Req(IDictionary<string, object> d, string key, string where)
    {
        object v;
        if (d == null || !d.TryGetValue(key, out v)) throw Bad("ResultMissing:" + where + "." + key);
        return v;
    }
    private static void Check(bool ok, string code) { if (!ok) throw Bad(code); }

    public static void Validate(string op, IDictionary<string, object> res, string taskId)
    {
        switch (op)
        {
            case "Health": Health(res); break;
            case "CreateInventory":
                Check(IsId(Req(res, "TaskId", op)) && (string)res["TaskId"] == taskId, "ResultInvalid:CreateInventory.TaskId"); break;
            case "GetProgress": Progress(res, taskId); break;
            case "QueryGroups": Groups(res); break;
            case "QueryEvidence": Evidence(res); break;
            case "QuerySpace": Space(res); break;
            case "QuerySpaceAsync":
                string spaceStatus=Req(res,"Status",op) as string;Check(spaceStatus=="Running" || spaceStatus=="Ready" || spaceStatus=="Failed","ResultInvalid:SpaceQuery.Status");
                object spacePage=Req(res,"Page",op);Check((spaceStatus=="Ready")== (spacePage!=null),"ResultInvalid:SpaceQuery.Page");
                if(spacePage!=null)Space(spacePage as IDictionary<string,object>);break;
            case "Pause": case "Cancel":
                Check(Req(res, "Accepted", op) is bool && IsText(Req(res, "State", op), 40), "ResultInvalid:" + op); break;
            case "Resume":
                Check(Req(res, "Accepted", op) is bool, "ResultInvalid:Resume"); break;
            case "ListTasks": ListTasks(res); break;
            case "CreateBatch": case "GetBatch": case "ContinueBatch": case "PauseBatch": case "CancelBatch": case "StopBatch":
                BatchSnapshot(res, op); break;
            case "ListBatches": ListBatches(res); break;
            case "StartBatchEntry": StartBatchEntry(res); break;
            case "GetStorageInfo": Storage(res); break;
            case "CompactState":
                foreach (string k in new string[] { "BeforeBytes", "AfterBytes", "ReclaimedBytes", "BackupBytes", "TasksPreserved", "ObjectsPreserved" }) Check(IsInt(Req(res,k,op)) && ToLong(res[k]) >= 0,"ResultInvalid:"+op+"."+k);
                Check(IsText(Req(res,"BackupPath",op),32768) && IsHex64(Req(res,"BackupSha256",op)),"ResultInvalid:CompactState.Backup"); break;
            case "GetSessionInfo":
                foreach(string k in new string[] { "AnalysisSessions","AnalysisLimit","ActiveAnalyses","ExecutionSessions","ActiveExecutions","ExecutionLimit","DraftBindings" }) Check(IsInt(Req(res,k,op)) && ToLong(res[k]) >= 0,"ResultInvalid:"+op+"."+k);
                object artifacts=Req(res,"ApprovalStorage",op); if(artifacts!=null) ApprovalStorage(artifacts as IDictionary<string,object>); break;
            case "ReleaseFinishedSessions": Check(IsInt(Req(res,"ReleasedAnalyses",op)) && IsBool(Req(res,"ExistingApprovalsInvalidated",op)) && IsBool(Req(res,"PersistedClaimsAndLedgersRetained",op)),"ResultInvalid:"+op); break;
            case "ArchiveUnconfirmedDrafts": Check(IsInt(Req(res,"DraftsArchived",op)) && IsInt(Req(res,"BytesArchived",op)) && IsText(Req(res,"ArchivePath",op),32768) && IsHex64(Req(res,"ManifestSha256",op)),"ResultInvalid:"+op); break;
            case "Analyze": AnalyzeStarted(res); break;
            case "GetAnalysisProgress": AnalysisProgress(res); break;
            case "QuerySuggestions": Suggestions(res); break;
            case "QuerySuggestionFiles": SuggestionFiles(res); break;
            case "InvalidateAnalysis": Check(Req(res, "Invalidated", op) is bool && (bool)res["Invalidated"], "ResultInvalid:InvalidateAnalysis"); break;
            case "PrepareApproval": Prepared(res); break;
            case "BeginPrepareApproval": case "GetPreparationProgress":
                Check(IsId(Req(res,"PreparationId",op)) && IsText(Req(res,"Status",op),40) && IsText(Req(res,"Stage",op),80),"ResultInvalid:"+op);
                foreach(string key in new string[]{"CheckedFiles","TotalFiles"}) Check(IsInt(Req(res,key,op)) && ToLong(res[key])>=0,"ResultInvalid:"+op+"."+key);
                string prepStatus=(string)res["Status"];
                Check(prepStatus=="Running" || prepStatus=="Ready" || prepStatus=="Failed" || prepStatus=="Cancelled","ResultInvalid:Preparation.Status");
                Check(ToLong(res["CheckedFiles"])<=ToLong(res["TotalFiles"]),"ResultInvalid:Preparation.Counts");
                object ready=Req(res,"Prepared",op); if(ready!=null) { var draft=ready as IDictionary<string,object>;Check(draft!=null,"ResultInvalid:Preparation.Prepared");Prepared(draft); }
                Check((prepStatus=="Ready")== (ready!=null),"ResultInvalid:Preparation.Publication");
                object elapsed=Req(res,"ElapsedMilliseconds",op);Check(elapsed is int || elapsed is long || elapsed is double || elapsed is decimal,"ResultInvalid:Preparation.Elapsed");
                double elapsedValue=Convert.ToDouble(elapsed);Check(elapsedValue>=0 && !double.IsNaN(elapsedValue) && !double.IsInfinity(elapsedValue),"ResultInvalid:Preparation.Elapsed");
                break;
            case "CancelPreparation": Check(IsBool(Req(res,"CancellationRequested",op)),"ResultInvalid:CancelPreparation"); break;
            case "ConfigureStorageBudget":
                Check(IsInt(Req(res,"MaxStateBytes",op)) && ToLong(res["MaxStateBytes"])>=536870912L && IsBool(Req(res,"SessionOnly",op)),"ResultInvalid:ConfigureStorageBudget");
                object budgetRepairPending; if(res.TryGetValue("IndexRepairPending",out budgetRepairPending)) Check(IsBool(budgetRepairPending),"ResultInvalid:ConfigureStorageBudget.IndexRepairPending");
                break;
            case "QueryApprovalItems": ApprovalItems(res); break;
            case "ConfirmApproval": Confirmed(res); break;
            case "ExecuteApproved": Executed(res); break;
            case "GetExecutionResult": ExecutionResult(res); break;
            case "CancelAnalysis": Check(Req(res, "CancellationRequested", op) is bool && (bool)res["CancellationRequested"], "ResultInvalid:CancelAnalysis"); break;
            case "CancelExecution": Check(Req(res, "CancellationRequested", op) is bool, "ResultInvalid:CancelExecution"); break;
            case "ReleaseTask": Check(Req(res, "Released", op) is bool && (bool)res["Released"], "ResultInvalid:ReleaseTask"); break;
            default: throw Bad("OperationNotAllowed");
        }
    }

    private static bool IsHex64(object v) { string s = v as string; if (s == null || s.Length != 64) return false; foreach (char c in s) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false; return true; }
    private static bool IsObjId(object v) { string s = v as string; if (s == null || s.Length == 0 || s.Length > 80) return false; foreach (char c in s) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-' || c == '_')) return false; return true; }
    private static bool IsCursor(object v) { string s = v as string; if (s == null || s.Length == 0 || s.Length > 2048) return false; foreach (char c in s) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-' || c == '_')) return false; return true; }
    private static bool IsBool(object v) { return v is bool; }
    private static System.Collections.IList List(IDictionary<string, object> d, string key, string where, int max)
    {
        System.Collections.IList l = Req(d, key, where) as System.Collections.IList;
        Check(l != null && l.Count <= max, "ResultInvalid:" + where + "." + key);
        return l;
    }
    private static void TextList(IDictionary<string, object> d, string key, string where, int max, int itemMax)
    {
        foreach (object o in List(d, key, where, max)) Check(IsText(o, itemMax), "ResultInvalid:" + where + "." + key);
    }

    private static void AnalyzeStarted(IDictionary<string, object> r)
    {
        Check(IsId(Req(r, "AnalysisId", "Analyze")), "ResultInvalid:Analyze.AnalysisId");
        Check(IsText(Req(r, "Status", "Analyze"), 40), "ResultInvalid:Analyze.Status");
        Exploration(r, "Analyze");
    }

    private static void Exploration(IDictionary<string, object> r, string where)
    {
        Check(IsBool(Req(r, "HasResult", where)), "ResultInvalid:" + where + ".HasResult");
        object mode = Req(r, "ExplorationMode", where);
        Check(IsText(mode, 20) && ((string)mode == "Scope" || (string)mode == "Selected"), "ResultInvalid:" + where + ".ExplorationMode");
        IDictionary<string, object> p = Req(r, "Progress", where) as IDictionary<string, object>;
        Check(p != null, "ResultInvalid:" + where + ".Progress");
        foreach (string k in new string[] { "VisitedTargets", "QueuedTargets", "CompletedActions" })
            Check(IsInt(Req(p, k, where)) && ToLong(p[k]) >= 0, "ResultInvalid:" + where + "." + k);
        object target = Req(p, "CurrentTargetId", where);
        Check(target == null || IsObjId(target), "ResultInvalid:" + where + ".CurrentTargetId");
        Check(IsText(Req(p, "Reason", where), 400) && IsBool(Req(p, "HasMore", where)), "ResultInvalid:" + where + ".ProgressFields");
    }

    private static void AnalysisProgress(IDictionary<string, object> r)
    {
        Check(IsId(Req(r, "AnalysisId", "GetAnalysisProgress")), "ResultInvalid:GetAnalysisProgress.AnalysisId");
        Check(IsText(Req(r, "Status", "GetAnalysisProgress"), 80) && ((string)r["Status"]).Length > 0, "ResultInvalid:GetAnalysisProgress.Status");
        Check(IsNullableText(Req(r, "Reason", "GetAnalysisProgress"), 400), "ResultInvalid:GetAnalysisProgress.Reason");
        Exploration(r, "GetAnalysisProgress");
        object usage = Req(r, "Usage", "GetAnalysisProgress");
        if (usage != null)
        {
            IDictionary<string, object> u = usage as IDictionary<string, object>; Check(u != null, "ResultInvalid:GetAnalysisProgress.Usage");
            foreach (string k in new string[] { "Steps", "MetadataObjects", "ReadFiles", "SampleBytes", "HashBytes", "HashFiles" }) Check(IsInt(Req(u, k, "GetAnalysisProgress.Usage")) && ToLong(u[k]) >= 0, "ResultInvalid:GetAnalysisProgress.Usage." + k);
        }
    }

    private static void Space(IDictionary<string, object> r)
    {
        foreach (object o in List(r, "Items", "QuerySpace", 64))
        {
            IDictionary<string, object> item = o as IDictionary<string, object>; Check(item != null, "ResultInvalid:QuerySpace.Item");
            Check(IsObjId(Req(item, "ObjectId", "QuerySpace")) && IsText(Req(item, "Path", "QuerySpace"), 32768), "ResultInvalid:QuerySpace.Identity");
            Check(IsText(Req(item, "Kind", "QuerySpace"), 20) && IsText(Req(item, "Coverage", "QuerySpace"), 40), "ResultInvalid:QuerySpace.Kind");
            foreach (string k in new string[] { "ObservedLogicalBytes", "ObservedAllocatedBytes" })
            {
                object value = Req(item, k, "QuerySpace"); Check(IsNullableInt(value) && (value == null || ToLong(value) >= 0), "ResultInvalid:QuerySpace." + k);
            }
            foreach (string k in new string[] { "UnknownAllocationObjects", "HardLinkedFiles" })
                Check(IsInt(Req(item, k, "QuerySpace")) && ToLong(item[k]) >= 0, "ResultInvalid:QuerySpace." + k);
        }
        object next = Req(r, "NextCursor", "QuerySpace"); Check(next == null || IsCursor(next), "ResultInvalid:QuerySpace.NextCursor");
        Check(IsInt(Req(r, "Revision", "QuerySpace")) && IsText(Req(r, "Semantics", "QuerySpace"), 2000), "ResultInvalid:QuerySpace.Revision");
    }

    private static void Suggestions(IDictionary<string, object> r)
    {
        foreach (object o in List(r, "Items", "QuerySuggestions", 64))
        {
            IDictionary<string, object> s = o as IDictionary<string, object>; Check(s != null, "ResultInvalid:QuerySuggestions.Item");
            Check(IsId(Req(s, "SuggestionId", "QuerySuggestions.Item")), "ResultInvalid:QuerySuggestions.SuggestionId");
            Check(IsObjId(Req(s, "TargetId", "QuerySuggestions.Item")), "ResultInvalid:QuerySuggestions.TargetId");
            Check(IsText(Req(s, "Classification", "QuerySuggestions.Item"), 40) && IsText(Req(s, "Level", "QuerySuggestions.Item"), 40), "ResultInvalid:QuerySuggestions.Classification");
            Check(IsInt(Req(s, "CandidateCount", "QuerySuggestions.Item")) && ToLong(s["CandidateCount"]) >= 0, "ResultInvalid:QuerySuggestions.CandidateCount");
            Check(IsInt(Req(s, "LogicalBytes", "QuerySuggestions.Item")) && ToLong(s["LogicalBytes"]) >= 0, "ResultInvalid:QuerySuggestions.LogicalBytes");
            Check(IsText(Req(s, "Impact", "QuerySuggestions.Item"), 2000), "ResultInvalid:QuerySuggestions.Impact");
            TextList(s, "Doubts", "QuerySuggestions.Item", 32, 600);
            TextList(s, "EvidenceIds", "QuerySuggestions.Item", 64, 80);
            Check(IsBool(Req(s, "HardProtected", "QuerySuggestions.Item")) && IsBool(Req(s, "MayPrepareForReview", "QuerySuggestions.Item")), "ResultInvalid:QuerySuggestions.Flags");
            // 契约：任何建议都不得默认选中；受保护的建议不得声明可复核。
            Check(Req(s, "SelectedByDefault", "QuerySuggestions.Item") is bool && !(bool)s["SelectedByDefault"], "ResultInvalid:QuerySuggestions.SelectedByDefault");
            Check(!((bool)s["HardProtected"] && (bool)s["MayPrepareForReview"]), "ResultInvalid:QuerySuggestions.ProtectedButReviewable");
            Check(IsNullableText(Req(s, "ApprovalBlockedReason", "QuerySuggestions.Item"), 200), "ResultInvalid:QuerySuggestions.BlockedReason");
            object reasonField;
            foreach(string field in new string[] { "ReasonCategory", "ReasonCode", "ReviewHint" }) if(s.TryGetValue(field,out reasonField)) Check(IsText(reasonField,200),"ResultInvalid:QuerySuggestions."+field);
            object dup = Req(s, "DuplicateSummary", "QuerySuggestions.Item");
            if (dup != null) { IDictionary<string, object> d = dup as IDictionary<string, object>; Check(d != null, "ResultInvalid:QuerySuggestions.Duplicate"); }
        }
        object nx = Req(r, "NextAfterId", "QuerySuggestions"); Check(nx == null || IsCursor(nx), "ResultInvalid:QuerySuggestions.NextAfterId");
        Check(IsText(Req(r, "AnalysisStatus", "QuerySuggestions"), 80), "ResultInvalid:QuerySuggestions.Status");
        Check(IsInt(Req(r, "Revision", "QuerySuggestions")) && IsText(Req(r, "Sort", "QuerySuggestions"), 100) && IsText(Req(r, "CursorSchema", "QuerySuggestions"), 100), "ResultInvalid:QuerySuggestions.CursorBinding");
    }

    private static void SuggestionFiles(IDictionary<string, object> r)
    {
        foreach (object o in List(r, "Items", "QuerySuggestionFiles", 64))
        {
            IDictionary<string, object> f = o as IDictionary<string, object>; Check(f != null, "ResultInvalid:QuerySuggestionFiles.Item");
            Check(IsObjId(Req(f, "ObjectId", "QuerySuggestionFiles.Item")), "ResultInvalid:QuerySuggestionFiles.ObjectId");
            Check(IsText(Req(f, "Path", "QuerySuggestionFiles.Item"), 32768), "ResultInvalid:QuerySuggestionFiles.Path");
            Check(IsText(Req(f, "FileIdentity", "QuerySuggestionFiles.Item"), 200), "ResultInvalid:QuerySuggestionFiles.FileIdentity");
            Check(IsInt(Req(f, "LogicalBytes", "QuerySuggestionFiles.Item")) && IsInt(Req(f, "ModifiedUtcTicks", "QuerySuggestionFiles.Item")), "ResultInvalid:QuerySuggestionFiles.Numbers");
            Check(IsNullableText(Req(f, "ContentSha256", "QuerySuggestionFiles.Item"), 64), "ResultInvalid:QuerySuggestionFiles.ContentSha256");
        }
        object nx = Req(r, "NextAfterId", "QuerySuggestionFiles"); Check(nx == null || IsCursor(nx), "ResultInvalid:QuerySuggestionFiles.NextAfterId");
    }

    private static void Prepared(IDictionary<string, object> r)
    {
        Check(IsId(Req(r, "DraftId", "PrepareApproval")), "ResultInvalid:PrepareApproval.DraftId");
        Check(IsHex64(Req(r, "DisplayHash", "PrepareApproval")) && IsHex64(Req(r, "CandidateSetHash", "PrepareApproval")), "ResultInvalid:PrepareApproval.Hash");
        Check(IsInt(Req(r, "LogicalBytes", "PrepareApproval")) && ToLong(r["LogicalBytes"]) >= 0, "ResultInvalid:PrepareApproval.LogicalBytes");
        Check(IsInt(Req(r, "ItemCount", "PrepareApproval")) && ToLong(r["ItemCount"]) >= 1, "ResultInvalid:PrepareApproval.ItemCount");
        // 契约：复核草稿必须是只回收（RecycleOnly），不接受其它模式。
        Check(Req(r, "RecycleOnly", "PrepareApproval") is bool && (bool)r["RecycleOnly"], "ResultInvalid:PrepareApproval.RecycleOnly");
        Check(IsText(Req(r, "AlgorithmMode", "PrepareApproval"), 40) && (string)r["AlgorithmMode"] == "Heuristic" && IsBool(Req(r, "RecycleEnabled", "PrepareApproval")), "ResultInvalid:PrepareApproval.Flags");
    }

    private static void ApprovalItems(IDictionary<string, object> r)
    {
        Check(IsHex64(Req(r, "DisplayHash", "QueryApprovalItems")) && IsHex64(Req(r, "CandidateSetHash", "QueryApprovalItems")), "ResultInvalid:QueryApprovalItems.Hash");
        Check(IsInt(Req(r, "LogicalBytes", "QueryApprovalItems")), "ResultInvalid:QueryApprovalItems.LogicalBytes");
        foreach (object o in List(r, "Items", "QueryApprovalItems", 64))
        {
            IDictionary<string, object> i = o as IDictionary<string, object>; Check(i != null, "ResultInvalid:QueryApprovalItems.Item");
            Check(IsId(Req(i, "SuggestionId", "QueryApprovalItems.Item")), "ResultInvalid:QueryApprovalItems.SuggestionId");
            IDictionary<string, object> f = Req(i, "File", "QueryApprovalItems.Item") as IDictionary<string, object>; Check(f != null, "ResultInvalid:QueryApprovalItems.File");
            Check(IsText(Req(f, "ObjectId", "QueryApprovalItems.File"), 80) && IsText(Req(f, "Path", "QueryApprovalItems.File"), 32768) && IsText(Req(f, "Identity", "QueryApprovalItems.File"), 200), "ResultInvalid:QueryApprovalItems.FileFields");
            Check(IsInt(Req(f, "Size", "QueryApprovalItems.File")) && IsText(Req(f, "ModifiedUtc", "QueryApprovalItems.File"), 64), "ResultInvalid:QueryApprovalItems.FileSize");
            Check(Req(i, "Ancestors", "QueryApprovalItems.Item") is System.Collections.IList && Req(i, "RetainedCopies", "QueryApprovalItems.Item") is System.Collections.IList, "ResultInvalid:QueryApprovalItems.Lists");
        }
        object nx = Req(r, "NextAfter", "QueryApprovalItems"); Check(IsNullableInt(nx), "ResultInvalid:QueryApprovalItems.NextAfter");
    }

    private static void Confirmed(IDictionary<string, object> r)
    {
        Check(IsId(Req(r, "ApprovalId", "ConfirmApproval")) && IsBool(Req(r, "RecycleEnabled", "ConfirmApproval")), "ResultInvalid:ConfirmApproval");
        object can; if (r.TryGetValue("CanExecute", out can)) Check(IsBool(can), "ResultInvalid:ConfirmApproval.CanExecute");
    }

    private static void Executed(IDictionary<string, object> r)
    {
        Check(IsId(Req(r, "ExecutionId", "ExecuteApproved")) && IsText(Req(r, "Status", "ExecuteApproved"), 40) && IsBool(Req(r, "RecycleEnabled", "ExecuteApproved")), "ResultInvalid:ExecuteApproved");
    }

    private static void ExecutionResult(IDictionary<string, object> r)
    {
        Check(IsText(Req(r, "Status", "GetExecutionResult"), 60) && ((string)r["Status"]).Length > 0, "ResultInvalid:GetExecutionResult.Status");
        foreach (object o in List(r, "Entries", "GetExecutionResult", 64))
        {
            IDictionary<string, object> e = o as IDictionary<string, object>; Check(e != null, "ResultInvalid:GetExecutionResult.Entry");
            object path; if(e.TryGetValue("Path",out path)) Check(IsText(path,32768),"ResultInvalid:GetExecutionResult.Path");
            Check(IsText(Req(e, "ObjectId", "GetExecutionResult.Entry"), 80) && IsText(Req(e, "Status", "GetExecutionResult.Entry"), 40) && IsText(Req(e, "Reason", "GetExecutionResult.Entry"), 400) && IsInt(Req(e, "LogicalBytes", "GetExecutionResult.Entry")), "ResultInvalid:GetExecutionResult.EntryFields");
        }
        Check(IsNullableInt(Req(r, "NextAfter", "GetExecutionResult")), "ResultInvalid:GetExecutionResult.NextAfter");
        object bytes; if (r.TryGetValue("RecycledLogicalBytes", out bytes)) Check(IsInt(bytes), "ResultInvalid:GetExecutionResult.RecycledLogicalBytes");
        foreach(string field in new string[] { "LedgerEntries","ExpectedItems","FinalItems","RecycledItems","SkippedItems","UnknownItems" }) if(r.TryGetValue(field,out bytes)) Check(IsInt(bytes) && ToLong(bytes)>=0,"ResultInvalid:GetExecutionResult."+field);
    }

    private static void Health(IDictionary<string, object> r)
    {
        // Mode 不做固定值匹配：新 Host 可能声明其它阶段；只要求是合理的标识符。
        object mode = Req(r, "Mode", "Health");
        Check(IsText(mode, 40) && ((string)mode).Length > 0, "ResultInvalid:Health.Mode");
        Check(Req(r, "ProtocolVersion", "Health") is int && (int)r["ProtocolVersion"] == 1, "ResultInvalid:Health.ProtocolVersion");
        Check(IsInt(Req(r, "ContractVersion", "Health")) && ToLong(r["ContractVersion"]) == 3, "ResultInvalid:Health.ContractVersion");
        Check(IsText(Req(r, "ModelMode", "Health"), 20) && (string)r["ModelMode"] == "Absent" && IsText(Req(r, "AlgorithmMode", "Health"), 40) && (string)r["AlgorithmMode"] == "Heuristic", "ResultInvalid:Health.EngineMode");
        Check(IsInt(Req(r, "SchemaVersion", "Health")) && ToLong(r["SchemaVersion"]) >= 1, "ResultInvalid:Health.SchemaVersion");
        Check(IsInt(Req(r, "MaxMessageBytes", "Health")) && ToLong(r["MaxMessageBytes"]) >= 1024 && ToLong(r["MaxMessageBytes"]) <= 32768, "ResultInvalid:Health.MaxMessageBytes");
        Check(IsInt(Req(r, "MaxResponseBytes", "Health")) && ToLong(r["MaxResponseBytes"]) >= 1024 && ToLong(r["MaxResponseBytes"]) <= 262144, "ResultInvalid:Health.MaxResponseBytes");
        Check(IsInt(Req(r, "MaxPageSize", "Health")) && ToLong(r["MaxPageSize"]) >= 1 && ToLong(r["MaxPageSize"]) <= 64, "ResultInvalid:Health.MaxPageSize");
        System.Collections.IList ops = Req(r, "Operations", "Health") as System.Collections.IList;
        Check(ops != null && ops.Count > 0 && ops.Count <= 64, "ResultInvalid:Health.Operations");
        HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (object o in ops) Check(IsText(o, 40) && ((string)o).Length > 0 && seen.Add((string)o), "ResultInvalid:Health.Operations");
        foreach (string need in new string[] { "Health", "CreateInventory", "GetProgress", "QueryGroups", "QueryEvidence", "Pause", "Resume", "Cancel" })
            Check(seen.Contains(need), "ResultInvalid:Health.OperationMissing");
        IDictionary<string, object> cd = Req(r, "Capabilities", "Health") as IDictionary<string, object>;
        Check(cd != null && cd.Count <= 40, "ResultInvalid:Health.Capabilities");
        foreach (KeyValuePair<string, object> kv in cd) Check(kv.Key.Length > 0 && kv.Key.Length <= 60, "ResultInvalid:Health.Capabilities");
        Check(IsBool(Req(cd, "HeuristicExploration", "Health.Capabilities")) && (bool)cd["HeuristicExploration"], "ResultInvalid:Health.HeuristicExploration");
        foreach (string k in new string[] { "ModelIncluded", "ModelReady", "ModelAvailable", "ModelEnabledByDefault" })
            Check(IsBool(Req(cd, k, "Health.Capabilities")) && !(bool)cd[k], "ResultInvalid:Health.ModelNotAbsent");
    }

    private static void TaskView(IDictionary<string, object> t, string where)
    {
        Check(IsId(Req(t, "TaskId", where)), "ResultInvalid:" + where + ".TaskId");
        Check(IsText(Req(t, "State", where), 40) && ((string)t["State"]).Length > 0, "ResultInvalid:" + where + ".State");
        Check(IsNullableText(Req(t, "Reason", where), 200), "ResultInvalid:" + where + ".Reason");
        Check(IsInt(Req(t, "EvidenceRevision", where)), "ResultInvalid:" + where + ".EvidenceRevision");
        Check(IsText(Req(t, "CreatedUtc", where), 64) && IsText(Req(t, "UpdatedUtc", where), 64), "ResultInvalid:" + where + ".Utc");
    }

    private static void Progress(IDictionary<string, object> r, string taskId)
    {
        IDictionary<string, object> t = Req(r, "Task", "GetProgress") as IDictionary<string, object>;
        Check(t != null, "ResultInvalid:GetProgress.Task");
        TaskView(t, "GetProgress.Task");
        Check((string)t["TaskId"] == taskId, "ResponseTaskMismatch");
        IDictionary<string, object> c = Req(r, "Coverage", "GetProgress") as IDictionary<string, object>;
        Check(c != null, "ResultInvalid:GetProgress.Coverage");
        foreach (string k in new string[] { "ObservedObjects", "PendingDirectories", "SkippedObjects", "ObservedLogicalBytes", "ObservedAllocatedBytes", "UnknownAllocationObjects" })
            Check(IsNullableInt(Req(c, k, "GetProgress.Coverage")), "ResultInvalid:GetProgress.Coverage." + k);
        object sem;
        if (r.TryGetValue("Semantics", out sem)) Check(IsText(sem, 1000), "ResultInvalid:GetProgress.Semantics");
    }

    private static System.Collections.IList Items(IDictionary<string, object> r, string op)
    {
        System.Collections.IList items = Req(r, "Items", op) as System.Collections.IList;
        Check(items != null && items.Count <= 64, "ResultInvalid:" + op + ".Items");
        Check(IsNullableInt(Req(r, "NextAfter", op)), "ResultInvalid:" + op + ".NextAfter");
        object sem;
        if (r.TryGetValue("Semantics", out sem)) Check(IsText(sem, 1000), "ResultInvalid:" + op + ".Semantics");
        return items;
    }

    private static void Groups(IDictionary<string, object> r)
    {
        foreach (object o in Items(r, "QueryGroups"))
        {
            IDictionary<string, object> g = o as IDictionary<string, object>;
            Check(g != null, "ResultInvalid:QueryGroups.Item");
            Check(IsInt(Req(g, "GroupId", "QueryGroups.Item")) && ToLong(g["GroupId"]) > 0, "ResultInvalid:QueryGroups.GroupId");
            Check(IsText(Req(g, "Path", "QueryGroups.Item"), 32768), "ResultInvalid:QueryGroups.Path");
            Check(IsText(Req(g, "Coverage", "QueryGroups.Item"), 40), "ResultInvalid:QueryGroups.Coverage");
            Check(IsNullableText(Req(g, "Reason", "QueryGroups.Item"), 200), "ResultInvalid:QueryGroups.Reason");
            Check(IsInt(Req(g, "ObservedDirectChildren", "QueryGroups.Item")), "ResultInvalid:QueryGroups.Children");
            Check(IsNullableInt(Req(g, "DirectLogicalBytes", "QueryGroups.Item")) && IsNullableInt(Req(g, "DirectAllocatedBytes", "QueryGroups.Item")), "ResultInvalid:QueryGroups.Bytes");
            foreach (string k in new string[] { "FactType", "Classification", "SuggestedAction" }) Check(IsText(Req(g, k, "QueryGroups.Item"), 80), "ResultInvalid:QueryGroups." + k);
            Check(IsNullableText(Req(g, "Protection", "QueryGroups.Item"), 200), "ResultInvalid:QueryGroups.Protection");
        }
    }

    private static void Evidence(IDictionary<string, object> r)
    {
        foreach (object o in Items(r, "QueryEvidence"))
        {
            IDictionary<string, object> e = o as IDictionary<string, object>;
            Check(e != null, "ResultInvalid:QueryEvidence.Item");
            Check(IsInt(Req(e, "EvidenceId", "QueryEvidence.Item")) && ToLong(e["EvidenceId"]) > 0, "ResultInvalid:QueryEvidence.EvidenceId");
            Check(IsNullableInt(Req(e, "ParentId", "QueryEvidence.Item")), "ResultInvalid:QueryEvidence.ParentId");
            Check(IsText(Req(e, "Path", "QueryEvidence.Item"), 32768), "ResultInvalid:QueryEvidence.Path");
            Check(IsText(Req(e, "Kind", "QueryEvidence.Item"), 40) && IsText(Req(e, "Coverage", "QueryEvidence.Item"), 40), "ResultInvalid:QueryEvidence.Kind");
            Check(IsNullableText(Req(e, "FileIdentity", "QueryEvidence.Item"), 200), "ResultInvalid:QueryEvidence.FileIdentity");
            foreach (string k in new string[] { "Attributes", "LinkCount", "LogicalBytes", "AllocatedBytes" }) Check(IsNullableInt(Req(e, k, "QueryEvidence.Item")), "ResultInvalid:QueryEvidence." + k);
            Check(IsNullableText(Req(e, "ModifiedUtc", "QueryEvidence.Item"), 64) && IsText(Req(e, "ObservedUtc", "QueryEvidence.Item"), 64), "ResultInvalid:QueryEvidence.Utc");
            Check(IsNullableText(Req(e, "SkippedReason", "QueryEvidence.Item"), 200) && IsNullableText(Req(e, "Protection", "QueryEvidence.Item"), 200), "ResultInvalid:QueryEvidence.Reason");
            Check(IsText(Req(e, "DetectorVersion", "QueryEvidence.Item"), 80), "ResultInvalid:QueryEvidence.DetectorVersion");
        }
    }

    private static void Storage(IDictionary<string,object> r)
    {
        foreach(string k in new string[] { "DbBytes","WalBytes","ShmBytes","LockBytes","TotalBytes","MaxStateBytes","PageSize","PageCount","FreePages","ReusableBytes","Tasks","Objects","EstimatedBackupBytes","EstimatedVacuumBytes","SafetyReserveBytes","EstimatedExtraBytes","AvailableDriveBytes" })
            Check(IsInt(Req(r,k,"GetStorageInfo")) && ToLong(r[k])>=0,"ResultInvalid:GetStorageInfo."+k);
        Check(IsBool(Req(r,"CanCompact","GetStorageInfo")) && IsNullableText(Req(r,"CompactionReason","GetStorageInfo"),100),"ResultInvalid:GetStorageInfo.Flags");
        object storageRepairPending; if(r.TryGetValue("IndexRepairPending",out storageRepairPending)) Check(IsBool(storageRepairPending),"ResultInvalid:GetStorageInfo.IndexRepairPending");
    }
    private static void ApprovalStorage(IDictionary<string,object> r)
    {
        Check(r!=null,"ResultInvalid:ApprovalStorage");
        foreach(string k in new string[] { "Bytes","Files","Drafts","Seals","Claims","Ledgers","MaxBytes","MaxFiles","ReclaimableDrafts","ReclaimableBytes" }) Check(IsInt(Req(r,k,"ApprovalStorage")) && ToLong(r[k])>=0,"ResultInvalid:ApprovalStorage."+k);
        Check(IsBool(Req(r,"CanPrepare","ApprovalStorage")) && IsNullableText(Req(r,"LimitReason","ApprovalStorage"),100),"ResultInvalid:ApprovalStorage.Flags");
    }

    private static void ListTasks(IDictionary<string, object> r)
    {
        System.Collections.IList items = Req(r, "Items", "ListTasks") as System.Collections.IList;
        Check(items != null && items.Count <= 64, "ResultInvalid:ListTasks.Items");
        foreach (object o in items) { IDictionary<string, object> t = o as IDictionary<string, object>; Check(t != null, "ResultInvalid:ListTasks.Item"); TaskView(t, "ListTasks.Item"); }
        foreach(object o in items)
        {
            var t=(IDictionary<string,object>)o; object value;
            foreach(string k in new string[] { "RootPath","Drive","ScanMode" }) if(t.TryGetValue(k,out value)) Check(IsText(value,k=="RootPath"?32768:40),"ResultInvalid:ListTasks."+k);
            foreach(string k in new string[] { "ObservedObjects","SkippedObjects","ObservedLogicalBytes" }) if(t.TryGetValue(k,out value)) Check(IsNullableInt(value),"ResultInvalid:ListTasks."+k);
        }
        object next = Req(r, "NextAfterTaskId", "ListTasks");
        Check(next == null || IsId(next), "ResultInvalid:ListTasks.NextAfterTaskId");
    }

    private static void BatchSummaryFields(IDictionary<string, object> b, string where)
    {
        Check(IsId(Req(b, "BatchId", where)), "ResultInvalid:" + where + ".BatchId");
        Check(IsText(Req(b, "ScanMode", where), 40) && (string)b["ScanMode"] == "AllFixedDisks", "ResultInvalid:" + where + ".ScanMode");
        Check(IsText(Req(b, "State", where), 40) && ((string)b["State"]).Length > 0, "ResultInvalid:" + where + ".State");
        Check(IsNullableText(Req(b, "Reason", where), 400), "ResultInvalid:" + where + ".Reason");
        Check(IsInt(Req(b, "Revision", where)) && ToLong(b["Revision"]) >= 1, "ResultInvalid:" + where + ".Revision");
        Check(IsText(Req(b, "CreatedUtc", where), 64) && IsText(Req(b, "UpdatedUtc", where), 64), "ResultInvalid:" + where + ".Utc");
        Check(IsInt(Req(b, "EntryCount", where)) && ToLong(b["EntryCount"]) >= 1 && ToLong(b["EntryCount"]) <= 26, "ResultInvalid:" + where + ".EntryCount");
    }

    private static void BatchSnapshot(IDictionary<string, object> r, string where)
    {
        BatchSummaryFields(r, where);
        Check(IsBool(Req(r, "CanContinue", where)), "ResultInvalid:" + where + ".CanContinue");
        System.Collections.IList entries = List(r, "Entries", where, 26);
        Check(entries.Count == (int)ToLong(r["EntryCount"]), "ResultInvalid:" + where + ".EntriesCount");
        for (int i = 0; i < entries.Count; i++)
        {
            IDictionary<string, object> e = entries[i] as IDictionary<string, object>;
            Check(e != null, "ResultInvalid:" + where + ".Entry");
            Check(IsInt(Req(e, "EntryIndex", where)) && ToLong(e["EntryIndex"]) == i, "ResultInvalid:" + where + ".EntryIndex");
            Check(IsText(Req(e, "RootPath", where), 32768) && ((string)e["RootPath"]).Length > 0, "ResultInvalid:" + where + ".RootPath");
            object tid = Req(e, "TaskId", where);
            Check(tid == null || IsId(tid), "ResultInvalid:" + where + ".TaskId");
            Check(IsText(Req(e, "State", where), 40) && ((string)e["State"]).Length > 0, "ResultInvalid:" + where + ".EntryState");
            Check(IsNullableText(Req(e, "Reason", where), 400), "ResultInvalid:" + where + ".EntryReason");
        }
    }

    private static void ListBatches(IDictionary<string, object> r)
    {
        System.Collections.IList items = List(r, "Items", "ListBatches", 64);
        foreach (object o in items)
        {
            IDictionary<string, object> b = o as IDictionary<string, object>;
            Check(b != null, "ResultInvalid:ListBatches.Item");
            BatchSummaryFields(b, "ListBatches.Item");
        }
        object next = Req(r, "NextAfterBatchId", "ListBatches");
        Check(next == null || IsId(next), "ResultInvalid:ListBatches.NextAfterBatchId");
    }

    private static void StartBatchEntry(IDictionary<string, object> r)
    {
        Check(IsId(Req(r, "BatchId", "StartBatchEntry")), "ResultInvalid:StartBatchEntry.BatchId");
        Check(IsInt(Req(r, "Revision", "StartBatchEntry")) && ToLong(r["Revision"]) >= 1, "ResultInvalid:StartBatchEntry.Revision");
        Check(IsInt(Req(r, "EntryIndex", "StartBatchEntry")) && ToLong(r["EntryIndex"]) >= 0 && ToLong(r["EntryIndex"]) < 26, "ResultInvalid:StartBatchEntry.EntryIndex");
        Check(IsId(Req(r, "TaskId", "StartBatchEntry")), "ResultInvalid:StartBatchEntry.TaskId");
        Check(IsText(Req(r, "State", "StartBatchEntry"), 40) && ((string)r["State"]).Length > 0, "ResultInvalid:StartBatchEntry.State");
        Check(IsNullableText(Req(r, "Reason", "StartBatchEntry"), 400), "ResultInvalid:StartBatchEntry.Reason");
    }
}

public sealed class SjcExplorerBridge
{
    public const int MaxRequestBytes = 32768;
    public const int MaxResponseBytes = 262144;
    private const int MaxQueuedLines = 4;
    private const int MaxStderrLines = 40;
    private const int MaxStderrChars = 400;
    private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
    private readonly ConcurrentQueue<string> errLines = new ConcurrentQueue<string>();
    private readonly JavaScriptSerializer json = new JavaScriptSerializer();
    private readonly UTF8Encoding strict = new UTF8Encoding(false, true);
    private readonly UTF8Encoding plain = new UTF8Encoding(false);
    private Process process;
    private Task writeTask;
    private string pendingId, pendingOp, pendingTask;
    private long deadline;
    private volatile string fault;
    private volatile bool stdoutClosed;
    public Task ClosedTask;

    public SjcExplorerBridge() { json.RecursionLimit = 16; json.MaxJsonLength = MaxResponseBytes * 2; }
    public string Fault { get { return fault; } }
    public bool Pending { get { return pendingId != null; } }
    public bool Started { get { return process != null; } }
    public string PendingOperation { get { return pendingOp; } }

    public void Start(string exe, string args, string workDir, string dotnetRoot)
    {
        if (process != null) throw new InvalidOperationException("AlreadyStarted");
        ProcessStartInfo psi = new ProcessStartInfo(exe, args);
        psi.UseShellExecute = false; psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = plain; psi.StandardErrorEncoding = plain;
        if (!string.IsNullOrEmpty(workDir)) psi.WorkingDirectory = workDir;
        List<string> drop = new List<string>();
        foreach (System.Collections.DictionaryEntry kv in psi.EnvironmentVariables)
        {
            string k = (string)kv.Key;
            if (k.StartsWith("DOTNET_", StringComparison.OrdinalIgnoreCase) || k.StartsWith("COMPlus_", StringComparison.OrdinalIgnoreCase) || k.StartsWith("CORECLR_", StringComparison.OrdinalIgnoreCase) || k.StartsWith("CORE_", StringComparison.OrdinalIgnoreCase)) drop.Add(k);
        }
        foreach (string k in drop) psi.EnvironmentVariables.Remove(k);
        if (!string.IsNullOrEmpty(dotnetRoot)) psi.EnvironmentVariables["DOTNET_ROOT"] = dotnetRoot;
        psi.EnvironmentVariables["DOTNET_NOLOGO"] = "1"; psi.EnvironmentVariables["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1";
        process = Process.Start(psi);
        Stream so = process.StandardOutput.BaseStream, se = process.StandardError.BaseStream;
        Task.Factory.StartNew(delegate { ReadStdout(so); }, TaskCreationOptions.LongRunning);
        Task.Factory.StartNew(delegate { ReadStderr(se); }, TaskCreationOptions.LongRunning);
    }

    private void ReadStdout(Stream s)
    {
        try
        {
            byte[] buf = new byte[8192]; MemoryStream line = new MemoryStream(); int n;
            while ((n = s.Read(buf, 0, buf.Length)) > 0)
            {
                for (int i = 0; i < n; i++)
                {
                    byte b = buf[i];
                    if (b != 10)
                    {
                        if (line.Length >= MaxResponseBytes) { fault = "ResponseTooLarge"; return; }
                        line.WriteByte(b); continue;
                    }
                    string text;
                    try { text = strict.GetString(line.GetBuffer(), 0, (int)line.Length); }
                    catch (ArgumentException) { fault = "InvalidUtf8"; return; }
                    line.SetLength(0);
                    if (text.EndsWith("\r")) text = text.Substring(0, text.Length - 1);
                    if (lines.Count >= MaxQueuedLines) { fault = "UnsolicitedOutput"; return; }
                    lines.Enqueue(text);
                }
            }
            stdoutClosed = true;
        }
        catch (Exception) { if (fault == null) fault = "StdoutReadFailed"; }
    }

    private void ReadStderr(Stream s)
    {
        try
        {
            byte[] buf = new byte[1024]; StringBuilder cur = new StringBuilder(); int n;
            while ((n = s.Read(buf, 0, buf.Length)) > 0)
            {
                foreach (char c in plain.GetString(buf, 0, n))
                {
                    if (c == '\n')
                    {
                        errLines.Enqueue(cur.ToString().Trim()); cur.Length = 0;
                        string drop; while (errLines.Count > MaxStderrLines) errLines.TryDequeue(out drop);
                    }
                    else if (cur.Length < MaxStderrChars && c != '\r') cur.Append(c);
                }
            }
        }
        catch (Exception) { }
    }
    public string[] TakeStderr()
    {
        List<string> all = new List<string>(); string l;
        while (errLines.TryDequeue(out l)) all.Add(l);
        return all.ToArray();
    }

    private string armedExecution;
    public void ArmExecution(string approvalId)
    {
        Guid g; if (!Guid.TryParseExact(approvalId, "D", out g) || g == Guid.Empty) throw new ArgumentException("InvalidApprovalId");
        armedExecution = g.ToString("D");
    }

    public string BeginRequest(string operation, string taskId, Dictionary<string, object> payload, int timeoutMs)
    {
        if (process == null) throw new InvalidOperationException("NotStarted");
        if (fault != null) throw new InvalidOperationException(fault);
        if (pendingId != null) throw new InvalidOperationException("RequestInFlight");
        bool needsTask;
        string keys;
        switch (operation)
        {
            case "Health": needsTask = false; keys = "|"; break;
            case "ListTasks": needsTask = false; keys = "AfterTaskId,PageSize|PathFilter"; break;
            case "CreateBatch": needsTask = false; keys = "BatchId,Roots|"; break;
            case "ListBatches": needsTask = false; keys = "AfterBatchId,PageSize|"; break;
            case "GetBatch": needsTask = false; keys = "BatchId|"; break;
            case "ContinueBatch": needsTask = false; keys = "BatchId,ExpectedRevision,Confirmed|"; break;
            case "StartBatchEntry": needsTask = false; keys = "BatchId,EntryIndex,ExpectedRevision|"; break;
            case "PauseBatch": case "CancelBatch": case "StopBatch": needsTask = false; keys = "BatchId,ExpectedRevision|"; break;
            case "GetStorageInfo": case "GetSessionInfo": needsTask = false; keys = "|"; break;
            case "CompactState": case "ArchiveUnconfirmedDrafts": case "ReleaseFinishedSessions": needsTask = false; keys = "Confirmed|"; break;
            case "CreateInventory": needsTask = false; keys = "SelectedPath|ScanMode"; break;
            case "GetProgress": case "Pause": case "Resume": case "Cancel": case "ReleaseTask": needsTask = true; keys = "|"; break;
            case "QueryGroups": needsTask = true; keys = "AfterId,PageSize|"; break;
            case "QueryEvidence": needsTask = true; keys = "AfterId,PageSize,ParentId|"; break;
            case "QuerySpace": case "QuerySpaceAsync": needsTask = true; keys = "AfterCursor,PageSize|"; break;
            case "Analyze": needsTask = true; keys = "TargetId,ExpectedEvidenceRevision,ExplorationMode|"; break;
            case "GetAnalysisProgress": case "InvalidateAnalysis": case "CancelAnalysis": needsTask = true; keys = "AnalysisId|"; break;
            case "QuerySuggestions": needsTask = true; keys = "AnalysisId,AfterId,PageSize|"; break;
            case "QuerySuggestionFiles": needsTask = true; keys = "AnalysisId,SuggestionId,AfterId,PageSize|"; break;
            case "PrepareApproval": case "BeginPrepareApproval": needsTask = true; keys = "AnalysisId,SuggestionIds,ExpectedEvidenceRevision|"; break;
            case "GetPreparationProgress": case "CancelPreparation": needsTask = true; keys = "PreparationId|"; break;
            case "ConfigureStorageBudget": needsTask = false; keys = "Mebibytes,Confirmed|"; break;
            case "QueryApprovalItems": needsTask = true; keys = "DraftId,AfterId,PageSize|"; break;
            case "ConfirmApproval": needsTask = true; keys = "DraftId,DisplayHash|"; break;
            case "ExecuteApproved": case "CancelExecution": needsTask = true; keys = "ApprovalId|"; break;
            case "GetExecutionResult": needsTask = true; keys = "ApprovalId,AfterEntry,PageSize|"; break;
            default: throw new ArgumentException("OperationNotAllowed");
        }
        string[] kp = keys.Split('|');
        HashSet<string> required = new HashSet<string>(kp[0].Length == 0 ? new string[0] : kp[0].Split(','), StringComparer.Ordinal);
        HashSet<string> optional = new HashSet<string>(kp[1].Length == 0 ? new string[0] : kp[1].Split(','), StringComparer.Ordinal);
        int present = 0;
        if (payload != null)
            foreach (string k in payload.Keys)
            {
                if (!required.Contains(k) && !optional.Contains(k)) throw new ArgumentException("PayloadFieldNotAllowed:" + k);
                if (required.Contains(k)) present++;
            }
        if (present != required.Count) throw new ArgumentException("PayloadFieldMissing");
        if (operation == "ExecuteApproved")
        {
            // 结构性保护：只有用户在界面上明确确认后调用 ArmExecution(approvalId) 才能发送一次执行请求。
            object want; string armed = armedExecution; armedExecution = null;
            if (armed == null || payload == null || !payload.TryGetValue("ApprovalId", out want) || !string.Equals(want as string, armed, StringComparison.Ordinal)) throw new ArgumentException("ExecuteNotArmed");
        }
        string id = Guid.NewGuid().ToString("D");
        if (taskId == string.Empty) taskId = null; // PowerShell 把 $null 传给 string 参数时会变成空串
        if (taskId != null)
        {
            Guid g;
            if (!Guid.TryParseExact(taskId, "D", out g) || g == Guid.Empty) throw new ArgumentException("InvalidTaskId");
            taskId = g.ToString("D");
        }
        if (needsTask != (taskId != null)) throw new ArgumentException("TaskIdMismatchForOperation");
        Dictionary<string, object> req = new Dictionary<string, object>();
        req["ProtocolVersion"] = 1; req["RequestId"] = id; req["TaskId"] = taskId; req["Operation"] = operation;
        req["Payload"] = payload != null ? payload : new Dictionary<string, object>();
        byte[] data = plain.GetBytes(json.Serialize(req) + "\n");
        if (data.Length > MaxRequestBytes) throw new ArgumentException("RequestTooLarge");
        pendingId = id; pendingOp = operation; pendingTask = taskId;
        deadline = Stopwatch.GetTimestamp() + (long)timeoutMs * Stopwatch.Frequency / 1000;
        Stream stdin = process.StandardInput.BaseStream;
        writeTask = Task.Factory.StartNew(delegate { stdin.Write(data, 0, data.Length); stdin.Flush(); });
        return id;
    }

    // 非阻塞：返回已校验的响应字典，否则返回 null；失败时设置 Fault（此后不再可用，需要重启 Host）。
    public Dictionary<string, object> Poll()
    {
        if (fault != null) return null;
        if (pendingId == null)
        {
            if (!lines.IsEmpty) fault = "UnsolicitedOutput";
            else if (stdoutClosed && process != null) fault = "HostExited";
            return null;
        }
        if (writeTask != null && writeTask.IsFaulted) { fault = "WriteFailed"; return null; }
        string line;
        if (lines.TryDequeue(out line))
        {
            try { Dictionary<string, object> r = Validate(line); pendingId = null; return r; }
            catch (InvalidOperationException ex) { fault = ex.Message; }
            catch (Exception) { fault = "ResponseParseFailed"; }
            return null;
        }
        if (stdoutClosed && lines.IsEmpty) { fault = "HostExited"; return null; }
        if (Stopwatch.GetTimestamp() > deadline) fault = "RequestTimeout";
        return null;
    }

    private static InvalidOperationException Bad(string code) { return new InvalidOperationException(code); }
    private static bool IsId(object v, out string text)
    {
        Guid g; text = v as string;
        if (text == null || !Guid.TryParseExact(text, "D", out g) || g == Guid.Empty) return false;
        text = g.ToString("D"); return true;
    }

    private Dictionary<string, object> Validate(string line)
    {
        string guard = SjcJsonGuard.Check(line);
        if (guard != null) throw Bad(guard);
        Dictionary<string, object> o = json.DeserializeObject(line) as Dictionary<string, object>;
        if (o == null) throw Bad("ResponseNotObject");
        if (!o.ContainsKey("Ok") || !(o["Ok"] is bool)) throw Bad("ResponseOkInvalid");
        bool ok = (bool)o["Ok"];
        string[] allowed = { "ProtocolVersion", "RequestId", "TaskId", "Ok", ok ? "Result" : "Error" };
        if (o.Count != allowed.Length) throw Bad("ResponseFieldMismatch");
        foreach (string k in allowed) if (!o.ContainsKey(k)) throw Bad("ResponseFieldMismatch");
        if (!(o["ProtocolVersion"] is int) || (int)o["ProtocolVersion"] != 1) throw Bad("ResponseVersionMismatch");
        string rid; if (!IsId(o["RequestId"], out rid) || rid != pendingId) throw Bad("ResponseRequestMismatch");
        string tid = null;
        if (o["TaskId"] != null && !IsId(o["TaskId"], out tid)) throw Bad("ResponseTaskInvalid");
        if ((pendingOp == "Health" || pendingOp == "ListTasks" || pendingOp == "CreateBatch" || pendingOp == "ListBatches" || pendingOp == "GetBatch" || pendingOp == "ContinueBatch" || pendingOp == "StartBatchEntry" || pendingOp == "PauseBatch" || pendingOp == "CancelBatch" || pendingOp == "StopBatch") && tid != null) throw Bad("ResponseTaskMismatch");
        if (pendingTask != null && tid != pendingTask) throw Bad("ResponseTaskMismatch");
        if (pendingOp == "ConfigureStorageBudget" && tid != null) throw Bad("ResponseTaskMismatch");
        if (ok)
        {
            Dictionary<string, object> res = o["Result"] as Dictionary<string, object>;
            if (res == null) throw Bad("ResultNotObject");
            SjcResultSchema.Validate(pendingOp, res, tid);
        }
        else
        {
            Dictionary<string, object> err = o["Error"] as Dictionary<string, object>;
            string code = err != null && err.ContainsKey("Code") ? err["Code"] as string : null;
            if (err == null || code == null || code.Length == 0 || code.Length > 100) throw Bad("ErrorShapeInvalid");
            foreach(var pair in err)
            {
                if(pair.Key=="Code") continue;
                if((pendingOp=="CompactState" && (pair.Key=="Stage" || pair.Key=="BackupPath")) || (pendingOp=="ArchiveUnconfirmedDrafts" && pair.Key=="ArchivePath"))
                { if(pair.Value!=null && (!(pair.Value is string) || ((string)pair.Value).Length>32768)) throw Bad("ErrorShapeInvalid"); }
                else if(pendingOp=="CompactState" && (pair.Key=="BeforeBytes" || pair.Key=="BackupBytes")) { if(!(pair.Value is int || pair.Value is long)) throw Bad("ErrorShapeInvalid"); }
                else if(pendingOp=="CompactState" && (pair.Key=="StatePathRetained" || pair.Key=="BackupExists" || pair.Key=="AutomaticRestorePerformed")) { if(!(pair.Value is bool)) throw Bad("ErrorShapeInvalid"); }
                else if(pendingOp=="ArchiveUnconfirmedDrafts" && pair.Key=="MovedFiles") { var l=pair.Value as System.Collections.IList;if(l==null || l.Count>4096)throw Bad("ErrorShapeInvalid");foreach(object x in l)if(!(x is string) || ((string)x).Length>100)throw Bad("ErrorShapeInvalid"); }
                else throw Bad("ErrorShapeInvalid");
            }
            foreach (char c in code) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_')) throw Bad("ErrorShapeInvalid");
            o["ErrorCode"] = code;
        }
        return o;
    }

    // 关闭 stdin 让 Host 正常退出，超时则强制结束；在线程池执行，不阻塞 UI。
    public Task BeginClose(int waitMs)
    {
        if (ClosedTask != null) return ClosedTask;
        Process p = process; process = null; Task wt = writeTask;
        ClosedTask = Task.Factory.StartNew(delegate
        {
            if (p == null) return;
            try { if (wt != null) wt.Wait(2000); } catch (Exception) { }
            try { p.StandardInput.BaseStream.Close(); } catch (Exception) { }
            try { if (!p.WaitForExit(waitMs)) { p.Kill(); p.WaitForExit(2000); } } catch (Exception) { }
            try { p.Dispose(); } catch (Exception) { }
        });
        return ClosedTask;
    }
}
'@

function Initialize-SjcExplorerBridge {
    if(-not ('SjcExplorerBridge' -as [type])){
        Add-Type -TypeDefinition $script:SjcExplorerBridgeSource -ReferencedAssemblies 'System.Web.Extensions','System.Core','System.Runtime.Serialization','System.Xml','System.Runtime.Serialization','System.Xml'
    }
}

function Test-SjcExplorerPlainFile([string]$Path){
    # 固定路径白名单要求：存在、是文件、非重解析点（符号链接/联接）。
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
    $item=Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
}

# 解析 Host 启动方式。生产：<应用目录>\explorer\sjc-explorer.exe（固定）；开发：仓库 artifacts 下固定的 dotnet.exe + sjc-explorer.dll。
# 不读取任何环境变量指定的可执行文件。测试：仅当调用方在本进程设置了 $script:SjcExplorerTestContext 且 TestId 为同一 GUID 时才接受 LaunchSpec。
function Resolve-SjcExplorerLaunch($LaunchSpec,[string]$AppRoot){
    Initialize-SjcExplorerBridge
    $ctx=Get-SjcExplorerTestContext
    if($LaunchSpec){
        if(-not $ctx -or [string]$LaunchSpec.TestId -ne [string]$ctx.Id){throw 'LaunchSpecNotAllowed'}
        if(-not (Test-SjcExplorerPlainFile ([string]$LaunchSpec.Exe))){throw 'TestHostMissing'}
        return @{Exe=[string]$LaunchSpec.Exe;Arguments=[string]$LaunchSpec.Arguments;DotnetRoot=$null;Kind='Test';BuildId=$null;ManifestSha256=$null;Verifications=@()}
    }
    $packaged=[bool](Get-Variable -Name SjcIsPackaged -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if(-not $AppRoot){
        $entry=[string](Get-Variable -Name SjcEntryPath -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        if($packaged -and $entry){$AppRoot=Split-Path -Parent $entry}
        elseif($PSScriptRoot){$AppRoot=Split-Path -Parent $PSScriptRoot}
        elseif($entry){$AppRoot=Split-Path -Parent (Split-Path -Parent $entry)}
        else{throw 'AppRootUnknown'}
    }
    if(Test-SjcExplorerPlainFile (Join-Path $AppRoot 'explorer\sjc-explorer.exe')){return (Get-SjcExplorerPackagedPlan $AppRoot $ctx)}
    if($packaged){throw 'ExplorerHostNotInstalled'}
    return (Get-SjcExplorerDevelopmentPlan $AppRoot $ctx)
}

function Get-SjcExplorerProp($Object,[string]$Name){
    if($null -eq $Object){return $null}
    if($Object -is [Collections.IDictionary]){ if($Object.Contains($Name)){return $Object[$Name]}; return $null }
    $p=$Object.PSObject.Properties[$Name]
    if($null -eq $p){return $null}
    return $p.Value
}

function Read-SjcExplorerJsonFile([string]$Path,[int]$MaxBytes=2097152){
    if(-not (Test-SjcExplorerPlainFile $Path)){throw ('JsonFileMissingOrLinked:'+[IO.Path]::GetFileName($Path))}
    $info=[IO.FileInfo]::new($Path)
    if($info.Length -gt $MaxBytes -or $info.Length -lt 2){throw ('JsonFileSizeInvalid:'+[IO.Path]::GetFileName($Path))}
    $bytes=[IO.File]::ReadAllBytes($Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    if($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF){$text=$text.Substring(1)}
    $guard=[SjcJsonGuard]::Check($text)
    if($guard){throw ($guard+':'+[IO.Path]::GetFileName($Path))}
    return @{Hash=$hash;Object=($text|ConvertFrom-Json)}
}

function Convert-SjcExplorerComponents($Components,[switch]$NoSizes){
    $paths=[Collections.Generic.List[string]]::new();$hashes=[Collections.Generic.List[string]]::new();$sizes=[Collections.Generic.List[long]]::new()
    foreach($c in @($Components)){
        $rel=Get-SjcExplorerProp $c 'Path';$h=Get-SjcExplorerProp $c 'Sha256';$n=Get-SjcExplorerProp $c 'Bytes'
        if($rel -isnot [string] -or $rel.Length -eq 0 -or $rel.Length -gt 260 -or $rel -match '^[\\/]|[:*?"<>|]|(^|[\\/])\.\.([\\/]|$)|[\\/]{2}'){throw 'ComponentPathInvalid'}
        if($h -isnot [string] -or $h -notmatch '^[0-9A-Fa-f]{64}$'){throw ('ComponentHashInvalid:'+$rel)}
        if($NoSizes){$size=[long]-1}
        else{
            if($null -eq $n -or $n -isnot [ValueType] -or $n -lt 0){throw ('ComponentBytesInvalid:'+$rel)}
            $size=[long]$n
        }
        $paths.Add($rel);$hashes.Add($h);$sizes.Add($size)
    }
    if($paths.Count -eq 0){throw 'ComponentsEmpty'}
    if(@($paths | Group-Object {$_.ToLowerInvariant()} | Where-Object Count -gt 1).Count){throw 'ComponentDuplicate'}
    return @{Paths=$paths.ToArray();Hashes=$hashes.ToArray();Sizes=$sizes.ToArray()}
}

function New-SjcExplorerVerification([string]$Name,[string]$Root,$Components,[bool]$RejectLinks,[bool]$Extras,[bool]$Ancestors,[string]$AllowedExtra){
    return @{Name=$Name;Root=$Root;Paths=$Components.Paths;Hashes=$Components.Hashes;Sizes=$Components.Sizes;RejectLinks=$RejectLinks;Extras=$Extras;Ancestors=$Ancestors;AllowedExtra=$AllowedExtra}
}

function Get-SjcExplorerTestContext {
    $ctx=Get-Variable -Name SjcExplorerTestContext -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if($null -eq $ctx){return $null}
    $id=[Guid]::Empty
    if(-not [Guid]::TryParseExact([string]$ctx.Id,'D',[ref]$id) -or $id -eq [Guid]::Empty){return $null}
    return $ctx
}

function Get-SjcExplorerStateArgument($TestContext){
    # 仅内部测试上下文可指定隔离 state 目录；生产路径一律使用 Host 默认的 LocalAppData\SafeJunkCleaner\explorer。
    if($TestContext -and $TestContext.StateRoot){
        $root=[string]$TestContext.StateRoot
        if($root -notmatch '^[A-Za-z]:\\[^"]+$'){throw 'TestStateRootInvalid'}
        return (' --state-root "'+$root+'"')
    }
    return ''
}

function Get-SjcExplorerProgramFiles {
    if([Environment]::Is64BitProcess){return [Environment]::GetFolderPath('ProgramFiles')}
    $w6432=[Environment]::GetEnvironmentVariable('ProgramW6432')
    if(-not $w6432){throw 'ProgramFilesUnavailable'}
    return $w6432
}

function Get-SjcExplorerDevelopmentPlan([string]$AppRoot,$TestContext){
    $cache=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SafeJunkCleaner\explorer-dev-runtime'
    if($TestContext -and (Get-SjcExplorerProp $TestContext 'RuntimeCache')){
        $cache=[string](Get-SjcExplorerProp $TestContext 'RuntimeCache')
        if(-not [IO.Path]::IsPathRooted($cache) -or -not (Test-SjcExplorerPlainFile (Join-Path $cache 'current.json'))){throw 'TestRuntimeCacheInvalid'}
    }
    $pointer=(Read-SjcExplorerJsonFile (Join-Path $cache 'current.json') 4096).Object
    $g=[Guid]::Empty
    if(-not [Guid]::TryParseExact([string](Get-SjcExplorerProp $pointer 'BuildId'),'D',[ref]$g) -or $g -eq [Guid]::Empty){throw 'PointerBuildIdInvalid'}
    $build=$g.ToString('D')
    if((Get-SjcExplorerProp $pointer 'ContractVersion') -ne 3 -or (Get-SjcExplorerProp $pointer 'SchemaVersion') -ne 1){throw 'PointerVersionUnsupported'}
    if([string](Get-SjcExplorerProp $pointer 'Manifest') -cne 'host-component-manifest.json'){throw 'PointerManifestInvalid'}
    $expected=[string](Get-SjcExplorerProp $pointer 'ManifestSha256')
    if($expected -notmatch '^[0-9A-Fa-f]{64}$'){throw 'PointerHashMissing'}
    $runtime=Join-Path $cache $build
    $file=Read-SjcExplorerJsonFile (Join-Path $runtime 'host-component-manifest.json')
    if($file.Hash -ne $expected){throw 'ManifestHashMismatch'}
    $m=$file.Object
    if((Get-SjcExplorerProp $m 'ContractVersion') -ne 3 -or (Get-SjcExplorerProp $m 'SchemaVersion') -ne 1 -or (Get-SjcExplorerProp $m 'DevelopmentOnly') -ne $true -or [string](Get-SjcExplorerProp $m 'BuildId') -ne $build -or [string](Get-SjcExplorerProp $m 'RuntimeRoot') -cne '.'){throw 'ManifestFieldsInvalid'}
    $launch=Get-SjcExplorerProp $m 'Launch';$launchArgs=@(Get-SjcExplorerProp $launch 'Arguments')
    if((Get-SjcExplorerProp $m 'SelfContained') -ne $true -or [string](Get-SjcExplorerProp $m 'RuntimeIdentifier') -cne 'win-x64' -or [string](Get-SjcExplorerProp $launch 'Executable') -cne 'sjc-explorer.exe' -or $launchArgs.Count -ne 0 -or [string](Get-SjcExplorerProp $launch 'WorkingDirectory') -cne '.'){throw 'ManifestLaunchInvalid'}
    $rt=Convert-SjcExplorerComponents (Get-SjcExplorerProp $m 'Components')
    foreach($need in 'sjc-explorer.exe','sjc-explorer.dll','coreclr.dll','hostfxr.dll'){if($rt.Paths -notcontains $need){throw 'ManifestHostRuntimeMissing'}}
    $src=Convert-SjcExplorerComponents (Get-SjcExplorerProp (Get-SjcExplorerProp $m 'SourceProvenance') 'Sources') -NoSizes
    if(-not (Test-Path -LiteralPath (Join-Path $AppRoot 'engine') -PathType Container)){throw 'DevelopmentSourceMissing'}
    $verifications=@(
        (New-SjcExplorerVerification 'Runtime' $runtime $rt $true $true $true 'host-component-manifest.json'),
        (New-SjcExplorerVerification 'SourceProvenance' $AppRoot $src $false $false $false ''))
    return @{Exe=(Join-Path $runtime 'sjc-explorer.exe');Arguments=((Get-SjcExplorerStateArgument $TestContext).Trim());DotnetRoot=$null;Kind='Development';BuildId=$build;ManifestSha256=$file.Hash;Verifications=$verifications}
}

function Get-SjcExplorerPackagedPlan([string]$AppRoot,$TestContext){
    $dir=Join-Path $AppRoot 'explorer'
    $embedded=Get-Variable -Name SjcEmbeddedExplorerManifestSha256 -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if([string]$embedded -notmatch '^[0-9A-Fa-f]{64}$'){throw 'PackagedManifestHashMissing'}
    $file=Read-SjcExplorerJsonFile (Join-Path $dir 'host-component-manifest.json')
    if($file.Hash -ne [string]$embedded){throw 'PackagedManifestHashMismatch'}
    $m=$file.Object
    # DevelopmentOnly marks an unsealed candidate, not a dependency on the SDK.
    # Packaged execution requires the complete self-contained apphost contract.
    $launch=Get-SjcExplorerProp $m 'Launch'
    $args=@(Get-SjcExplorerProp $launch 'Arguments')
    if((Get-SjcExplorerProp $m 'ContractVersion') -ne 3 -or (Get-SjcExplorerProp $m 'SchemaVersion') -ne 1 -or (Get-SjcExplorerProp $m 'SelfContained') -ne $true -or [string](Get-SjcExplorerProp $m 'RuntimeIdentifier') -cne 'win-x64' -or [string](Get-SjcExplorerProp $m 'RuntimeRoot') -cne '.' -or [string](Get-SjcExplorerProp $launch 'Executable') -cne 'sjc-explorer.exe' -or [string](Get-SjcExplorerProp $launch 'WorkingDirectory') -cne '.' -or $args.Count -ne 0){throw 'PackagedManifestFieldsInvalid'}
    $components=Convert-SjcExplorerComponents (Get-SjcExplorerProp $m 'Components')
    if($components.Paths -notcontains 'sjc-explorer.exe'){throw 'PackagedHostExeMissing'}
    $verification=New-SjcExplorerVerification 'PackagedHost' $dir $components $true $true $false 'host-component-manifest.json'
    return @{Exe=(Join-Path $dir 'sjc-explorer.exe');Arguments=((Get-SjcExplorerStateArgument $TestContext).Trim());DotnetRoot=$null;Kind='Packaged';BuildId=$null;ManifestSha256=$file.Hash;Verifications=@($verification)}
}

function Format-SjcExplorerBytes($Value){
    if($null -eq $Value){return '未知'}
    $n=[double]$Value
    foreach($unit in 'B','KB','MB','GB','TB'){ if($n -lt 1024 -or $unit -eq 'TB'){ if($unit -eq 'B'){return ('{0:N0} B' -f $n)}; return ('{0:N1} {1}' -f $n,$unit)}; $n=$n/1024 }
}

function Get-SjcExplorerStateText([string]$State){
    switch($State){
        'Inventory'{'探索中'} 'Paused'{'已暂停'} 'Ready'{'已完成'} 'Partial'{'部分完成'} 'Cancelled'{'已取消'} 'Failed'{'失败'}
        'Pending'{'待扫描'} 'Starting'{'启动中'} 'Released'{'记录已释放'} 'Running'{'运行中'} 'Stopped'{'已停止'} 'Interrupted'{'上次中断'} 'Completed'{'已完成'}
        default{if($State){$State}else{'未开始'}}
    }
}

# ---- 会话（无 UI，可无头测试）----
function New-SjcExplorerSession($LaunchSpec,[string]$AppRoot){
    Initialize-SjcExplorerBridge
    $launch=Resolve-SjcExplorerLaunch $LaunchSpec $AppRoot
    $s=@{Bridge=[SjcExplorerBridge]::new();Launch=$launch;Phase='Verifying';VerifyTasks=@();Queue=[Collections.Generic.List[hashtable]]::new();InFlight=$null
         HostReady=$false;Mode=$null;CanInventory=$true;Operations=@();Capabilities=@{};Fault=$null;LastError=$null;Stderr=[Collections.Generic.List[string]]::new()
         RenderingSuggestions=$false
         Space=@();SpaceNext=$null;SpaceStack=[Collections.Generic.List[string]]::new();SpaceRevision=$null;SpaceDirty=$false
         TaskId=$null;State=$null;Reason=$null;Revision=$null;Coverage=$null;ProgressTick=0;GroupsTick=0
         Storage=$null;SessionInfo=$null;StorageNotice='';StorageAutoRead=$false;StorageReadFailed=$false;SessionReadFailed=$false
         Groups=@();GroupsNext=$null;GroupsStack=[Collections.Generic.List[long]]::new();GroupsRevision=$null;GroupsDirty=$false
         ParentId=$null;Evidence=@();EvidenceNext=$null;EvidenceStack=[Collections.Generic.List[long]]::new();EvidenceDirty=$false
         ProgressDirty=$true;Semantics=@{};Closing=$false;StepCount=0
         TaskGen=0;AnalysisGen=0;DraftGen=0;BatchGen=0;BatchListGen=0;StaleDropped=0;LastStale=$null;AbandonedPrep=$null
         Batch=$null;BatchDirty=$false}
    $s.GroupsStack.Add(0); $s.EvidenceStack.Add(0); $s.SpaceStack.Add('')
    Initialize-SjcExplorerApprovalState $s
    $script:SjcExplorerLastTaskId=$null
    # 组件校验在线程池后台完成，UI 不阻塞；全部通过后才启动 Host 进程。
    $s.VerifyTasks=@($launch.Verifications | ForEach-Object {
        $v=$_
        @{Name=$v.Name;Task=[SjcHostVerifier]::VerifyAsync([string]$v.Root,[string[]]$v.Paths,[string[]]$v.Hashes,[long[]]$v.Sizes,[bool]$v.RejectLinks,[bool]$v.Extras,[bool]$v.Ancestors,[string]$v.AllowedExtra)}
    })
    return $s
}

function Add-SjcExplorerRequest($S,[string]$Op,[string]$TaskId,$Payload){
    if($Op -in 'GetProgress','QueryGroups','QueryEvidence','GetAnalysisProgress','QuerySpace'){
        $dups=@($S.Queue | Where-Object {$_.Op -eq $Op}); foreach($d in $dups){[void]$S.Queue.Remove($d)}
    }
    # Gen 记录发出请求时的界面世代；响应回来时据此判断是否仍属于当前任务/分析/草稿。
    $S.Queue.Add(@{Op=$Op;TaskId=$TaskId;Payload=$Payload;Gen=(Get-SjcExplorerGenSnapshot $S)})
}

function Get-SjcExplorerGenSnapshot($S){
    $bg=if($S.ContainsKey('BatchGen')){[long]$S['BatchGen']}else{0L}
    $blg=if($S.ContainsKey('BatchListGen')){[long]$S['BatchListGen']}else{0L}
    return @{Task=[long]$S['TaskGen'];Analysis=[long]$S['AnalysisGen'];Draft=[long]$S['DraftGen'];Batch=$bg;BatchList=$blg}
}

function Step-SjcExplorerGen($S,[string]$Kind){ $k=$Kind+'Gen'; $cur=if($S.ContainsKey($k)){[long]$S[$k]}else{0L}; $S[$k]=$cur+1 }

function Test-SjcExplorerQueryOp([string]$Op){
    return ($Op -in 'GetProgress','QueryGroups','QueryEvidence','QuerySpace','GetAnalysisProgress','QuerySuggestions','QuerySuggestionFiles','QueryApprovalItems','GetExecutionResult','ListBatches','GetBatch')
}

function Test-SjcExplorerPageTop($Stack,$Value){
    # 测试直接构造的会话可能没有分页栈；没有栈时不做分页位置判断。
    if($null -eq $Stack -or $Stack.Count -lt 1){return $true}
    $top=$Stack[$Stack.Count-1]
    if($top -is [string]){ $v=$(if($null -eq $Value){''}else{[string]$Value}); return ($top -eq $v) }
    if($null -eq $Value){return $false}
    return ([long]$top -eq [long]$Value)
}

function Test-SjcExplorerPrepDrainBlocksOp([string]$Op){
    return ($Op -in 'BeginPrepareApproval','PrepareApproval','InvalidateAnalysis','Analyze','ConfirmApproval','ExecuteApproved','CompactState','ArchiveUnconfirmedDrafts','ReleaseFinishedSessions','ConfigureStorageBudget','CreateInventory','ReleaseTask','CreateBatch','ContinueBatch','StartBatchEntry')
}

function Insert-SjcExplorerPriorityPrepControl($S,$Req){
    $idx=-1
    for($i=0;$i -lt $S.Queue.Count;$i++){
        if(Test-SjcExplorerPrepDrainBlocksOp ([string]$S.Queue[$i].Op)){ $idx=$i; break }
    }
    if($idx -ge 0){ $S.Queue.Insert($idx,$Req) } else { $S.Queue.Add($Req) }
}

function Start-SjcExplorerAbandonedCancel($S,[string]$TaskId,[string]$PreparationId){
    if(-not $TaskId -or -not $PreparationId -or -not (Test-SjcExplorerHasOp $S 'CancelPreparation')){return}
    $S['AbandonedPrep']=@{TaskId=$TaskId;PreparationId=$PreparationId;CancelAcked=$false;Polls=0;DeadlineUtc=[datetime]::UtcNow.AddSeconds(30);LastPollUtc=[datetime]::MinValue}
    if($S['InFlight'] -and $S.InFlight.Op -eq 'CancelPreparation' -and [string]$S.InFlight.TaskId -eq $TaskId -and [string]$S.InFlight.Payload['PreparationId'] -eq $PreparationId){return}
    if(@($S.Queue | Where-Object {$_.Op -eq 'CancelPreparation' -and [string]$_.TaskId -eq $TaskId -and [string]$_.Payload['PreparationId'] -eq $PreparationId}).Count -gt 0){return}
    $req=@{Op='CancelPreparation';TaskId=$TaskId;Payload=@{PreparationId=$PreparationId};Gen=(Get-SjcExplorerGenSnapshot $S)}
    Insert-SjcExplorerPriorityPrepControl $S $req
}

function Add-SjcExplorerAbandonedPoll($S,$Abandoned){
    if(-not $Abandoned -or -not (Test-SjcExplorerHasOp $S 'GetPreparationProgress')){return}
    $prepId=[string]$Abandoned['PreparationId']; $taskId=[string]$Abandoned['TaskId']
    if(-not $prepId -or -not $taskId){return}
    if($S['InFlight'] -and $S.InFlight.Op -eq 'GetPreparationProgress' -and $S.InFlight['AbandonedDrain'] -eq $true -and [string]$S.InFlight.TaskId -eq $taskId -and [string]$S.InFlight.Payload['PreparationId'] -eq $prepId){return}
    if(@($S.Queue | Where-Object {$_.Op -eq 'GetPreparationProgress' -and $_['AbandonedDrain'] -eq $true -and [string]$_.TaskId -eq $taskId -and [string]$_.Payload['PreparationId'] -eq $prepId}).Count -gt 0){return}
    $Abandoned['LastPollUtc']=[datetime]::UtcNow
    $req=@{Op='GetPreparationProgress';TaskId=$taskId;Payload=@{PreparationId=$prepId};Gen=(Get-SjcExplorerGenSnapshot $S);AbandonedDrain=$true}
    Insert-SjcExplorerPriorityPrepControl $S $req
}

function Complete-SjcExplorerAbandonedUnconfirmed($S){
    $S['AbandonedPrep']=$null
    foreach($queuedPrep in @($S.Queue | Where-Object {$_.Op -in 'BeginPrepareApproval','PrepareApproval','GetPreparationProgress'})){
        [void]$S.Queue.Remove($queuedPrep)
    }
    $d=$S.Draft
    if($d -and $d['Pending'] -eq $true -and -not $d['PreparationId'] -and -not $d['DraftId']){
        $S.Draft=$null; $S.DraftDirty=$true; Step-SjcExplorerGen $S 'Draft'
    }
    $S.LastError='PreparationCancelUnconfirmed'
    $S['StorageNotice']='取消未确认，请关闭并重开探索后重试；未批准或处理文件。'
    $S.ProgressDirty=$true; $S.ApprovalDirty=$true
}

# 判断请求（及其响应/失败）是否仍归属当前界面状态。只做“是否可写入当前界面”的判断，不放宽 Host 侧授权。
function Test-SjcExplorerReqOwned($S,$Req){
    $op=[string]$Req.Op; $p=$Req.Payload; if($null -eq $p){$p=@{}}; $g=$Req['Gen']
    $genTask=(-not $g) -or ([long]$g['Task'] -eq [long]$S['TaskGen'])
    $genAnalysis=(-not $g) -or ([long]$g['Analysis'] -eq [long]$S['AnalysisGen'])
    $genDraft=(-not $g) -or ([long]$g['Draft'] -eq [long]$S['DraftGen'])
    $curBatchGen=if($S.ContainsKey('BatchGen')){[long]$S['BatchGen']}else{0L}
    $curBatchListGen=if($S.ContainsKey('BatchListGen')){[long]$S['BatchListGen']}else{0L}
    $genBatch=(-not $g) -or (-not $g.ContainsKey('Batch')) -or ([long]$g['Batch'] -eq $curBatchGen)
    $genBatchList=(-not $g) -or (-not $g.ContainsKey('BatchList')) -or ([long]$g['BatchList'] -eq $curBatchListGen)
    $b=$S['Batch']
    $batchOk=($b -and [string]$p['BatchId'] -eq [string]$b['Id'] -and $genBatch)
    $taskOk=($S.TaskId -and [string]$Req.TaskId -eq [string]$S.TaskId -and $genTask)
    $a=$S.Analysis
    $analysisOk=($taskOk -and $genAnalysis -and $a -and $a.Id -and [string]$p['AnalysisId'] -eq [string]$a.Id)
    switch($op){
        { $_ -in 'Health','ListTasks','ReleaseTask','InvalidateAnalysis','CancelExecution','CancelPreparation' }{ return $true }
        'ListBatches'{ return [bool]($genBatchList -and (Test-SjcExplorerPageTop $S['BatchListStack'] $p['AfterBatchId'])) }
        'CreateBatch'{ return [bool]($batchOk -and $b['Creating'] -eq $true) }
        'GetBatch'{ return [bool]$batchOk }
        { $_ -in 'PauseBatch','CancelBatch','StopBatch' }{ return [bool]$batchOk }
        'ContinueBatch'{ return [bool]($batchOk -and $null -ne $b['Revision'] -and [long]$p['ExpectedRevision'] -eq [long]$b['Revision']) }
        'StartBatchEntry'{ return [bool]($batchOk -and ($b['ActiveIntent'] -eq $true -or $b.CancelRequested -or $b['PauseAfterStart']) -and $null -ne $b['Revision'] -and [long]$p['ExpectedRevision'] -eq [long]$b['Revision']) }
        'CreateInventory'{ return [bool]$genTask }
        { $_ -in 'GetProgress','Pause','Resume','Cancel' }{ return [bool]$taskOk }
        'QueryGroups'{ return [bool]($taskOk -and (Test-SjcExplorerPageTop $S.GroupsStack $p['AfterId'])) }
        'QueryEvidence'{ return [bool]($taskOk -and $null -ne $S.ParentId -and $null -ne $p['ParentId'] -and [long]$p['ParentId'] -eq [long]$S.ParentId -and (Test-SjcExplorerPageTop $S.EvidenceStack $p['AfterId'])) }
        { $_ -in 'QuerySpace','QuerySpaceAsync' }{ return [bool]($taskOk -and (Test-SjcExplorerPageTop $S.SpaceStack $p['AfterCursor'])) }
        'Analyze'{ return [bool]($taskOk -and $genAnalysis -and $a -and -not $a.Id -and $a.Requested) }
        { $_ -in 'GetAnalysisProgress','CancelAnalysis' }{ return [bool]$analysisOk }
        'QuerySuggestions'{ return [bool]($analysisOk -and (Test-SjcExplorerPageTop $S.SugStack $p['AfterId'])) }
        'QuerySuggestionFiles'{ return [bool]($analysisOk -and $S.SugFilesFor -and [string]$p['SuggestionId'] -eq [string]$S.SugFilesFor -and (Test-SjcExplorerPageTop $S.SugFilesStack $p['AfterId'])) }
        { $_ -in 'PrepareApproval','BeginPrepareApproval' }{ return [bool]($analysisOk -and $genDraft -and $S.Draft -and $S.Draft.Pending) }
        'GetPreparationProgress'{
            if($Req['AbandonedDrain'] -eq $true){
                $ab=$S['AbandonedPrep']
                return [bool]($ab -and [string]$ab['TaskId'] -eq [string]$Req.TaskId -and [string]$ab['PreparationId'] -eq [string]$p['PreparationId'])
            }
            return [bool]($taskOk -and $genDraft -and $S.Draft -and [string]$S.Draft['PreparationId'] -eq [string]$p['PreparationId'])
        }
        'QueryApprovalItems'{ return [bool]($taskOk -and $genDraft -and $S.Draft -and $S.Draft.DraftId -and [string]$p['DraftId'] -eq [string]$S.Draft.DraftId -and (Test-SjcExplorerPageTop $S.DraftStack $p['AfterId'])) }
        'ConfirmApproval'{ return [bool]($taskOk -and $genDraft -and $S.Draft -and $S.Draft.DraftId -and [string]$p['DraftId'] -eq [string]$S.Draft.DraftId -and -not $S.Approval) }
        { $_ -in 'ExecuteApproved','GetExecutionResult' }{ return [bool]($taskOk -and $S.Exec -and $S.Exec.ApprovalId -and [string]$p['ApprovalId'] -eq [string]$S.Exec.ApprovalId) }
    }
    return $true
}

function Register-SjcExplorerStale($S,$Req,[string]$Kind,[string]$Code){
    # 过期响应不写入当前界面，但留下计数与最后一次记录，便于诊断；不覆盖当前 LastError。
    $S['StaleDropped']=[int]$S['StaleDropped']+1
    $S['LastStale']=@{Kind=$Kind;Op=[string]$Req.Op;TaskId=[string]$Req.TaskId;Code=$Code}
}

function Reset-SjcExplorerProgressDisplay($S){
    $S['ScanMetrics']=$null;$S['ProgressSample']=$null;$S['RecentObjectsPerSecond']=$null
    $S['LastAdvanceAt']=$null;$S['ProgressReceivedAt']=$null;$S['InFlightStartedAt']=$null
}

function Update-SjcExplorerProgressDisplay($S,$Result){
    $now=[datetime]::UtcNow
    $metrics=$(if($Result.ContainsKey('Metrics')){$Result['Metrics']}else{$null})
    $S['ScanMetrics']=$metrics;$S['ProgressReceivedAt']=$now
    $coverage=$Result['Coverage'];if(-not $coverage -or $null -eq $coverage['ObservedObjects']){return}
    $observed=[long]$coverage['ObservedObjects']
    $committed=$(if($metrics -and $metrics.ContainsKey('CommittedBatches')){[long]$metrics['CommittedBatches']}else{-1L})
    $elapsed=$(if($metrics -and $metrics.ContainsKey('ElapsedMilliseconds')){[double]$metrics['ElapsedMilliseconds']}else{-1.0})
    $old=$S['ProgressSample']
    $reset=($null -eq $old -or [string]$old['TaskId'] -ne [string]$S.TaskId -or [long]$old['TaskGen'] -ne [long]$S['TaskGen'] -or $observed -lt [long]$old['Observed'] -or ($elapsed -ge 0 -and [double]$old['Elapsed'] -ge 0 -and $elapsed -lt [double]$old['Elapsed']))
    if($reset){
        $S['ProgressSample']=@{TaskId=[string]$S.TaskId;TaskGen=[long]$S['TaskGen'];At=$now;Observed=$observed;Committed=$committed;Elapsed=$elapsed}
        $S['RecentObjectsPerSecond']=$null;$S['LastAdvanceAt']=$now;return
    }
    $seconds=($now-[datetime]$old['At']).TotalSeconds
    if($observed -gt [long]$old['Observed'] -or ($committed -ge 0 -and $committed -gt [long]$old['Committed'])){$S['LastAdvanceAt']=$now}
    if($seconds -ge 1.0){
        $S['RecentObjectsPerSecond']=[math]::Max(0.0,($observed-[long]$old['Observed'])/$seconds)
        $S['ProgressSample']=@{TaskId=[string]$S.TaskId;TaskGen=[long]$S['TaskGen'];At=$now;Observed=$observed;Committed=$committed;Elapsed=$elapsed}
    }
}

function Get-SjcExplorerProgressDisplayText($S){
    if(-not $S.TaskId){return ''}
    $parts=[Collections.Generic.List[string]]::new()
    $metrics=$S['ScanMetrics']
    if($metrics -and $metrics.ContainsKey('ElapsedMilliseconds')){
        $duration=[timespan]::FromMilliseconds([math]::Max(0.0,[double]$metrics['ElapsedMilliseconds']))
        $parts.Add(('本轮用时 {0:00}:{1:00}:{2:00}' -f [int][math]::Floor($duration.TotalHours),$duration.Minutes,$duration.Seconds))
    }
    if($S.State -eq 'Inventory'){
        if($null -eq $S['RecentObjectsPerSecond']){$parts.Add('近期速度统计中')}
        else{$parts.Add(('近期约 {0:N0} 个对象/秒' -f [double]$S['RecentObjectsPerSecond']))}
        if($S['LastAdvanceAt']){
            $age=[math]::Max(0,[int]([datetime]::UtcNow-[datetime]$S['LastAdvanceAt']).TotalSeconds)
            $parts.Add(('最近推进 {0} 秒前' -f $age))
        }
        if($S.InFlight -and $S['InFlightStartedAt']){
            $waiting=([datetime]::UtcNow-[datetime]$S['InFlightStartedAt']).TotalSeconds
            if($waiting -ge 3){$parts.Add(('等待扫描服务回应 {0:N0} 秒' -f $waiting))}
        }
        $parts.Add('速度按已提交记录估算；0不等于卡死，不预测剩余时间')
    }
    return ($parts -join '　')
}

function Set-SjcExplorerTaskView($S,$Result){
    $S['SkippedReasons']=if($Result.ContainsKey('SkippedReasons')){$Result['SkippedReasons']}else{$null}
    $t=$Result['Task']
    if($t){$S.State=[string]$t['State'];$S.Reason=$t['Reason'];$S.Revision=$t['EvidenceRevision']}
    $S.Coverage=$Result['Coverage']; $S.ProgressDirty=$true
    Update-SjcExplorerProgressDisplay $S $Result
    $sem=$Result['Semantics']; if($sem){$S.Semantics['Progress']=[string]$sem}
}

function Receive-SjcExplorerResponse($S,$Req,$Resp){
    if(-not $Resp['Ok']){
        Receive-SjcExplorerFailure $S $Req ([string]$Resp['ErrorCode'])
        if($Req.Op -in 'CompactState','ArchiveUnconfirmedDrafts' -and $Resp.ContainsKey('Error')){
            $errorDetails=$Resp['Error'];$notice='维护未完成：'+(Get-SjcExplorerErrorText ([string]$Resp['ErrorCode']))+'；不自动恢复或重试。'
            foreach($field in @('Stage','BackupPath','ArchivePath')){if($errorDetails.ContainsKey($field) -and $errorDetails[$field]){$notice+=' '+$field+'：'+[string]$errorDetails[$field]}}
            $S['StorageNotice']=$notice;$S.ApprovalDirty=$true
        }
        return
    }
    $r=$Resp['Result']
    if(-not (Test-SjcExplorerReqOwned $S $Req)){
        Register-SjcExplorerStale $S $Req 'Response' $null
        # 过期的 Analyze 已在 Host 建立分析但界面不再跟踪：作废它，避免占用分析配额。
        if($Req.Op -eq 'Analyze' -and $r -and $r['AnalysisId'] -and $Req.TaskId){ Add-SjcExplorerRequest $S 'InvalidateAnalysis' ([string]$Req.TaskId) @{AnalysisId=[string]$r['AnalysisId']} }
        # 过期的 BeginPrepareApproval 已在 Host 启动后台准备但界面已返回/切任务：对原任务补发取消并有界追踪至终态。
        if($Req.Op -eq 'BeginPrepareApproval' -and $r -and $r['PreparationId'] -and ($null -eq $r['Status'] -or [string]$r['Status'] -eq 'Running') -and $Req.TaskId){
            Start-SjcExplorerAbandonedCancel $S ([string]$Req.TaskId) ([string]$r['PreparationId'])
            $S.ApprovalDirty=$true
        }
        if($Req.Op -eq 'CreateInventory'){ Request-SjcExplorerTaskList $S 0 }
        return
    }
    if($Req.Op -eq 'GetProgress' -and $r -and $r['Task'] -and $r['Task']['TaskId'] -and [string]$r['Task']['TaskId'] -ne [string]$Req.TaskId){
        Register-SjcExplorerStale $S $Req 'ResponseTaskMismatch' $null; return
    }
    switch($Req.Op){
        'Health'{
            # 信封与各字段已由 bridge 按 Operation 严格验证；Mode 与额外 Capabilities 按声明保留，不因新增字段或新 Mode 故障。
            $wasReady=$S.HostReady
            $S.Mode=[string]$r['Mode']
            $declaredOps=@($r['Operations']|ForEach-Object{[string]$_})
            $S.Operations=$(if($wasReady){@($S.Operations | Where-Object {$declaredOps -contains $_})}else{$declaredOps}); $S.Capabilities=@{}
            if($r['Capabilities'] -is [Collections.IDictionary]){foreach($k in $r['Capabilities'].Keys){$S.Capabilities[[string]$k]=$r['Capabilities'][$k]}}
            # 旧 Host 没有 Capabilities 时视为可清点；新 Host 明确声明 InventoryReady 才可清点。
            $S.CanInventory=(-not $S.Capabilities.ContainsKey('InventoryReady')) -or ($S.Capabilities['InventoryReady'] -eq $true)
            $S.HostReady=$true; $S.ProgressDirty=$true; $S.ApprovalDirty=$true
            if(-not $wasReady -and (Test-SjcExplorerHasOp $S 'ListTasks')){ Request-SjcExplorerTaskList $S 0 }
            if(-not $wasReady -and (Test-SjcExplorerCanPersistBatch $S)){ [void](Request-SjcExplorerBatchList $S 0) }
        }
        'CreateInventory'{ Set-SjcExplorerCurrentTask $S ([string]$r['TaskId']) 'Inventory'; Receive-SjcExplorerBatchCreated $S $Req ([string]$r['TaskId']) }
        'CreateBatch'{
            $cancelAfterCreate=[bool]($S['Batch'] -and $S.Batch.CancelRequested)
            $pauseAfterCreate=[bool]($S['Batch'] -and $S.Batch['PauseAfterCreate'])
            Apply-SjcExplorerBatchSnapshot $S $r $true
            if($cancelAfterCreate){Stop-SjcExplorerBatchQueue $S}
            elseif($pauseAfterCreate){Invoke-SjcExplorerTaskCommand $S 'Pause'}
            [void](Request-SjcExplorerBatchList $S 0)
        }
        'ListBatches'{
            $S['BatchList']=@($r['Items']); $S['BatchListNext']=$r['NextAfterBatchId']; $S['BatchListLoaded']=$true; $S['BatchListDirty']=$true; $S.ApprovalDirty=$true
        }
        'GetBatch'{
            $keepActive=[bool]($Req['PassiveView'] -ne $true -and $S['Batch'] -and $S.Batch['Id'] -eq [string]$r['BatchId'] -and $S.Batch['ActiveIntent'] -eq $true -and [string]$r['State'] -eq 'Running')
            Apply-SjcExplorerBatchSnapshot $S $r $keepActive
        }
        'ContinueBatch'{
            Apply-SjcExplorerBatchSnapshot $S $r $true
            [void](Request-SjcExplorerBatchList $S 0)
        }
        'StartBatchEntry'{
            $b=$S['Batch']
            $idx=[int]$r['EntryIndex']; $tid=[string]$r['TaskId']
            if(-not $b -or $b['Persisted'] -ne $true -or $b['Id'] -ne [string]$r['BatchId'] -or $idx -lt 0 -or $idx -ge $b.Entries.Count -or [long]$r['Revision'] -lt [long]$b['Revision']){
                Register-SjcExplorerStale $S $Req 'StartBatchEntryMismatch' $null; return
            }
            $b['Revision']=[long]$r['Revision']; $b.Index=$idx; $b.Pending=$false
            $entry=$b.Entries[$idx]; $entry.TaskId=$tid; $entry.State=[string]$r['State']; $entry.Reason=$r['Reason']
            $S['BatchDirty']=$true; $S.ProgressDirty=$true; $S.ApprovalDirty=$true
            Set-SjcExplorerCurrentTask $S $tid ([string]$r['State'])
            if($b.CancelRequested){Stop-SjcExplorerBatchQueue $S}
            elseif($b['PauseAfterStart']){$b['PauseAfterStart']=$false;$b['ActiveIntent']=$true;Invoke-SjcExplorerTaskCommand $S 'Pause'}
        }
        { $_ -in 'PauseBatch','CancelBatch','StopBatch' }{
            Apply-SjcExplorerBatchSnapshot $S $r $false
            if($S.TaskId){ Add-SjcExplorerRequest $S 'GetProgress' $S.TaskId @{} }
            [void](Request-SjcExplorerBatchList $S 0)
        }
        'GetProgress'{
            Set-SjcExplorerTaskView $S $r
            Receive-SjcExplorerBatchProgress $S
            if($S.Revision -ne $S.GroupsRevision -and ($S.State -ne 'Inventory' -or ([Environment]::TickCount - $S.GroupsTick) -gt 5000 -or $null -eq $S.GroupsRevision)){
                $S.GroupsRevision=$S.Revision; $S.GroupsTick=[Environment]::TickCount
                Add-SjcExplorerRequest $S 'QueryGroups' $S.TaskId @{AfterId=[long]$S.GroupsStack[$S.GroupsStack.Count-1];PageSize=64}
                if($null -ne $S.ParentId){Add-SjcExplorerRequest $S 'QueryEvidence' $S.TaskId @{AfterId=[long]$S.EvidenceStack[$S.EvidenceStack.Count-1];PageSize=64;ParentId=[long]$S.ParentId}}
                if($S.State -in 'Ready','Partial' -and (Test-SjcExplorerHasOp $S 'QuerySpace')){Request-SjcExplorerSpacePage $S 0}
            }
            $S.ApprovalDirty=$true
        }
        'QuerySpaceAsync'{
            if(-not (Test-SjcExplorerReqOwned $S $Req)){return}
            if([string]$r['Status'] -eq 'Ready'){$S['SpaceQueryPending']=$null;Receive-SjcExplorerResponse $S @{Op='QuerySpace';TaskId=$Req.TaskId;Payload=$Req.Payload} @{Ok=$true;Result=$r['Page']}}
            elseif([string]$r['Status'] -eq 'Running'){$S['SpaceQueryPending']=@{TaskId=$Req.TaskId;Payload=$Req.Payload;Tick=[Environment]::TickCount}}
            else{$S['SpaceQueryPending']=$null;$S.LastError=[string]$r['ErrorCode'];$S.ProgressDirty=$true}
        }
        'QuerySpace'{
            if([long]$r['Revision'] -ne [long]$S.Revision){$S.LastError='SpaceRevisionChanged';$S.ProgressDirty=$true;return}
            $S.Space=@($r['Items']);$S.SpaceNext=$r['NextCursor'];$S.SpaceRevision=[long]$r['Revision'];$S.SpaceDirty=$true;$S.Semantics['Space']=[string]$r['Semantics']
        }
        'QueryGroups'{ $S.Groups=@($r['Items']); $S.GroupsNext=$r['NextAfter']; $S.GroupsDirty=$true; if($r['Semantics']){$S.Semantics['Groups']=[string]$r['Semantics']} }
        'QueryEvidence'{ $S.Evidence=@($r['Items']); $S.EvidenceNext=$r['NextAfter']; $S.EvidenceDirty=$true; if($r['Semantics']){$S.Semantics['Evidence']=[string]$r['Semantics']} }
        { $_ -in 'Pause','Resume','Cancel' }{ Add-SjcExplorerRequest $S 'GetProgress' $S.TaskId @{} }
        'Analyze'{
            $a=$S.Analysis; if(-not $a){return}
            $a.Id=[string]$r['AnalysisId']; $a.Status='Running'; $a.Mode=[string]$r['ExplorationMode']; $a.Progress=$r['Progress']; $S.AnalysisTick=[Environment]::TickCount
            Add-SjcExplorerRequest $S 'GetAnalysisProgress' $S.TaskId @{AnalysisId=$a.Id}; $S.ApprovalDirty=$true
        }
        'GetAnalysisProgress'{
            $a=$S.Analysis; if(-not $a -or $a.Id -ne [string]$r['AnalysisId']){return}
            $a.Status=[string]$r['Status']; $a.Reason=$r['Reason']; $a.Mode=[string]$r['ExplorationMode']; $a.Progress=$r['Progress']; $a.Usage=$r['Usage']; $S.AnalysisTick=[Environment]::TickCount; $S.ApprovalDirty=$true
            if($r.ContainsKey('Timing')){$a.Timing=$r['Timing']}; if($r.ContainsKey('Outcome')){$a.Outcome=$r['Outcome']}
            if($a.Status -ne 'Running'){
                $a.Terminal=$true
                $a.Ready=($a.Status -in 'Complete','BudgetExhausted','NoProgress','AskedUser' -and $r['HasResult'] -eq $true)
                if($a.Ready){ Add-SjcExplorerRequest $S 'QuerySuggestions' $S.TaskId @{AnalysisId=$a.Id;AfterId=$null;PageSize=64} }
            }
        }
        'QuerySuggestions'{
            if(-not $S.Analysis -or [long]$r['Revision'] -ne [long]$S.Analysis.Revision){$S.LastError='AnalysisRevisionInvalidated';Reset-SjcExplorerApproval $S;return}
            $S.Suggestions=@($r['Items']); $S.SugNext=$r['NextAfterId']; $S.SugStatus=[string]$r['AnalysisStatus']; $S.SugDirty=$true; $S.ApprovalDirty=$true
            $S['NoResultReason']=$(if($r.ContainsKey('NoResultReason')){$r['NoResultReason']}else{$null})
            foreach($it in $S.Suggestions){ $S.SugIndex[[string]$it['SuggestionId']]=$it }
        }
        'QuerySuggestionFiles'{ $S.SugFiles=@($r['Items']); $S.SugFilesNext=$r['NextAfterId']; $S.SugFilesDirty=$true }
        'CancelAnalysis'{if($S.Analysis){$S.Analysis.CancelRequested=$true;$S.ApprovalDirty=$true}}
        'InvalidateAnalysis'{ }
        'ConfigureStorageBudget'{
            if($S['Storage'] -is [Collections.IDictionary] -and $r.ContainsKey('IndexRepairPending')){$S.Storage['IndexRepairPending']=($r['IndexRepairPending'] -eq $true)}
            $S['StorageNotice']='本次会话的扫描记录空间预算已更新；不会删除旧记录。';Request-SjcExplorerStorage $S
        }
        'BeginPrepareApproval'{
            if($S.Draft -and $S.Draft.Pending){
                $S.Draft['PreparationId']=[string]$r['PreparationId'];$S.Draft['PrepareProgress']=$r;$S.ApprovalDirty=$true
                if([string]$r['Status'] -eq 'Ready' -and $r['Prepared']){Receive-SjcExplorerResponse $S @{Op='PrepareApproval';TaskId=$S.TaskId;Payload=@{AnalysisId=[string]$S.Analysis.Id}} @{Ok=$true;Result=$r['Prepared']}}
                elseif([string]$r['Status'] -in 'Failed','Cancelled'){$S.LastError=[string]$r['ErrorCode'];$S.Draft=$null;$S.ProgressDirty=$true}
                else{Add-SjcExplorerRequest $S 'GetPreparationProgress' $S.TaskId @{PreparationId=[string]$r['PreparationId']}}
            }
        }
        'GetPreparationProgress'{
            if($Req['AbandonedDrain'] -eq $true){
                $ab=$S['AbandonedPrep']
                if(-not $ab -or [string]$ab['TaskId'] -ne [string]$Req.TaskId -or [string]$ab['PreparationId'] -ne [string]$r['PreparationId']){return}
                if([string]$r['Status'] -in 'Ready','Failed','Cancelled'){
                    $S['AbandonedPrep']=$null;$S.ApprovalDirty=$true
                }else{
                    $ab['Polls']=[int]$ab['Polls']+1;$ab['LastPollUtc']=[datetime]::UtcNow
                    if([int]$ab['Polls'] -ge 150 -or [datetime]::UtcNow -ge [datetime]$ab['DeadlineUtc']){Complete-SjcExplorerAbandonedUnconfirmed $S}
                }
                return
            }
            if(-not $S.Draft -or [string]$S.Draft['PreparationId'] -ne [string]$r['PreparationId']){return}
            $S.Draft['PrepareProgress']=$r;$S.Draft['PrepareTick']=[Environment]::TickCount;$S.ApprovalDirty=$true
            if([string]$r['Status'] -eq 'Ready' -and $r['Prepared']){Receive-SjcExplorerResponse $S @{Op='PrepareApproval';TaskId=$S.TaskId;Payload=@{AnalysisId=[string]$S.Analysis.Id}} @{Ok=$true;Result=$r['Prepared']}}
            elseif([string]$r['Status'] -in 'Failed','Cancelled'){$S.LastError=[string]$r['ErrorCode'];$S.Draft=$null;$S.ProgressDirty=$true}
        }
        'CancelPreparation'{
            $ab=$S['AbandonedPrep']
            $matchesAb=($ab -and [string]$ab['TaskId'] -eq [string]$Req.TaskId -and $Req.Payload -and [string]$ab['PreparationId'] -eq [string]$Req.Payload['PreparationId'])
            if($matchesAb){
                if(-not $S.Draft){ $S['StorageNotice']='已请求取消清单准备，尚未批准或处理任何文件。' }
                $ab['CancelAcked']=$true
                if(Test-SjcExplorerHasOp $S 'GetPreparationProgress'){ Add-SjcExplorerAbandonedPoll $S $ab }
                else { $S['AbandonedPrep']=$null; $S.ApprovalDirty=$true }
            }elseif(-not $S.Draft -and -not $ab -and [string]$Req.TaskId -eq [string]$S.TaskId){
                $S['StorageNotice']='已请求取消清单准备，尚未批准或处理任何文件。'
            }
        }
        'PrepareApproval'{
            $S.Draft=@{Pending=$false;DraftId=[string]$r['DraftId'];DisplayHash=[string]$r['DisplayHash'];DisplayedHash=$null;CandidateSetHash=[string]$r['CandidateSetHash'];LogicalBytes=[long]$r['LogicalBytes'];ItemCount=[int]$r['ItemCount'];RecycleEnabled=($r['RecycleEnabled'] -eq $true);ConfirmError=$null;SuggestionIds=@($S.Selected.Keys)}
            $S.DraftItems=@(); $S.DraftNext=$null; $S.DraftStack.Clear(); $S.DraftStack.Add(0); $S.DraftDirty=$true; $S.ApprovalDirty=$true
            Add-SjcExplorerRequest $S 'QueryApprovalItems' $S.TaskId @{DraftId=$S.Draft.DraftId;AfterId=0;PageSize=64}
        }
        'QueryApprovalItems'{
            $d=$S.Draft; if(-not $d){return}
            if($S.DraftStack.Count -eq 1){ $d.DisplayedHash=[string]$r['DisplayHash'] }
            if([string]$r['DisplayHash'] -ne $d.DisplayHash -or [string]$r['CandidateSetHash'] -ne $d.CandidateSetHash){ $d.ConfirmError='DisplayedSnapshotMismatch'; $d.DisplayedHash=$null }
            $S.DraftItems=@($r['Items']); $S.DraftNext=$r['NextAfter']; $S.DraftDirty=$true; $S.ApprovalDirty=$true
        }
        'ConfirmApproval'{
            $can=$r['RecycleEnabled'] -eq $true; if($r.ContainsKey('CanExecute')){$can=($r['CanExecute'] -eq $true)}
            $S.Approval=@{ApprovalId=[string]$r['ApprovalId'];CanExecute=$can;RecycleEnabled=($r['RecycleEnabled'] -eq $true);DisplayHash=$S.Draft.DisplayedHash}
            $S.ApprovalDirty=$true
        }
        'ExecuteApproved'{
            $e=$S.Exec; if(-not $e){return}
            $e.Status=[string]$r['Status']; $e.ExecutionId=[string]$r['ExecutionId']; $e.Tick=[Environment]::TickCount
            Add-SjcExplorerRequest $S 'GetExecutionResult' $S.TaskId @{ApprovalId=$e.ApprovalId;AfterEntry=0;PageSize=64}; $S.ApprovalDirty=$true
        }
        'GetExecutionResult'{
            $e=$S.Exec; if(-not $e){return}
            $e.Status=[string]$r['Status']; $e.Tick=[Environment]::TickCount
            foreach($x in @($r['Entries'])){ $e.Entries.Add($x) }
            if($r.ContainsKey('RecycledLogicalBytes')){$e.RecycledBytes=[long]$r['RecycledLogicalBytes']}
            if($null -ne $r['NextAfter']){ Add-SjcExplorerRequest $S 'GetExecutionResult' $S.TaskId @{ApprovalId=$e.ApprovalId;AfterEntry=[int]$r['NextAfter'];PageSize=64} }
            elseif($e.Status -notin 'Queued','Running','Requested'){ $e.Terminal=$true }
            $S.ApprovalDirty=$true
        }
        'CancelExecution'{ }
        'ListTasks'{ if($Req.Payload.ContainsKey('PathFilter') -and [string]$Req.Payload['PathFilter'] -ne [string]$S['HistoryFilter']){return}; $S.TaskList=@($r['Items']); $S.TaskListNext=$r['NextAfterTaskId']; $S.TaskListLoaded=$true; $S.TaskListDirty=$true; $S.ProgressDirty=$true; $S.ApprovalDirty=$true }
        'GetStorageInfo'{$S['Storage']=$r;$S['StorageReadFailed']=$false;$S.ApprovalDirty=$true}
        'GetSessionInfo'{$S['SessionInfo']=$r;$S['SessionReadFailed']=$false;$S.ApprovalDirty=$true}
        'CompactState'{$S['StorageNotice']=('索引整理完成：{0} → {1}；备份保留于 {2}。备份仍占磁盘空间。' -f (Format-SjcExplorerBytes $r['BeforeBytes']),(Format-SjcExplorerBytes $r['AfterBytes']),$r['BackupPath']);Request-SjcExplorerStorage $S;$S.ApprovalDirty=$true}
        'ArchiveUnconfirmedDrafts'{$S['StorageNotice']=('已整理 {0} 份未确认草稿至 {1}，已确认凭据/账本未动；保留材料仍占磁盘空间。' -f $r['DraftsArchived'],$r['ArchivePath']);Request-SjcExplorerStorage $S;$S.ApprovalDirty=$true}
        'ReleaseFinishedSessions'{$S.Analysis=$null;Reset-SjcExplorerApproval $S;$S['StorageNotice']='已释放结束的分析/执行会话，旧复核批准已失效；防重放记录与执行账本保留。';Request-SjcExplorerStorage $S;$S.ApprovalDirty=$true}
        'ReleaseTask'{
            if($S.LastError -eq 'IndexQuotaExceededReleaseCompletedTask'){$S.LastError=$null;$S.ProgressDirty=$true;$S.ApprovalDirty=$true}
            # ReleaseTask 可作用于历史任务；只有释放的是当前任务时才清空当前视图。
            if($S.TaskId -and [string]$Req.TaskId -eq [string]$S.TaskId){
                Step-SjcExplorerGen $S 'Task'; Step-SjcExplorerGen $S 'Analysis'
                $S.TaskId=$null; $S.State=$null; $S.Revision=$null; $S.Coverage=$null; $S.Groups=@(); $S.Evidence=@(); $S.ParentId=$null; $S.Analysis=$null
                $S.GroupsNext=$null; $S.EvidenceNext=$null; $S.GroupsRevision=$null
                if($S.GroupsStack){$S.GroupsStack.Clear();$S.GroupsStack.Add(0)}; if($S.EvidenceStack){$S.EvidenceStack.Clear();$S.EvidenceStack.Add(0)}
                $S.Space=@(); $S.SpaceNext=$null; $S.SpaceRevision=$null; if($S.SpaceStack){$S.SpaceStack.Clear();$S.SpaceStack.Add('')}; $S.SpaceDirty=$true
                $S.GroupsDirty=$true; $S.EvidenceDirty=$true; Reset-SjcExplorerApproval $S; $S.ProgressDirty=$true
            }
            Request-SjcExplorerTaskList $S 0
        }
    }
}

# 每个定时器周期调用一次：最多发一个请求、收一个响应，不阻塞。
function Step-SjcExplorerSession($S){
    $S.StepCount++
    $b=$S.Bridge
    foreach($line in $b.TakeStderr()){ if($line){$S.Stderr.Add($line); if($S.Stderr.Count -gt 20){$S.Stderr.RemoveAt(0)}} }
    if($S.Fault){if(Test-SjcExplorerBatchActive $S){$S.Batch.Status='Stopped';$S['BatchDirty']=$true};return}
    if($S.Phase -eq 'Verifying'){ Start-SjcExplorerHostIfVerified $S; if($S.Phase -eq 'Verifying'){return} }
    if($b.Fault){ $S.Fault=$b.Fault; $S.InFlight=$null; $S.ProgressDirty=$true; return }
    if($S.InFlight){
        $resp=$b.Poll()
        if($resp){ $req=$S.InFlight; $S.InFlight=$null;$S['InFlightStartedAt']=$null; Receive-SjcExplorerResponse $S $req $resp }
        elseif($b.Fault){ $S.Fault=$b.Fault; $S.InFlight=$null; $S.ProgressDirty=$true }
        return
    }
    if($S.Closing){return}
    [void]$b.Poll()
    if($b.Fault){ $S.Fault=$b.Fault; $S.ProgressDirty=$true; return }
    Step-SjcExplorerBatch $S
    $ab=$S['AbandonedPrep']
    if($ab){
        if([int]$ab['Polls'] -ge 150 -or [datetime]::UtcNow -ge [datetime]$ab['DeadlineUtc']){
            Complete-SjcExplorerAbandonedUnconfirmed $S
        }elseif($ab['CancelAcked'] -eq $true -and -not $S.InFlight){
            $hasDrain=@($S.Queue | Where-Object {$_['AbandonedDrain'] -eq $true -or $_.Op -eq 'CancelPreparation'}).Count -gt 0
            if(-not $hasDrain -and ([datetime]::UtcNow - [datetime]$ab['LastPollUtc']).TotalMilliseconds -ge 80){
                Add-SjcExplorerAbandonedPoll $S $ab
            }
        }
    }
    $now=[Environment]::TickCount
    if($S['SpaceQueryPending'] -and $S.Queue.Count -eq 0){$pendingSpace=$S['SpaceQueryPending'];if(($now-[int]$pendingSpace.Tick) -gt 250){$candidate=@{Op='QuerySpaceAsync';TaskId=$pendingSpace.TaskId;Payload=$pendingSpace.Payload};if(Test-SjcExplorerReqOwned $S $candidate){Add-SjcExplorerRequest $S 'QuerySpaceAsync' $pendingSpace.TaskId $pendingSpace.Payload;$pendingSpace.Tick=$now}else{$S['SpaceQueryPending']=$null}}}
    if($S.Draft -and $S.Draft.Pending -and $S.Draft['PreparationId'] -and -not $S['AbandonedPrep'] -and -not $S.InFlight -and $S.Queue.Count -eq 0){
        $last=if($S.Draft.ContainsKey('PrepareTick')){[int]$S.Draft['PrepareTick']}else{0}
        if(($now-$last) -gt 200){Add-SjcExplorerRequest $S 'GetPreparationProgress' $S.TaskId @{PreparationId=[string]$S.Draft['PreparationId']};$S.Draft['PrepareTick']=$now}
    }
    if($S.Queue.Count -eq 0){
        if($S.TaskId -and $S.State -eq 'Inventory' -and ($now - $S.ProgressTick) -gt 800){ Add-SjcExplorerRequest $S 'GetProgress' $S.TaskId @{} }
        elseif($S.Analysis -and $S.Analysis.Id -and -not $S.Analysis.Terminal -and ($now - $S.AnalysisTick) -gt 200){ $S.AnalysisTick=$now; Add-SjcExplorerRequest $S 'GetAnalysisProgress' $S.TaskId @{AnalysisId=[string]$S.Analysis.Id} }
        elseif($S.Exec -and $S.Exec.ApprovalId -and -not $S.Exec.Terminal -and $S.Exec.Status -ne 'Requested' -and ($now - $S.Exec.Tick) -gt 200){ $S.Exec.Tick=$now; Add-SjcExplorerRequest $S 'GetExecutionResult' $S.TaskId @{ApprovalId=[string]$S.Exec.ApprovalId;AfterEntry=[int]$S.Exec.Entries.Count;PageSize=64} }
    }
    if($S.Queue.Count -gt 0){
        $pickIdx=0
        if($S['AbandonedPrep']){
            $pickIdx=-1
            for($qi=0;$qi -lt $S.Queue.Count;$qi++){
                $qItem=$S.Queue[$qi]
                if(-not (Test-SjcExplorerPrepDrainBlocksOp ([string]$qItem.Op))){ $pickIdx=$qi; break }
                if(-not (Test-SjcExplorerReqOwned $S $qItem)){ $pickIdx=$qi; break }
            }
            if($pickIdx -lt 0){return}
        }
        $req=$S.Queue[$pickIdx]; $S.Queue.RemoveAt($pickIdx)
        if($req.Op -in 'BeginPrepareApproval','GetPreparationProgress','QuerySpaceAsync' -and -not (Test-SjcExplorerReqOwned $S $req)){Register-SjcExplorerStale $S $req 'QueuedPreparation' $null;return}
        # 过期查询及启动/批准请求不再发送；停止与释放请求仍作用于原任务。
        if(((Test-SjcExplorerQueryOp ([string]$req.Op)) -or $req.Op -in 'Resume','CreateInventory','CreateBatch','ContinueBatch','StartBatchEntry','Analyze','PrepareApproval','ConfirmApproval','ExecuteApproved') -and -not (Test-SjcExplorerReqOwned $S $req)){ Register-SjcExplorerStale $S $req 'QueuedRequest' $null; return }
        try{
            $payload=[Collections.Generic.Dictionary[string,object]]::new()
            if($req.Payload){ foreach($k in $req.Payload.Keys){$payload[$k]=$req.Payload[$k]} }
            if($req.Op -eq 'QueryEvidence' -and -not $payload.ContainsKey('ParentId')){$payload['ParentId']=$null}
            if($req.Op -eq 'ListBatches' -and -not $payload.ContainsKey('AfterBatchId')){$payload['AfterBatchId']=$null}
            $tid=$null; if($req.TaskId){$tid=[string]$req.TaskId}
            $timeout=15000;if($req.Op -in 'CompactState','ArchiveUnconfirmedDrafts'){$timeout=120000}
            [void]$b.BeginRequest($req.Op,$tid,$payload,$timeout)
            $S.InFlight=$req;$S['InFlightStartedAt']=[datetime]::UtcNow; $S.ProgressTick=[Environment]::TickCount
        }catch{
            Receive-SjcExplorerFailure $S $req ('RequestRejectedLocally:'+$_.Exception.Message)
            if($req['BatchId'] -and $S['Batch']){$S.Batch.Pending=$false;$S.Batch['ActiveIntent']=$false;$S.Batch.Status='Stopped';$S['BatchDirty']=$true}
            if($req.Op -eq 'ExecuteApproved'){ $S.Exec=@{ApprovalId=$null;Status='NotExecuted';Entries=[Collections.Generic.List[object]]::new();Next=$null;Terminal=$true;Rejected=$true;ErrorCode='ExecuteNotArmed';RecycledBytes=0} }
            if($req.Op -eq 'Analyze' -and $S.Analysis){ $S.Analysis.Terminal=$true; $S.Analysis.Status='Failed'; $S.Analysis.ErrorCode=$S.LastError }
        }
    }
}

# 启动恢复预留：只有 Health 的 Operations 声明了 ListTasks 才可用，否则保持禁用（当前 Host 未声明）。
function Test-SjcExplorerCanListTasks($S){ return ($S.HostReady -and ($S.Operations -contains 'ListTasks')) }

function Test-SjcExplorerCanPersistBatch($S){
    if(-not $S.HostReady -or $S.Fault){return $false}
    foreach($op in 'CreateBatch','ListBatches','GetBatch','ContinueBatch','StartBatchEntry','PauseBatch','CancelBatch','StopBatch'){
        if($S.Operations -notcontains $op){return $false}
    }
    return $true
}

function Apply-SjcExplorerBatchSnapshot($S,$Snapshot,[bool]$ActiveIntent){
    $entries=[Collections.Generic.List[object]]::new()
    $curIdx=-1
    foreach($e in @($Snapshot['Entries'])){
        $idx=[int]$e['EntryIndex']
        $st=[string]$e['State']
        $tid=$e['TaskId']
        $entries.Add(@{EntryIndex=$idx;Root=[string]$e['RootPath'];TaskId=$tid;State=$st;Reason=$e['Reason']})
        if($st -eq 'Inventory' -or ($curIdx -lt 0 -and $st -in 'Paused','Pending')){$curIdx=$idx}
    }
    $state=[string]$Snapshot['State']
    $prevSessionCreated=[bool]($S['Batch'] -and $S.Batch['Id'] -eq [string]$Snapshot['BatchId'] -and $S.Batch['SessionCreated'] -eq $true)
    if($state -ne 'Running'){$ActiveIntent=$false}
    $S['Batch']=@{
        Id=[string]$Snapshot['BatchId'];Persisted=$true;ActiveIntent=$ActiveIntent;SessionCreated=($prevSessionCreated -or $ActiveIntent)
        Creating=$false;Revision=[long]$Snapshot['Revision'];CanContinue=($Snapshot['CanContinue'] -eq $true)
        Entries=$entries;Index=$curIdx;Status=$state;Reason=$Snapshot['Reason']
        Pending=$false;SyncNeeded=$false;Hold=($state -eq 'Paused');CancelRequested=$false;NextTick=0
    }
    $S['BatchDirty']=$true;$S.ProgressDirty=$true;$S.ApprovalDirty=$true
}

function Request-SjcExplorerBatchList($S,[int]$Direction=0){
    if(-not (Test-SjcExplorerCanPersistBatch $S)){return $false}
    if(-not $S.ContainsKey('BatchListStack') -or $null -eq $S['BatchListStack']){
        $S['BatchListStack']=[Collections.Generic.List[string]]::new();$S['BatchListStack'].Add('')
    }
    $stack=$S['BatchListStack']
    if($Direction -gt 0 -and $null -ne $S['BatchListNext']){$stack.Add([string]$S['BatchListNext'])}
    elseif($Direction -lt 0){if($stack.Count -gt 1){$stack.RemoveAt($stack.Count-1)}else{return $false}}
    elseif($Direction -eq 0){$stack.Clear();$stack.Add('')}
    else{return $false}
    Step-SjcExplorerGen $S 'BatchList'
    $after=$stack[$stack.Count-1];if($after -eq ''){$after=$null}
    $dups=@($S.Queue | Where-Object {$_.Op -eq 'ListBatches'});foreach($d in $dups){[void]$S.Queue.Remove($d)}
    Add-SjcExplorerRequest $S 'ListBatches' $null @{AfterBatchId=$after;PageSize=64}
    return $true
}

function Open-SjcExplorerHistoricalBatch($S,[string]$BatchId){
    if(-not (Test-SjcExplorerCanPersistBatch $S) -or (Test-SjcExplorerBatchActive $S)){return $false}
    if($S.State -eq 'Inventory' -or ($S.Analysis -and -not $S.Analysis.Terminal) -or ($S.Exec -and -not $S.Exec.Terminal)){return $false}
    $gid=[Guid]::Empty
    if(-not [Guid]::TryParseExact($BatchId,'D',[ref]$gid) -or $gid -eq [Guid]::Empty){return $false}
    $bid=$gid.ToString('D')
    Step-SjcExplorerGen $S 'Batch'
    $S['Batch']=@{Id=$bid;Persisted=$true;ActiveIntent=$false;SessionCreated=$false;Creating=$false;Revision=$null;CanContinue=$false;Entries=[Collections.Generic.List[object]]::new();Index=-1;Status='Loading';Reason=$null;Pending=$true;SyncNeeded=$false;Hold=$false;CancelRequested=$false;NextTick=0}
    $S['BatchDirty']=$true;$S.ProgressDirty=$true;$S.ApprovalDirty=$true
    Add-SjcExplorerRequest $S 'GetBatch' $null @{BatchId=$bid}
    $req=$S.Queue[$S.Queue.Count-1];$req['PassiveView']=$true;$req['BatchId']=$bid
    return $true
}

function Get-SjcExplorerBatchContinueManifest($S){
    $b=$S['Batch']
    if(-not $b -or $b['Persisted'] -ne $true -or -not $b['Entries'] -or $b.Entries.Count -eq 0){return ''}
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add(('批次 {0}（当前状态：{1}，版本：{2}）' -f $b.Id,(Get-SjcExplorerStateText $b.Status),$b['Revision']))
    $lines.Add('确认后将仅串行恢复「已暂停」条目或开始「待扫描」条目；已完成、部分完成、已取消、失败或记录已释放的条目不会重扫，且不会自动执行分析或回收：')
    foreach($e in $b.Entries){
        $action=if($e.State -in 'Pending','Paused'){'[将继续]'}else{'[保持跳过]'}
        $lines.Add(('{0} #{1} {2} — {3}' -f $action,$e['EntryIndex'],$e.Root,(Get-SjcExplorerStateText $e.State)))
    }
    return ($lines -join "`n")
}

function Test-SjcExplorerCanContinueBatch($S){
    if(-not (Test-SjcExplorerCanPersistBatch $S) -or (Test-SjcExplorerBatchActive $S)){return $false}
    if($S.State -eq 'Inventory' -or $S.InFlight -or $S.Queue.Count -gt 0 -or ($S.Analysis -and -not $S.Analysis.Terminal) -or ($S.Exec -and -not $S.Exec.Terminal)){return $false}
    $b=$S['Batch']
    return [bool]($b -and $b['Persisted'] -eq $true -and $b['CanContinue'] -eq $true -and $null -ne $b['Revision'] -and $b.Status -ne 'Running' -and -not $b.Pending)
}

function Request-SjcExplorerContinueBatch($S,[bool]$UserConfirmed){
    if(-not $UserConfirmed -or -not (Test-SjcExplorerCanContinueBatch $S)){return $false}
    if($S.Analysis -and $S.Analysis.Id -and $S.TaskId){Add-SjcExplorerRequest $S 'InvalidateAnalysis' $S.TaskId @{AnalysisId=[string]$S.Analysis.Id}}
    $b=$S['Batch'];$b.Pending=$true;$S.LastError=$null;$S['BatchDirty']=$true;$S.ProgressDirty=$true;$S.ApprovalDirty=$true
    Add-SjcExplorerRequest $S 'ContinueBatch' $null @{BatchId=[string]$b.Id;ExpectedRevision=[long]$b['Revision'];Confirmed=$true}
    $req=$S.Queue[$S.Queue.Count-1];$req['BatchId']=$b.Id
    return $true
}

function Test-SjcExplorerBatchActive($S){
    $batch=$S['Batch']
    if(-not $batch){return $false}
    if($batch['Persisted'] -eq $true){
        return [bool]($batch['Creating'] -eq $true -or ($batch['ActiveIntent'] -eq $true -and $batch.Status -in 'Running','Cancelling'))
    }
    return [bool]($batch.Status -in 'Running','Paused','Cancelling')
}

function Start-SjcExplorerAllDisks($S){
    $roots=@(Get-SjcExplorerFixedDisks | Sort-Object -Unique)
    if(-not $roots.Count){$S.LastError='NoFixedDisks';$S.ProgressDirty=$true;return $false}
    return (Start-SjcExplorerBatch $S $roots)
}

function Start-SjcExplorerBatch($S,[string[]]$Roots){
    if(-not $S.HostReady -or -not $S.CanInventory -or $S.Fault -or $S.Closing -or (Test-SjcExplorerBatchActive $S)){return $false}
    if($S.State -in 'Inventory','Paused' -or ($S.Analysis -and -not $S.Analysis.Terminal) -or ($S.Exec -and -not $S.Exec.Terminal)){return $false}
    if($S.InFlight -or $S.Queue.Count -gt 0){return $false}
    $paths=@($Roots | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Sort-Object -Unique)
    if(-not $paths.Count -or @($paths | Where-Object {-not [IO.Path]::IsPathRooted($_)}).Count){return $false}
    if($S.Analysis -and $S.Analysis.Id -and $S.TaskId){Add-SjcExplorerRequest $S 'InvalidateAnalysis' $S.TaskId @{AnalysisId=[string]$S.Analysis.Id}}
    $bid=[guid]::NewGuid().ToString('D')
    $entries=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $paths.Count;$i++){$entries.Add(@{EntryIndex=$i;Root=$paths[$i];TaskId=$null;State='Pending';Reason=$null})}
    Step-SjcExplorerGen $S 'Batch'
    if(Test-SjcExplorerCanPersistBatch $S){
        $S['Batch']=@{Id=$bid;Persisted=$true;ActiveIntent=$false;SessionCreated=$true;Creating=$true;Revision=$null;CanContinue=$false;Entries=$entries;Index=-1;Status='Running';Reason=$null;Pending=$true;SyncNeeded=$false;Hold=$false;CancelRequested=$false;NextTick=0}
        Add-SjcExplorerRequest $S 'CreateBatch' $null @{BatchId=$bid;Roots=[string[]]$paths}
        $req=$S.Queue[$S.Queue.Count-1];$req['BatchId']=$bid
    }else{
        $S['Batch']=@{Id=$bid;Persisted=$false;ActiveIntent=$true;Entries=$entries;Index=-1;Status='Running';Pending=$false;Hold=$false;CancelRequested=$false;NextTick=0}
    }
    $S['BatchDirty']=$true;$S.ProgressDirty=$true;$S.ApprovalDirty=$true;$S.LastError=$null
    return $true
}

function Step-SjcExplorerBatch($S){
    $b=$S['Batch']
    if(-not (Test-SjcExplorerBatchActive $S) -or $S.Closing -or $S.Fault -or $b.Hold -or $b.CancelRequested -or $b.Pending){return}
    if($S.InFlight -or $S.Queue.Count -gt 0 -or (Test-SjcExplorerTaskCommandPending $S)){return}
    if(($S.Analysis -and -not $S.Analysis.Terminal) -or ($S.Exec -and -not $S.Exec.Terminal)){return}
    if($b['Persisted'] -eq $true){
        if($b['Creating'] -eq $true -or $b['ActiveIntent'] -ne $true -or $b.Status -ne 'Running'){return}
        if(@($b.Entries | Where-Object {$_.State -eq 'Inventory'}).Count -gt 0 -or $S.State -eq 'Inventory'){return}
        if(([Environment]::TickCount - $b.NextTick) -lt 0){return}
        if($b['SyncNeeded'] -eq $true){
            $b['SyncNeeded']=$false;$b.Pending=$true
            Add-SjcExplorerRequest $S 'GetBatch' $null @{BatchId=[string]$b.Id}
            $req=$S.Queue[$S.Queue.Count-1];$req['BatchId']=$b.Id
            return
        }
        $next=@($b.Entries | Where-Object {$_.State -in 'Pending','Paused'})
        if($next.Count -eq 0){
            $b['ActiveIntent']=$false;$b['CanContinue']=$false;if($b.Status -eq 'Running'){$b.Status='Completed'}
            $S.ProgressDirty=$true;$S.ApprovalDirty=$true;$S['BatchDirty']=$true
            Request-SjcExplorerTaskList $S 0;[void](Request-SjcExplorerBatchList $S 0);return
        }
        $target=$next[0];$idx=[int]$target['EntryIndex']
        $b.Index=$idx;$b.Pending=$true;$target.State='Starting'
        Add-SjcExplorerRequest $S 'StartBatchEntry' $null @{BatchId=[string]$b.Id;EntryIndex=$idx;ExpectedRevision=[long]$b['Revision']}
        $req=$S.Queue[$S.Queue.Count-1];$req['BatchId']=$b.Id;$req['BatchIndex']=$idx
        $S.ProgressDirty=$true;$S['BatchDirty']=$true
        return
    }
    if($b.Index -ge 0){
        $entry=$b.Entries[$b.Index]
        if($entry.State -notin 'Ready','Partial','Cancelled','Failed'){return}
        if($entry.Reason -eq 'IndexQuotaExceeded'){$b.Status='Stopped';$S.LastError='IndexQuotaExceededReleaseCompletedTask';$S.ProgressDirty=$true;$S['BatchDirty']=$true;return}
    }
    if(([Environment]::TickCount - $b.NextTick) -lt 0){return}
    if($b.Index+1 -ge $b.Entries.Count){$b.Status='Completed';$S.ProgressDirty=$true;$S.ApprovalDirty=$true;$S['BatchDirty']=$true;Request-SjcExplorerTaskList $S 0;return}
    $b.Index++;$b.Pending=$true;$b.Entries[$b.Index].State='Starting'
    $payload=@{SelectedPath=[string]$b.Entries[$b.Index].Root};if(Test-SjcExplorerHasOp $S 'GetStorageInfo'){$payload['ScanMode']='AllFixedDisks'}
    Add-SjcExplorerRequest $S 'CreateInventory' $null $payload
    $req=$S.Queue[$S.Queue.Count-1];$req['BatchId']=$b.Id;$req['BatchIndex']=$b.Index
    $S.ProgressDirty=$true;$S['BatchDirty']=$true
}

function Receive-SjcExplorerBatchCreated($S,$Req,[string]$TaskId){
    $b=$S['Batch']
    if(-not $Req['BatchId'] -or -not $b -or $Req['BatchId'] -ne $b.Id){return}
    $entry=$b.Entries[[int]$Req['BatchIndex']];$entry.TaskId=$TaskId;$entry.State='Inventory';$b.Pending=$false
    if($b.CancelRequested){Add-SjcExplorerRequest $S 'Cancel' $TaskId @{}}
    elseif($b.Hold){Add-SjcExplorerRequest $S 'Pause' $TaskId @{}}
    $S['BatchDirty']=$true
}

function Receive-SjcExplorerBatchProgress($S){
    $b=$S['Batch'];if(-not $b){return}
    if($b['Persisted'] -eq $true){
        $matched=@($b.Entries | Where-Object {$_.TaskId -and [string]$_.TaskId -eq [string]$S.TaskId})
        if($matched.Count -ne 1){return}
        $entry=$matched[0];$prevState=$entry.State;$entry.State=$S.State;$entry.Reason=$S.Reason;$S['BatchDirty']=$true
        if($S.State -in 'Ready','Partial','Cancelled','Failed','Paused' -and $prevState -ne $S.State){
            if($S.Reason -eq 'IndexQuotaExceeded'){
                $b['ActiveIntent']=$false;$b.Status='Stopped';$b['SyncNeeded']=$false
                $S.LastError='IndexQuotaExceededReleaseCompletedTask';$S.ProgressDirty=$true;$S.ApprovalDirty=$true
                Add-SjcExplorerRequest $S 'GetBatch' $null @{BatchId=[string]$b.Id};$S.Queue[$S.Queue.Count-1]['PassiveView']=$true;$S.Queue[$S.Queue.Count-1]['BatchId']=$b.Id
                return
            }
            if($b['ActiveIntent'] -eq $true -and $S.State -in 'Ready','Partial','Failed'){
                $b['SyncNeeded']=$true;$b.NextTick=[Environment]::TickCount+80
            }elseif($S.State -in 'Paused','Cancelled'){
                $b['ActiveIntent']=$false;$b['SyncNeeded']=$false
                Add-SjcExplorerRequest $S 'GetBatch' $null @{BatchId=[string]$b.Id};$S.Queue[$S.Queue.Count-1]['PassiveView']=$true;$S.Queue[$S.Queue.Count-1]['BatchId']=$b.Id
            }
            $S.ProgressDirty=$true;$S.ApprovalDirty=$true
        }
        return
    }
    if($b.Index -lt 0){return}
    $entry=$b.Entries[$b.Index]
    if(-not $entry.TaskId -or $entry.TaskId -ne $S.TaskId){return}
    $entry.State=$S.State;$entry.Reason=$S.Reason;$S['BatchDirty']=$true
    if($b.CancelRequested -and $S.State -in 'Inventory','Paused' -and -not (Test-SjcExplorerTaskCommandPending $S)){Add-SjcExplorerRequest $S 'Cancel' $S.TaskId @{}}
    if($b['ResumeAfterPause'] -and $S.State -in 'Ready','Partial','Cancelled','Failed'){$b['ResumeAfterPause']=$false;$b.Hold=$false;$b.Status='Running'}
    if($S.State -eq 'Paused' -and -not $b.CancelRequested){
        if($b['ResumeAfterPause']){$b['ResumeAfterPause']=$false;$b.Hold=$false;$b.Status='Running';Add-SjcExplorerRequest $S 'Resume' $S.TaskId @{}}
        else{$b.Status='Paused';$b.Hold=$true}
    }
    if($S.State -in 'Ready','Partial','Cancelled','Failed'){
        $b.NextTick=[Environment]::TickCount+100
        if($b.CancelRequested){$b.Status='Cancelled'}
        elseif($b.Hold){$b.Status='Paused'}
        $S.ProgressDirty=$true;$S.ApprovalDirty=$true
    }
}

function Stop-SjcExplorerBatchQueue($S){
    $b=$S['Batch'];if(-not $b){return}
    if($b['Persisted'] -eq $true){
        if(-not ($b['ActiveIntent'] -eq $true -or $b['Creating'] -eq $true -or $b.CancelRequested -or ($b['SessionCreated'] -eq $true -and $b.Status -eq 'Paused' -and $b['CanContinue'] -eq $true))){return}
        $b.CancelRequested=$true;$b['ActiveIntent']=$false;$b['SyncNeeded']=$false
        foreach($q in @($S.Queue | Where-Object {$_.Op -in 'StartBatchEntry','ContinueBatch' -and $_['BatchId'] -eq $b.Id})){[void]$S.Queue.Remove($q)}
        $starting=($S.InFlight -and $S.InFlight.Op -in 'CreateBatch','StartBatchEntry' -and [string]$S.InFlight.Payload['BatchId'] -eq [string]$b.Id)
        if(-not $starting -and $null -ne $b['Revision'] -and -not (Test-SjcExplorerTaskCommandPending $S)){
            $b.Pending=$true;$b.Status='Cancelling'
            Add-SjcExplorerRequest $S 'CancelBatch' $null @{BatchId=[string]$b.Id;ExpectedRevision=[long]$b['Revision']}
            $S.Queue[$S.Queue.Count-1]['BatchId']=$b.Id
        }
        $S.ProgressDirty=$true;$S.ApprovalDirty=$true;$S['BatchDirty']=$true
        return
    }
    if(-not (Test-SjcExplorerBatchActive $S)){return}
    $b.CancelRequested=$true;$b.Hold=$true;$b.Status='Cancelling'
    $removed=$false
    foreach($q in @($S.Queue | Where-Object {$_.Op -eq 'CreateInventory' -and $_['BatchId'] -eq $b.Id})){
        [void]$S.Queue.Remove($q);$removed=$true
    }
    if($removed){$b.Pending=$false;$b.Entries[$b.Index].State='NotStarted'}
    $creating=($S.InFlight -and $S.InFlight.Op -eq 'CreateInventory' -and $S.InFlight['BatchId'] -eq $b.Id)
    if(-not $creating){
        if($b.Index -ge 0 -and $b.Entries[$b.Index].TaskId -eq $S.TaskId -and $S.State -in 'Inventory','Paused'){
            if(-not (Test-SjcExplorerTaskCommandPending $S)){Add-SjcExplorerRequest $S 'Cancel' $S.TaskId @{}}
        }else{$b.Status='Cancelled'}
    }
    $S.ProgressDirty=$true;$S.ApprovalDirty=$true;$S['BatchDirty']=$true
}

function Open-SjcExplorerBatchResult($S,[string]$TaskId){
    if(Test-SjcExplorerBatchActive $S){return $false}
    if($S.InFlight -or $S.Queue.Count -gt 0 -or ($S.Analysis -and -not $S.Analysis.Terminal) -or ($S.Exec -and -not $S.Exec.Terminal)){return $false}
    $b=$S['Batch'];if(-not $b){return $false}
    $entry=@($b.Entries | Where-Object {$_.TaskId -eq $TaskId -and $_.State -in 'Ready','Partial','Cancelled','Failed','Paused'})
    if($entry.Count -ne 1){return $false}
    if($S.Analysis -and $S.Analysis.Id -and $S.TaskId){Add-SjcExplorerRequest $S 'InvalidateAnalysis' $S.TaskId @{AnalysisId=[string]$S.Analysis.Id}}
    Set-SjcExplorerCurrentTask $S $TaskId ([string]$entry[0].State)
    return $true
}

function Get-SjcExplorerBatchText($S){
    $b=$S['Batch'];if(-not $b){return ''}
    if($b.Status -eq 'Loading'){return ('正在加载全盘批次 {0} 快照（只读）…' -f $b.Id)}
    $done=@($b.Entries | Where-Object {$_.State -in 'Ready','Partial','Cancelled','Failed','Released'}).Count
    $passive=($b['Persisted'] -eq $true -and $b['ActiveIntent'] -ne $true -and $b['Creating'] -ne $true)
    $status=switch($b.Status){
        'Running'{if($passive){'上次运行未完成（只读展示，未自动恢复）'}else{'逐盘盘点中'}}
        'Paused'{'已暂停'}
        'Cancelling'{'正在取消'}
        'Cancelled'{'已取消后续扫描'}
        'Interrupted'{'上次中断（只读展示，需明确确认才继续）'}
        'Stopped'{'已停止'}
        'Completed'{'盘点结束'}
        default{'已停止'}
    }
    $root=if($b.Index -ge 0 -and $b.Index -lt $b.Entries.Count){[string]$b.Entries[$b.Index].Root}elseif($b.Status -eq 'Completed'){'无待扫描项'}else{'尚未开始'}
    $extra=if($b['Persisted'] -eq $true -and $b['CanContinue'] -eq $true -and $passive){' 可点击「继续剩余扫描…」恢复未完成项。'}else{''}
    return ('全盘扫描：{0}，已结束 {1}/{2} 项；当前 {3}。每盘独立记录，不自动分析或清理。{4}' -f $status,$done,$b.Entries.Count,$root,$extra)
}

function Start-SjcExplorerInventory($S,[string]$Path){
    if(Test-SjcExplorerBatchActive $S){return}
    if(($S.InFlight -and $S.InFlight.Op -eq 'CreateInventory') -or @($S.Queue | Where-Object {$_.Op -eq 'CreateInventory'}).Count){return}
    if(-not $S.HostReady -or $S.Fault -or -not $S.CanInventory){return}
    if($S.TaskId -and $S.State -in 'Inventory','Paused'){return}
    if($S.Exec -and -not $S.Exec.Terminal){return}
    if($S.Analysis -and -not $S.Analysis.Terminal){return}
    if(-not [IO.Path]::IsPathRooted($Path)){$S.LastError='SelectedPathNotAbsolute';$S.ProgressDirty=$true;return}
    $S.LastError=$null
    # 开始新盘点前先作废旧分析（Host 对每个用户有分析数量上限）；旧复核清单与批准在界面上一并作废。
    if($S.Analysis -and $S.Analysis.Id -and $S.TaskId){ Add-SjcExplorerRequest $S 'InvalidateAnalysis' $S.TaskId @{AnalysisId=[string]$S.Analysis.Id} }
    $payload=@{SelectedPath=$Path};if(Test-SjcExplorerHasOp $S 'GetStorageInfo'){$payload['ScanMode']='Selected'}
    Add-SjcExplorerRequest $S 'CreateInventory' $null $payload
}

function Test-SjcExplorerTaskCommandPending($S){
    $ops=@('Pause','Resume','Cancel','PauseBatch','CancelBatch','StopBatch','ContinueBatch')
    if($S.InFlight -and $S.InFlight.Op -in $ops){return $true}
    return (@($S.Queue | Where-Object {$_.Op -in $ops}).Count -gt 0)
}

function Invoke-SjcExplorerTaskCommand($S,[string]$Op){
    $b=$S['Batch']
    if($b -and $b['Persisted'] -eq $true){
        if($S.Fault -or (Test-SjcExplorerTaskCommandPending $S)){return}
        if($b['Creating'] -eq $true){
            if($Op -eq 'Cancel'){Stop-SjcExplorerBatchQueue $S}
            elseif($Op -eq 'Pause'){$b['PauseAfterCreate']=$true;$S['BatchDirty']=$true}
            return
        }
        if($b['ActiveIntent'] -eq $true -and $b.Status -eq 'Running'){
            if($Op -eq 'Pause' -and $S.InFlight -and $S.InFlight.Op -eq 'StartBatchEntry'){
                $b['PauseAfterStart']=$true;$b['ActiveIntent']=$false;$S['BatchDirty']=$true;return
            }
            if($Op -eq 'Cancel'){Stop-SjcExplorerBatchQueue $S;return}
            if($Op -eq 'Pause' -and $null -ne $b['Revision']){
                $b['ActiveIntent']=$false;$b['SyncNeeded']=$false;$b.Hold=$true;$b.Pending=$true
                foreach($q in @($S.Queue | Where-Object {$_.Op -in 'StartBatchEntry','ContinueBatch' -and $_['BatchId'] -eq $b.Id})){[void]$S.Queue.Remove($q)}
                Add-SjcExplorerRequest $S 'PauseBatch' $null @{BatchId=[string]$b.Id;ExpectedRevision=[long]$b['Revision']}
                $S.Queue[$S.Queue.Count-1]['BatchId']=$b.Id
                $S.ProgressDirty=$true;$S.ApprovalDirty=$true;$S['BatchDirty']=$true
            }
            return
        }
        if($b['SessionCreated'] -eq $true -and $b.Status -eq 'Paused' -and $b['CanContinue'] -eq $true -and $null -ne $b['Revision']){
            if($Op -eq 'Resume'){[void](Request-SjcExplorerContinueBatch $S $true);return}
            if($Op -eq 'Cancel'){Stop-SjcExplorerBatchQueue $S;return}
        }
        if($S.TaskId -and @($b.Entries | Where-Object {$_.TaskId -and [string]$_.TaskId -eq [string]$S.TaskId}).Count -gt 0 -and $Op -eq 'Resume'){
            $S.LastError='BatchEntryStartRequired';$S.ProgressDirty=$true;$S.ApprovalDirty=$true;return
        }
    }
    if(Test-SjcExplorerBatchActive $S){
        $b=$S.Batch
        if($Op -eq 'Cancel'){Stop-SjcExplorerBatchQueue $S;return}
        if($b.CancelRequested -or $S.Fault -or (Test-SjcExplorerTaskCommandPending $S)){return}
        if($Op -eq 'Pause' -and -not $b.Hold){
            $b.Hold=$true;$b.Status='Paused'
            if($b.Index -ge 0 -and $b.Entries[$b.Index].TaskId -eq $S.TaskId -and $S.State -eq 'Inventory'){Add-SjcExplorerRequest $S 'Pause' $S.TaskId @{}}
        }elseif($Op -eq 'Resume' -and $b.Hold){
            if($b.Index -ge 0 -and $b.Entries[$b.Index].TaskId -eq $S.TaskId -and $S.State -eq 'Inventory'){$b['ResumeAfterPause']=$true;return}
            $b.Hold=$false;$b.Status='Running'
            if($b.Index -ge 0 -and $b.Entries[$b.Index].TaskId -eq $S.TaskId -and $S.State -eq 'Paused'){Add-SjcExplorerRequest $S 'Resume' $S.TaskId @{}}
        }
        $S.ProgressDirty=$true;$S.ApprovalDirty=$true;$S['BatchDirty']=$true;return
    }
    if($S.Fault -or -not $S.TaskId -or (Test-SjcExplorerTaskCommandPending $S)){return}
    $ok=switch($Op){'Pause'{$S.State -eq 'Inventory'} 'Resume'{$S.State -eq 'Paused'} 'Cancel'{$S.State -in 'Inventory','Paused'} default{$false}}
    if($ok){Add-SjcExplorerRequest $S $Op $S.TaskId @{}}
}

function Select-SjcExplorerGroup($S,$GroupId){
    $S.ParentId=$GroupId; $S.Evidence=@(); $S.EvidenceNext=$null; $S.EvidenceStack.Clear(); $S.EvidenceStack.Add(0); $S.EvidenceDirty=$true
    if($null -ne $GroupId -and $S.TaskId){Add-SjcExplorerRequest $S 'QueryEvidence' $S.TaskId @{AfterId=0;PageSize=64;ParentId=[long]$GroupId}}
}

function Move-SjcExplorerPage($S,[string]$Kind,[int]$Direction){
    if(-not $S.TaskId){return}
    if($Kind -eq 'Groups'){
        if($Direction -gt 0 -and $null -ne $S.GroupsNext){$S.GroupsStack.Add([long]$S.GroupsNext)}
        elseif($Direction -lt 0 -and $S.GroupsStack.Count -gt 1){$S.GroupsStack.RemoveAt($S.GroupsStack.Count-1)} else {return}
        Add-SjcExplorerRequest $S 'QueryGroups' $S.TaskId @{AfterId=[long]$S.GroupsStack[$S.GroupsStack.Count-1];PageSize=64}
    } else {
        if($null -eq $S.ParentId){return}
        if($Direction -gt 0 -and $null -ne $S.EvidenceNext){$S.EvidenceStack.Add([long]$S.EvidenceNext)}
        elseif($Direction -lt 0 -and $S.EvidenceStack.Count -gt 1){$S.EvidenceStack.RemoveAt($S.EvidenceStack.Count-1)} else {return}
        Add-SjcExplorerRequest $S 'QueryEvidence' $S.TaskId @{AfterId=[long]$S.EvidenceStack[$S.EvidenceStack.Count-1];PageSize=64;ParentId=[long]$S.ParentId}
    }
}

# 关闭：探索中则先请求暂停（最多等 1.5 秒），再异步关闭 Host；任务保留在持久 state 中，不自动 Release。
function Close-SjcExplorerSession($S){
    if($S.Closing){return $S.Bridge.ClosedTask}
    $pb=$S['Batch']
    $isPersisted=($pb -and $pb['Persisted'] -eq $true)
    if(-not $isPersisted){ Stop-SjcExplorerBatchQueue $S }
    $S.Closing=$true
    $b=$S.Bridge
    # Drain in-flight batch/create requests up to 1.5s before stopping.
    if($S.InFlight -and -not $S.Fault){
        $until=[Environment]::TickCount+1500
        while($b.Pending -and [Environment]::TickCount -lt $until -and -not $b.Fault){
            $response=$b.Poll()
            if($response){$request=$S.InFlight;$S.InFlight=$null;Receive-SjcExplorerResponse $S $request $response;break}
            Start-Sleep -Milliseconds 20
        }
    }
    $pb=$S['Batch']
    $isPersisted=($pb -and $pb['Persisted'] -eq $true)
    $cancelAnalysis=($S.Analysis -and $S.Analysis.Id -and -not $S.Analysis.Terminal -and $S.Operations -contains 'CancelAnalysis')
    if($isPersisted -and ($pb['ActiveIntent'] -eq $true -or ($pb['SessionCreated'] -eq $true -and $pb.Status -in 'Running','Paused')) -and -not $pb.CancelRequested -and $pb.Status -notin 'Completed','Cancelled','Stopped' -and $null -ne $pb['Revision'] -and -not $S.Fault -and -not $b.Pending -and -not $b.Fault){
        try{
            $p=[Collections.Generic.Dictionary[string,object]]::new()
            $p['BatchId']=[string]$pb.Id; $p['ExpectedRevision']=[long]$pb['Revision']
            $end=[Environment]::TickCount+1500
            [void]$b.BeginRequest('StopBatch',$null,$p,1500)
            while($b.Pending -and [Environment]::TickCount -lt $end -and -not $b.Fault){
                $r0=$b.Poll()
                if($r0){Receive-SjcExplorerResponse $S @{Op='StopBatch';TaskId=$null;Payload=@{BatchId=[string]$pb.Id;ExpectedRevision=[long]$pb['Revision']};Gen=(Get-SjcExplorerGenSnapshot $S)} $r0;break}
                Start-Sleep -Milliseconds 20
            }
        }catch{}
        $pb['ActiveIntent']=$false
        if($cancelAnalysis -and $S.TaskId -and -not $b.Pending -and -not $b.Fault){
            try{
                $pa=[Collections.Generic.Dictionary[string,object]]::new();$pa['AnalysisId']=[string]$S.Analysis.Id
                $end2=[Environment]::TickCount+1000
                [void]$b.BeginRequest('CancelAnalysis',$S.TaskId,$pa,1000)
                while($b.Pending -and [Environment]::TickCount -lt $end2 -and -not $b.Fault){ [void]$b.Poll(); Start-Sleep -Milliseconds 20 }
            }catch{}
        }
    }
    elseif($S.TaskId -and ((-not $isPersisted -and $S.State -eq 'Inventory') -or $cancelAnalysis) -and -not $S.Fault){
        $end=[Environment]::TickCount+1500
        while($b.Pending -and [Environment]::TickCount -lt $end -and -not $b.Fault){ [void]$b.Poll(); Start-Sleep -Milliseconds 20 }
        if(-not $b.Pending -and -not $b.Fault){
            try{
                $p=[Collections.Generic.Dictionary[string,object]]::new()
                $op='Pause';if($cancelAnalysis){$op='CancelAnalysis';$p['AnalysisId']=[string]$S.Analysis.Id}
                [void]$b.BeginRequest($op,$S.TaskId,$p,1500)
                while($b.Pending -and [Environment]::TickCount -lt $end -and -not $b.Fault){ [void]$b.Poll(); Start-Sleep -Milliseconds 20 }
            }catch{}
        }
    }
    return $b.BeginClose(3000)
}

function Start-SjcExplorerHostIfVerified($S){
    foreach($v in $S.VerifyTasks){
        if(-not $v.Task.IsCompleted){return}
    }
    foreach($v in $S.VerifyTasks){
        if($v.Task.IsFaulted){$S.Fault='LaunchVerifyFailed:'+$v.Name+':TaskFaulted';$S.ProgressDirty=$true;return}
        $code=$v.Task.Result
        if($code){$S.Fault='LaunchVerifyFailed:'+$v.Name+':'+$code;$S.ProgressDirty=$true;return}
    }
    try{
        $S.Bridge.Start([string]$S.Launch.Exe,[string]$S.Launch.Arguments,$null,[string]$S.Launch.DotnetRoot)
        $S.Phase='Running'
        Add-SjcExplorerRequest $S 'Health' $null @{}
    }catch{ $S.Fault='HostStartFailed:'+$_.Exception.GetType().Name; $S.ProgressDirty=$true }
}

function Get-SjcExplorerReasonText([string]$Code){
    $map=[ordered]@{'PackagedManifestHashMissing'='成品包内缺少探索组件清单的校验值';'PackagedManifestHashMismatch'='成品包内探索组件清单与构建时记录不一致';'ExplorerHostNotInstalled'='成品包不含探索组件';'ExplorerHostNotFound'='未找到探索组件';'ManifestHashMismatch'='开发运行时清单与指针记录的校验值不一致';'PointerHashMissing'='开发运行时指针缺少校验值';'LaunchVerifyFailed'='探索组件校验未通过，已拒绝启动';'LaunchSpecNotAllowed'='不允许的测试启动参数'}
    foreach($k in $map.Keys){ if($Code -like ($k+'*')){ return ($map[$k]+'（'+$Code+'）') } }
    return $Code
}

function Get-SjcExplorerHeadline($S){
    if($S.Fault){return ('探索服务异常：'+(Get-SjcExplorerReasonText $S.Fault)+'。请关闭窗口后重开。')}
    if($S.Phase -eq 'Verifying'){return '正在校验探索组件…'}
    if(-not $S.HostReady){return '正在连接探索服务…'}
    if(-not $S.CanInventory){return '探索服务已连接，但未声明可用的清点能力。'}
    if(Test-SjcExplorerBatchActive $S){return (Get-SjcExplorerBatchText $S)}
    if($S.LastError -eq 'IndexQuotaExceededReleaseCompletedTask'){return (Get-SjcExplorerQuotaText $S)}
    if($S.State -eq 'Partial' -and $S.Reason -eq 'SkippedOrUncoveredObjects'){
        $count=if($S.Coverage){[long]$S.Coverage['SkippedObjects']}else{0}
        return ('盘点已结束，{0:N0} 个对象未能覆盖；已读部分可继续分析。' -f $count)
    }
    return ('状态：'+(Get-SjcExplorerStateText $S.State)+$(if($S.Reason){'（'+$S.Reason+'）'}else{''}))
}
function Get-SjcExplorerCoverageExplanation($S){
    if($S.State -ne 'Partial'){return ''}
    $map=@{LinkOrCloud='链接或云占位';ProtectedScope='受保护位置';MetadataUnavailable='路径或属性不可读';DirectoryUnavailable='目录不可读';Other='其他未覆盖原因'}
    $parts=@();$reasons=$S['SkippedReasons']
    if($reasons -is [Collections.IDictionary]){foreach($key in @('LinkOrCloud','ProtectedScope','MetadataUnavailable','DirectoryUnavailable','Other')){if((@($reasons.Keys) -ccontains $key) -and [long]$reasons[$key] -gt 0){$parts+=($map[$key]+' '+('{0:N0}' -f [long]$reasons[$key]))}}}
    if($parts.Count){return ('未覆盖：'+($parts -join '；')+'。这些对象不会成为清理目标，其余已读内容可继续分析。')}
    return '部分位置未能读取或触发了保护；已读内容可继续分析。未覆盖不等于没有文件，也不代表需要清理。'
}

function Get-SjcExplorerMappedText($Map,[string]$Code,[string]$Fallback){
    if([string]::IsNullOrEmpty($Code)){return ''}
    if($Map.Contains($Code)){return [string]$Map[$Code]}
    if($Fallback){return ($Fallback+'：'+$Code)}
    return $Code
}

function Get-SjcExplorerClassText([string]$Code){
    Get-SjcExplorerMappedText ([ordered]@{Unknown='未确定';Cache='缓存';BuildArtifact='构建产物';InstallerDuplicate='安装包重复';UserData='用户数据';Mixed='混合内容';Portable='便携程序';SpaceOnly='仅空间展示'}) $Code '未识别类别'
}

function Get-SjcExplorerLevelText([string]$Code){
    Get-SjcExplorerMappedText ([ordered]@{Undetermined='未确定';ReviewSuggested='建议复核';OrganizeOpportunity='整理机会（仅展示）'}) $Code '未识别级别'
}

function Get-SjcExplorerImpactText([string]$Text){
    $map=[ordered]@{
        'Exact generated output files only; removing them would require a rebuild/redeployment and may break launch until rebuilt; project/source excluded'='仅限已精确识别的生成产物文件；移除后需要重新构建或重新部署，重建前可能无法启动；项目与源码不在其中。'
        'Exact recognized cache files only; future removal may cause cache regeneration, slower first load or loss of offline cached resources; application must be closed'='仅限已精确识别的缓存文件；移除后可能需要重新生成缓存、首次加载变慢，或丢失离线缓存的资源；需要先关闭相关应用。'
        'Personal/source/database/backup or incomplete mixture; display only, no processing candidates'='个人数据、源码、数据库、备份，或覆盖不完整的混合目录；仅展示，没有可处理的候选文件。'
        'Portable executable and settings may be the complete application; display only, not abandoned residue'='便携版程序及其设置可能就是完整的应用，不是遗留残留；仅展示。'
        'Space organization display only; size does not establish disposability'='仅用于空间整理展示；体积大不能说明可以清理。'
    }
    if($map.Contains($Text)){return [string]$map[$Text]}
    return ('（未翻译的 Host 原文）'+$Text)
}

function Get-SjcExplorerDoubtText([string]$Text){
    $map=[ordered]@{
        'Never classify protected data as cache'='受保护的数据不会被当作缓存。'
        'Space does not imply junk'='占用空间大不代表是垃圾。'
        'Private data/incomplete coverage blocks processing'='存在个人数据或覆盖不完整，禁止处理。'
        'Portable layout is not abandoned software'='便携布局不代表软件已被遗弃。'
        'Large file is display only'='大文件仅作展示。'
        'Build may be required again; no execution/project evaluation performed'='之后可能需要重新构建；探索过程没有运行或评估任何项目。'
        'Restricted dist evidence only; custom scripts never executed'='仅依据受限的 dist 目录证据判断；从不运行自定义脚本。'
        'Application may still depend on live cache; close and revalidate before future approval'='应用可能仍在使用该缓存；请先关闭应用，复核时会重新验证。'
    }
    if($map.Contains($Text)){return [string]$map[$Text]}
    return ('（未翻译的 Host 原文）'+$Text)
}

function Get-SjcExplorerEvidenceCodeText([string]$Code){
    Get-SjcExplorerMappedText ([ordered]@{
        RetainedCopyIdentityAndMetadataReconfirmed='已重新确认保留副本的身份与元数据';ChromiumIndexHeaderMagic='Chromium 缓存索引头标识匹配';DistIndexAndHashedAssets='存在 dist 入口页和带哈希的资源文件'
        DotNetGeneratedOutputMarkers='存在 .NET 生成输出的标记文件';DotNetProjectSdkMarkerNotOutput='发现 .NET 项目/SDK 标记，不是输出目录';PackageViteOrTscBuildMarkerNotOutput='发现 package/Vite/tsc 构建标记，不是输出目录'
        ChromiumIndexHeaderMismatch='Chromium 缓存索引头不匹配';DistGeneratedMarkersMissing='缺少 dist 生成标记';DotNetOutputMarkersMissing='缺少 .NET 输出标记';InsufficientLayoutEvidence='目录布局证据不足'
        NoVerifiedPackageDuplicates='未验证到安装包重复项';ProbeUnavailableOrInventoryChanged='探测不可用或盘点已变化';PersonalDatabaseBackupOrIncompleteMixed='含个人、数据库、备份内容，或混合且不完整'
        PersonalOrDatabaseMetadataOnly='个人或数据库文件（仅元数据）';PortableExecutableAndPortableMarker='便携程序及便携标记';UserReviewRequiredNoAuthorization='需要用户复核，尚未获得授权';LargeObservedFile='观察到的大文件'
    }) $Code '未识别事实'
}

function Get-SjcExplorerBlockedText([string]$Code){
    Get-SjcExplorerMappedText ([ordered]@{DeterministicProtectionOrExecutionPolicy='受确定性保护规则或执行策略限制，不能进入复核';ProofHashBudgetExceeded='达到证明文件哈希预算，此组暂不能准备批准'}) $Code '不可复核'
}

function Get-SjcExplorerAnalysisStatusText([string]$Code){
    if($Code -like 'AnalysisFailed:*'){return ('分析未完成（'+$Code.Substring(15)+'）')}
    Get-SjcExplorerMappedText ([ordered]@{None='尚未分析';Starting='正在启动分析';Running='启发式探索中';Complete='启发式探索完成';BudgetExhausted='探索预算用尽，结果不完整';NoProgress='没有新增证据，已停止';AskedUser='需要用户进一步确认';Cancelled='探索已取消，未处理文件';InvalidDecision='检查决策无效，结果不可信';Failed='分析未完成'}) $Code '分析状态'
}

function Get-SjcExplorerAnalysisFailureAction([string]$Code){
    switch -Regex ($Code){
        '^(AnalysisMemoryPressure|AnalysisResourcePressure)$'{return '已保留盘点记录，无需重扫。请在盘点页选择较小目录，再点“只分析所选目录”。'}
        '^(InventoryRootUnavailable)$'{return '请确认磁盘或文件夹可以访问，再重新盘点。'}
        '^(UnsupportedPath|InventoryLimitOrDuplicateObject)$'{return '请缩小到普通本地文件夹后重新盘点。'}
        '^(AnalysisUnavailable|AnalysisWorkerBusy)$'{return '请稍后再试。'}
        '^(UnownedOrUnstableInventory)$'{return '请等盘点结束后再试，必要时重新盘点。'}
        default{return '请重新盘点后再试。'}
    }
}
function Get-SjcExplorerAnalysisReasonText([string]$Reason){
    if($Reason -match '^Analysis(Memory|Resource)Pressure(?:\||$)'){return '当前内存或系统资源不足，剩余内容尚未完成。请缩小范围后重试。'}
    if([string]::IsNullOrEmpty($Reason)){return ''}
    $parts=foreach($p in $Reason.Split('|')){
        if($p -like 'HostAnalysis:*'){continue}
        Get-SjcExplorerMappedText ([ordered]@{NoUsefulChecksRemaining='没有剩余的有效检查';NoNewProbeEvidence='检查未获得新证据';Queued='已排队';LoadingInventorySnapshot='正在加载可信库存快照';PreparingSuggestionDisplay='正在准备建议展示信息';BuildingChargedInventoryIndex='正在建立受限库存索引';EvidencePriorityQueueReady='检查队列已就绪';UnknownFairExploration='正在检查证据不足的分支';EvidenceYieldCostBestFirst='按证据、收益和检查成本优先调查';EvidenceRecorded='已记录新证据';NoNewEvidenceStopBranch='此分支无新证据，停止继续检查';TargetBudget='达到目标数上限';ActionBudget='达到检查次数上限';DurationBudget='达到本轮时限';MetadataBudget='达到元数据检查上限';SampleBudget='达到采样预算';HashBudget='达到哈希预算';ReadMetadataOrHashBudget='元数据或哈希预算用尽';ExplicitCancellation='用户取消';ProtectedTarget='目标受保护，仅展示';StepBudget='检查步数预算用尽';PartialIndexMetadataBudget='索引预算不足，部分对象未覆盖';PartialIndexProbeAllowanceReserved='索引部分完成，已保留检查预算';ExactSetEvidenceSkipsRedundantLayout='已有精确集合证据，跳过重复布局检查';SuggestionDisplayBudget='结果展示数量达到上限，部分信息已省略';ProofHashBudgetExceeded='达到证明文件哈希预算，部分组暂不能准备批准'}) $p '原因'
    }
    return (@($parts) -join '；')
}

function Get-SjcExplorerQuotaText($S){
    return '无法开始新探索：索引空间达到保护上限。历史任务条数不限制；可在「历史任务」释放不再需要的已结束记录；若扫描记录占用仍高，请到「记录与帮助」点「刷新记录状态」，再按需「整理扫描记录占用…」。只处理本程序的扫描记录，不删除你的文件。'
}

function Get-SjcExplorerErrorText([string]$Code){
    switch($Code){
        { $_ -in 'AnalysisMemoryPressure','AnalysisResourcePressure' }{return '当前分析所需内存或系统资源较多，已安全停止；请缩小范围后重试，未分析部分仍未覆盖。'}
        'ApprovalPreparationActive'{return '复核清单仍在后台准备，请等待或返回取消。'}
        'PreparationCancelUnconfirmed'{return '取消未确认，请关闭并重开探索后重试；未批准或处理文件。'}
        'InvalidStorageBudget'{return '记录空间预算须为512到16384 MiB。'}
        'StorageBudgetBelowExistingUsage'{return '预算小于现有记录占用，请选择更高预算；不会自动删除记录。'}
        'ExplicitStorageBudgetConfirmationRequired'{return '更改记录空间预算需要明确确认。'}
    }
    if([string]::IsNullOrEmpty($Code)){return ''}
    $m=[ordered]@{
        ExecutionEvidenceReservationActive='正在为当前执行保留账本空间，请等待执行结束后再准备/确认或整理其它材料'
        ApprovalStorageQuota='批准材料空间达到上限；请到「记录与帮助」点「重置已结束的分析…」，再按需「整理未确认的复核材料…」。已确认和执行凭据不会自动清除'
        ApprovalWriteCapacityExceeded='批准记录容量不足，未开始新的副作用；请到「记录与帮助」点「刷新记录状态」查看'
        ApprovalExecutionFileReserve='批准材料文件数不足以保留执行证据，未开始处理'
        ExecutionLedgerBudgetExceeded='本次清单过大，超过执行账本证据预算，请减少选择后重新准备'
        ExecutionLedgerDriveSpace='磁盘余量不足以可靠记录执行账本，未开始处理'
        SessionWorkActive='仍有分析或执行工作，结束或取消后再整理资源'
        InventoryActive='盘点仍活动，暂停或结束后再整理'
        InsufficientDriveSpace='可用磁盘空间不足以保留备份和整理临时量，未继续整理'
        ExplicitCompactionConfirmationRequired='索引整理需要明确确认'
        ExplicitSessionReleaseConfirmationRequired='「重置已结束的分析…」需要明确确认'
        ExplicitApprovalArchiveConfirmationRequired='整理未确认草稿需要明确确认'
        NoUnconfirmedDraftsToArchive='没有可整理的未确认失效草稿；已确认和执行证据保留'
        ApprovalArchivePartial='草稿整理仅部分完成，现场和逐项清单已保留，请核对显示的保留目录'
        LedgerObjectNotInDraft='执行账本出现不属于封存清单的对象，结果未知，不显示成功'
        ExecutionSessionLimit='执行队列达到上限，等待当前工作结束后再试'
        NoFixedDisks='没有可用的固定磁盘，请连接磁盘后重试，或选择一个明确的文件夹/磁盘路径'
        IndexQuotaExceededReleaseCompletedTask='索引空间已达保护上限，请到「历史任务」释放不再需要的已结束扫描记录（不删除磁盘文件）'
        InventoryRevisionOrStageChanged='盘点已变化或尚未完成，请等盘点结束后重新分析';AnalysisWorkerBusy='已有分析正在运行，请等待结束';InvalidatePreviousAnalysisFirst='需要先作废上一次分析';AnalysisQuotaInvalidatePrevious='内存分析会话达到上限，请到「记录与帮助」点「刷新记录状态」，再点「重置已结束的分析…」并确认；旧建议和批准会失效，扫描历史保留'
        TargetNotInInventory='所选目录不在本次盘点范围内';AnalysisRevisionInvalidated='盘点已变化，原分析结果已作废，请重新分析';AnalysisNotReady='分析尚未完成';AnalysisNotReadyOrChanged='分析尚未完成或已变化，请重新分析'
        AnalysisNotOwnedOrMissing='找不到该分析（可能已作废）';SuggestionNotOwnedOrMissing='找不到该建议';SuggestionSetNotReviewable='所选建议中有不可复核的项目，未生成清单';DraftNotOwnedByTask='清单不属于当前任务'
        DisplayedSnapshotMismatch='界面显示的清单与 Host 草稿不一致，未确认；请返回重新生成';RecycleDisabledNoClaimConsumed='回收站处理当前未启用，未处理任何文件，批准也未被消耗';ExecuteNotArmed='未经用户明确确认，已拒绝发送执行请求'
        RequestRejectedLocally='请求被本地校验拒绝';TaskNotReleasable='该任务还不能释放';InvalidPage='分页参数无效';InvalidCursor='分页游标无效，请重新加载第一页';CursorRevisionChanged='盘点已变化，请重新加载第一页';SpaceRevisionChanged='空间排行与当前盘点版本不一致，请刷新'
        BatchRevisionChanged='批次状态已更新（可能某个条目刚结束），已自动刷新最新状态，请核对后重试操作'
        BatchContinuationRequired='需要先明确确认继续该批次，才能启动或恢复剩余扫描'
        BatchStageMismatch='批次当前阶段不允许此操作，已刷新最新状态'
        BatchNothingToContinue='该批次没有可继续的待扫描或暂停项'
        BatchNothingToStart='该批次没有剩余待启动的条目'
        BatchEntryOutOfOrder='批次条目顺序与当前快照不一致，已刷新最新状态'
        BatchEntryStartRequired='该任务属于全盘批次，请使用「继续剩余扫描…」按批次恢复，不能绕过批次单独继续'
        SnapshotRootChangedOrUnavailable='批次记录的磁盘或根目录已变化或不可用，批次已安全停止且不自动扫下一盘'
        BatchActive='已有活动的全盘批次，请先等待结束、暂停或取消'
        BatchTaskControlRace='当前条目刚结束或状态切换中，已刷新最新状态，请核对后重试'
        BatchTaskStateChanged='批次关联任务状态已变化，已刷新最新状态'
        ExplicitBatchContinuationRequired='继续全盘批次必须经过明确确认'
        NonCanonicalPath='盘点记录中的路径无法按原样稳定识别，分析未完成。请重新盘点后再分析'
        UnsupportedPath='盘点记录包含当前不支持的路径，分析未完成。请缩小到普通本地文件夹后重新盘点'
        InventoryOutsideScope='盘点记录超出本次选定范围，分析未完成。请重新盘点当前范围'
        InventoryRootUnavailable='盘点根目录当前不可用，分析未完成。请确认磁盘或文件夹可访问后重新盘点'
        InventoryRootMismatch='盘点根目录与当前任务不一致，分析未完成。请重新盘点后再分析'
        InventoryRevisionChangedDuringExport='分析准备期间盘点版本已变化，结果未完成。请重新盘点并重新分析'
        InventoryRevisionChangedDuringAnalysis='分析期间盘点版本已变化，结果未完成。请重新盘点并重新分析'
        InvalidInventoryParent='盘点记录的目录关系无效，分析未完成。请重新盘点'
        InvalidInventoryRow='盘点记录内容无效，分析未完成。请重新盘点'
        InventoryLimitOrDuplicateObject='盘点记录达到限制或对象重复，分析未完成。请缩小范围后重新盘点'
        DuplicateInventoryPath='盘点记录出现重复路径，分析未完成。请重新盘点'
        UnownedOrUnstableInventory='盘点记录不属于当前任务或尚未稳定，分析未完成。请等待盘点结束或重新盘点'
        ProofSourceChangedDuringBinding='准备复核证据时源文件已变化，本次未完成。请重新盘点并重新分析'
        AnalysisUnavailable='分析服务当前不可用，分析未完成。请稍后重试'
        InvalidAnalysisSnapshot='分析快照无效，分析未完成。请重新盘点后再分析'
    }
    if($Code -like 'RequestRejectedLocally:*'){return ('请求被本地校验拒绝（'+$Code.Substring(24)+'）')}
    if($m.Contains($Code)){return ([string]$m[$Code]+'（'+$Code+'）')}
    return $Code
}

function Test-SjcExplorerMaintenanceReady($S){
    if(($S.Draft -and $S.Draft['Pending'] -eq $true) -or $S['AbandonedPrep']){return $false}
    return [bool]($S.HostReady -and -not $S.Fault -and -not $S.Closing -and -not $S.InFlight -and $S.Queue.Count -eq 0 -and -not (Test-SjcExplorerBatchActive $S) -and $S.State -ne 'Inventory' -and -not ($S.Analysis -and -not $S.Analysis.Terminal) -and -not ($S.Exec -and -not $S.Exec.Terminal))
}
function Request-SjcExplorerStorage($S){
    if(Test-SjcExplorerHasOp $S 'GetStorageInfo'){Add-SjcExplorerRequest $S 'GetStorageInfo' $null @{}}
    if(Test-SjcExplorerHasOp $S 'GetSessionInfo'){Add-SjcExplorerRequest $S 'GetSessionInfo' $null @{}}
    $S.ApprovalDirty=$true
}
function Request-SjcExplorerStorageAutoRead($S){
    if(-not $S -or $S['StorageAutoRead'] -or $S.Fault -or $S.Closing -or -not $S.HostReady){return}
    if(-not (Test-SjcExplorerMaintenanceReady $S)){return}
    if(-not (Test-SjcExplorerHasOp $S 'GetStorageInfo') -or -not (Test-SjcExplorerHasOp $S 'GetSessionInfo')){return}
    $S['StorageAutoRead']=$true
    $S['StorageReadFailed']=$false;$S['SessionReadFailed']=$false
    Request-SjcExplorerStorage $S
}
function Get-SjcExplorerRecordStatus($S){
    $pending=@($S.Queue | Where-Object {$_.Op -in 'GetStorageInfo','GetSessionInfo'})
    $inFlight=($S.InFlight -and $S.InFlight.Op -in 'GetStorageInfo','GetSessionInfo')
    if(($S['StorageReadFailed'] -or $S['SessionReadFailed']) -and -not $pending.Count -and -not $inFlight){return 'Failed'}
    if($pending.Count -or $inFlight){return 'Loading'}
    if($S['Storage'] -and $S['SessionInfo']){return 'Loaded'}
    return 'NotLoaded'
}
function Update-SjcExplorerRecordView($W,$S){
    $e=$W.Tag.Controls
    if(-not $e.ContainsKey('StorageText')){return}
    $st=$S['Storage'];$si=$S['SessionInfo'];$idle=Test-SjcExplorerMaintenanceReady $S
    $status=Get-SjcExplorerRecordStatus $S
    $e.StorageRefresh.IsEnabled=[bool]((Test-SjcExplorerHasOp $S 'GetStorageInfo') -and $status -ne 'Loading')
    $maintenanceReady=($idle -and $status -eq 'Loaded')
    $e.StorageCompact.IsEnabled=[bool]($maintenanceReady -and $st -and $st['CanCompact'] -eq $true -and (Test-SjcExplorerHasOp $S 'CompactState'))
    $e.SessionRelease.IsEnabled=[bool]($maintenanceReady -and (Test-SjcExplorerHasOp $S 'ReleaseFinishedSessions'))
    $e.DraftArchive.IsEnabled=[bool]($maintenanceReady -and $si -and $si['ApprovalStorage'] -and [long]$si['ApprovalStorage']['ReclaimableDrafts'] -gt 0 -and (Test-SjcExplorerHasOp $S 'ArchiveUnconfirmedDrafts'))
    $storageFailed=[bool]$S['StorageReadFailed'];$sessionFailed=[bool]$S['SessionReadFailed']
    $storageDetail='技术详情尚未读取。';$sessionDetail='分析与批准材料的技术详情尚未读取。'
    if($storageFailed -and -not $sessionFailed -and -not $si){
        $summary='读取扫描记录占用失败。';$maintenance='不能确认是否需要维护；未自动整理。';$sessionSummary='已结束分析状态尚未返回。';$storageDetail='读取失败，不显示占用数值。'
    }elseif($sessionFailed -and -not $storageFailed -and -not $st){
        $summary='扫描记录占用尚未返回。';$maintenance='维护状态尚未返回。';$sessionSummary='读取已结束分析状态失败。';$sessionDetail='读取失败，不显示会话或批准材料数值。'
    }elseif($sessionFailed -and -not $storageFailed -and $st){
        $summary=('扫描记录占用 {0} / {1}。' -f (Format-SjcExplorerBytes $st['TotalBytes']),(Format-SjcExplorerBytes $st['MaxStateBytes']))
        $maintenance='部分状态未能读取，暂不建议维护。请刷新重试，或保存问题报告。'
        $sessionSummary='读取已结束分析状态失败。'
    }elseif($status -eq 'Failed'){
        $summary='读取扫描记录状态失败。'
        $maintenance='不能确认是否需要维护；未自动整理。'
        $sessionSummary='读取已结束分析状态失败。'
        $storageDetail='读取失败，不显示占用数值。'
        $sessionDetail='读取失败，不显示会话或批准材料数值。'
    }elseif($status -eq 'Loading' -or -not $st){
        $summary=$(if($status -eq 'Loading'){'正在读取扫描记录占用…'}else{'尚未读取扫描记录占用。'})
        $maintenance=$(if($status -eq 'Loading'){'正在读取维护状态…'}else{'维护状态尚未读取。'})
        $sessionSummary=$(if($status -eq 'Loading'){'正在读取已结束的分析状态…'}else{'尚未读取已结束的分析状态。'})
    }else{
        $used=(Format-SjcExplorerBytes $st['TotalBytes']);$limit=$(if($null -ne $st['MaxStateBytes']){(Format-SjcExplorerBytes $st['MaxStateBytes'])}else{'未提供'})
        $summary=('扫描记录占用 {0} / {1}。' -f $used,$limit)
        # CanCompact describes permission/availability, not a recommendation.
        # Only known reclaimable pages or a near-quota store justify suggesting it.
        $limitBytes=[long]$st['MaxStateBytes'];$usedBytes=[long]$st['TotalBytes'];$reusable=[long]$st['ReusableBytes']
        $worthReview=($limitBytes -gt 0 -and $usedBytes -ge ($limitBytes*0.8)) -or ($reusable -ge 16MB -and $usedBytes -gt 0 -and $reusable -ge ($usedBytes*0.25))
        $maintenance=if(-not $worthReview){'记录空间预算尚充足，暂不需要整理；上方数字不是待清理文件的大小。'}elseif($st['CanCompact'] -eq $true){'记录占用接近预算，或有较多可复用空间；可按需整理，操作前会保留备份。'}else{'当前无法整理，请在高级详情中查看原因；不会自动处理。'}
        $sessionSummary='已结束分析状态尚未读取。'
    }
    if($storageFailed){$summary='读取扫描记录占用失败。';$maintenance='不能确认是否需要维护；未自动整理。';$storageDetail='读取失败，不显示占用数值。'}
    elseif($st){
        $storageText=('索引总占用 {0} / 配额 {1}；主库 {2}，WAL {3}，可复用页 {4}。任务 {5}，对象 {6}。整理预计额外空间 {7}（包含备份、临时量与预留），可用 {8}。{9}' -f (Format-SjcExplorerBytes $st['TotalBytes']),(Format-SjcExplorerBytes $st['MaxStateBytes']),(Format-SjcExplorerBytes $st['DbBytes']),(Format-SjcExplorerBytes $st['WalBytes']),(Format-SjcExplorerBytes $st['ReusableBytes']),$st['Tasks'],$st['Objects'],(Format-SjcExplorerBytes $st['EstimatedExtraBytes']),(Format-SjcExplorerBytes $st['AvailableDriveBytes']),$(if($st['CompactionReason']){'当前不可整理：'+(Get-SjcExplorerErrorText ([string]$st['CompactionReason']))}else{'需你明确确认才整理，历史不会自动删除。'}))
        if($st.ContainsKey('RetainedBackupBytes')){$storageText+=(' 保留备份 {0} 份，占 {1}（未计入活动索引配额）；不可统计项 {2}。' -f $st['RetainedBackupDirectories'],(Format-SjcExplorerBytes $st['RetainedBackupBytes']),$st['RetainedBackupUnavailableEntries'])}
        if($st.ContainsKey('IndexRepairPending') -and $st['IndexRepairPending'] -eq $true){$storageText+=' 记录可查看；空间预算不足，性能索引待重建。确认调整预算后重试。'}
        $storageDetail=$storageText
    }
    if($sessionFailed){$sessionSummary='读取已结束分析状态失败。';$sessionDetail='读取失败，不显示会话或批准材料数值。'}
    elseif($si){
        $a=$si['ApprovalStorage']
        $sessionText=('分析会话 {0}/{1}（活动 {2}）；执行会话 {3}/{4}（活动 {5}）；草稿绑定 {6}。' -f $si['AnalysisSessions'],$si['AnalysisLimit'],$si['ActiveAnalyses'],$si['ExecutionSessions'],$si['ExecutionLimit'],$si['ActiveExecutions'],$si['DraftBindings'])
        if($a){$sessionText+=(' 批准材料 {0}/{1}，{2}/{3} 个文件，未确认可整理 {4} 份。已确认和执行记录保留。' -f (Format-SjcExplorerBytes $a['Bytes']),(Format-SjcExplorerBytes $a['MaxBytes']),$a['Files'],$a['MaxFiles'],$a['ReclaimableDrafts'])}
        if($a -and $a.ContainsKey('RetainedArchiveBytes')){$sessionText+=(' 保留区 {0} 份，占 {1}，不可统计项 {2}；这些仍占磁盘空间。' -f $a['RetainedArchiveDirectories'],(Format-SjcExplorerBytes $a['RetainedArchiveBytes']),$a['RetainedArchiveUnavailableEntries'])}
        $sessionDetail=$sessionText
        if($status -eq 'Loaded'){
            $active=[int]$si['ActiveAnalyses']+[int]$si['ActiveExecutions']
            $finished=([int]$si['AnalysisSessions']+[int]$si['ExecutionSessions'])-$active
            if($finished -lt 0){$finished=0}
            $sessionSummary=('已结束的分析或处理会话 {0} 个，活动会话 {1} 个。' -f $finished,$active)
            if($a -and [long]$a['ReclaimableDrafts'] -gt 0){$sessionSummary+='有未确认的复核材料可以整理。'}
        }
    }elseif($status -eq 'Loaded'){$sessionSummary='已结束分析状态尚未返回。'}
    if($e.ContainsKey('StorageSummaryText')){$e.StorageSummaryText.Text=$summary}
    if($e.ContainsKey('StorageMaintenanceText')){$e.StorageMaintenanceText.Text=$maintenance}
    if($e.ContainsKey('SessionSummaryText')){$e.SessionSummaryText.Text=$sessionSummary}
    $e.StorageText.Text=$storageDetail
    $e.SessionText.Text=$sessionDetail
    if($e.ContainsKey('StorageDetailText')){$e.StorageDetailText.Text=$storageDetail}
    if($e.ContainsKey('SessionDetailText')){$e.SessionDetailText.Text=$sessionDetail}
    $e.StorageNotice.Text=[string]$S['StorageNotice']
    $e.StorageNotice.ToolTip=[string]$S['StorageNotice']
    if([string]$S['StorageNotice'] -match '^已整理 (\d+) 份未确认草稿至 '){$e.StorageNotice.Text=('已将 {0} 份未确认清单移到保留区；未删除你的文件，保留副本仍占空间。完整位置可悬停查看。' -f $matches[1])}
    $e.StorageNotice.Visibility=if([string]$S['StorageNotice']){'Visible'}else{'Collapsed'}
}
function Request-SjcExplorerMaintenance($S,[string]$Operation,[bool]$Confirmed){
    if(-not $Confirmed -or $Operation -notin 'CompactState','ArchiveUnconfirmedDrafts','ReleaseFinishedSessions' -or -not (Test-SjcExplorerMaintenanceReady $S) -or -not (Test-SjcExplorerHasOp $S $Operation)){return $false}
    if($Operation -eq 'CompactState' -and (-not $S['Storage'] -or -not $S.Storage['CanCompact'])){return $false}
    Add-SjcExplorerRequest $S $Operation $null @{Confirmed=$true};$S['StorageNotice']='操作已请求；请等待明确结果，不要重复执行。';$S.ApprovalDirty=$true
    return $true
}
function Set-SjcExplorerHistoryFilter($S,[string]$Filter){
    if($null -eq $Filter){$Filter=''}
    if($Filter.Length -gt 1800){throw 'HistoryFilterTooLong'}
    $S['HistoryFilter']=$Filter;$S.TaskList=@();$S.TaskListDirty=$true
    Request-SjcExplorerTaskList $S 0
}
function Get-SjcExplorerReasonCategoryText([string]$Category){
    switch($Category){
        'Reviewable'{'可复核：精确集合仍需你确认'}
        'Protected'{'受保护：用户数据、源码或便携程序，建议保留'}
        'MixedMembers'{'混合成员：含额外/受保护文件或覆盖缺口，整组不处理'}
        'Coverage'{'覆盖不足：有缺口或索引不全，可缩小到可访问范围重扫'}
        'Budget'{'预算不足：本轮未能完成证据，可缩小范围重试'}
        'OrganizeOnly'{'仅供整理：重复或大文件不构成回收授权'}
        'UnsupportedLayout'{'布局证据不足：当前不授予回收资格'}
        default{'受保护或证据不足，不处理'}
    }
}
function Get-SjcExplorerEntryRows($S){
    if(-not $S.Exec){return @()}
    $index=0
    @($S.Exec.Entries | ForEach-Object {
        $index++;$path=if($_.ContainsKey('Path')){[string]$_['Path']}else{'对象 '+[string]$_['ObjectId']}
        [pscustomobject]@{Number=$index;Path=$path;Status=(Get-SjcExplorerExecEntryText ([string]$_['Status']) ([string]$_['Reason']));RawStatus=[string]$_['Status'];Reason=[string]$_['Reason'];Logical=(Format-SjcExplorerBytes $_['LogicalBytes'])}
    })
}
function Show-SjcExplorerExecutionEntries($Owner,$S){
    if(-not $S.Exec){return}
    $x=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="逐项执行记录（只读）" Width="980" Height="560" MinWidth="720" MinHeight="400" Background="White" FontFamily="Microsoft YaHei UI" FontSize="13">
 <Grid Margin="14"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <TextBlock x:Name="Note" TextWrapping="Wrap" Margin="0,0,0,10"/>
 <ListView x:Name="Rows" Grid.Row="1"><ListView.View><GridView>
 <GridViewColumn Header="账本序号" DisplayMemberBinding="{Binding Number}" Width="70"/><GridViewColumn Header="精确路径（悬停查看）" Width="430"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Path}" ToolTip="{Binding Path}" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
 <GridViewColumn Header="状态/原因" Width="380"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Status}" ToolTip="{Binding Status}" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
 </GridView></ListView.View></ListView>
 <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0"><Button x:Name="Prev" Content="上一页" Padding="12,6"/><Button x:Name="Next" Content="下一页" Padding="12,6" Margin="8,0"/><TextBlock x:Name="Page" VerticalAlignment="Center"/></StackPanel>
 </Grid>
</Window>
'@
    $w=[Windows.Markup.XamlReader]::Parse($x);if($Owner -and $Owner.IsLoaded){$w.Owner=$Owner}
    $st=@{Offset=0;Rows=@(Get-SjcExplorerEntryRows $S)};$list=$w.FindName('Rows');$prev=$w.FindName('Prev');$next=$w.FindName('Next');$page=$w.FindName('Page')
    $w.FindName('Note').Text='逐项账本包含“准备尝试”和最终记录，同一文件可能有多条。最终汇总按每个文件最后记录计算；未知不当作成功。窗口显示打开时快照，处理中请关闭后重新打开刷新。'
    $render={
        $list.ItemsSource=@($st.Rows | Select-Object -Skip $st.Offset -First 64)
        $prev.IsEnabled=($st.Offset -ge 64);$next.IsEnabled=($st.Offset+64 -lt $st.Rows.Count)
        $page.Text=('第 {0} 页，共 {1} 条账本记录' -f (1+[int]($st.Offset/64)),$st.Rows.Count)
    }.GetNewClosure()
    $prev.Add_Click({$st.Offset=[math]::Max(0,$st.Offset-64);& $render}.GetNewClosure())
    $next.Add_Click({if($st.Offset+64 -lt $st.Rows.Count){$st.Offset+=64};& $render}.GetNewClosure())
    & $render;[void]$w.ShowDialog()
}
function New-SjcExplorerDiagnostic($S){
    # Explicit field allowlist. Never include paths, task IDs, URL/key, stderr or raw exception text.
    $analysis=@{};if($S.Analysis){
        foreach($k in @('Usage','Timing')){
            $value=$S.Analysis[$k]
            if($value -is [Collections.IDictionary]){$safe=@{};foreach($n in @('Steps','MetadataObjects','ReadFiles','SampleBytes','HashBytes','HashFiles','SnapshotMilliseconds','AnalysisMilliseconds','ProofAndDisplayMilliseconds','TotalMilliseconds')){if((@($value.Keys) -ccontains $n) -and $value[$n] -is [ValueType]){$safe[$n]=$value[$n]}};$analysis[$k]=$safe}
        }
    }
    $code=if($S.LastError -match '^[A-Za-z0-9_]{1,100}$'){$S.LastError}else{'RedactedOrNone'}
    if($S.Analysis){
        $analysisStatus=if($S.Analysis.ContainsKey('Status')){[string]$S.Analysis['Status']}else{''}
        $analysisCode=([string]$S.Analysis['Reason']).Split('|')[0]
        if($analysisCode -match '^[A-Za-z0-9_]{1,100}$|^AnalysisFailed:[A-Za-z0-9_]{1,40}$'){
            $analysis['ReasonCode']=$analysisCode
            if($analysisStatus -in 'Failed','InvalidDecision','BudgetExhausted'){$code=$analysisCode}
        }
        if($analysisStatus -in 'Starting','Running','Complete','BudgetExhausted','NoProgress','AskedUser','Cancelled','InvalidDecision','Failed'){$analysis['Status']=$analysisStatus}
    }
    $state=if($S.State -in 'Inventory','Paused','Ready','Partial','Cancelled','Failed'){$S.State}else{'NotStarted'}
    $entries=@{};if($S.Exec){foreach($entry in $S.Exec.Entries){$status=[string]$entry['Status'];if($status -notin 'Attempting','Recycled','Skipped','NotAttempted','UnknownOrFailed'){$status='Unknown'};if(-not $entries.ContainsKey($status)){$entries[$status]=0};$entries[$status]++}}
    return [ordered]@{Schema='SafeJunkCleaner.LocalDiagnostic.v1';CreatedUtc=[datetime]::UtcNow.ToString('o');Version=(Get-SjcVersion);Privacy='NoBodyNoPathsNoIdsNoUrlNoTokensNoRawStderr';State=$state;ErrorCode=$code;Analysis=$analysis;ExecutionStatusCounts=$entries;Manifest=@{Included=@('version','state','safe error code','numeric budget/timing','execution status counts');Excluded=@('file contents','paths','task IDs','URLs','keys','tokens','raw stderr','exception details');UploadPerformed=$false}}
}
function Export-SjcExplorerDiagnostic($S,[string]$Destination){
    if([string]::IsNullOrWhiteSpace($Destination) -or -not [IO.Path]::IsPathRooted($Destination)){throw 'DiagnosticDestinationRequired'}
    if([IO.File]::Exists($Destination) -or [IO.Directory]::Exists($Destination)){throw 'DiagnosticDestinationExists'}
    if(-not (Test-SjcNoReparsePath ([IO.Path]::GetDirectoryName($Destination)))){throw 'DiagnosticDestinationUnsafe'}
    $payload=New-SjcExplorerDiagnostic $S;$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($payload|ConvertTo-Json -Depth 10))
    $stream=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    return $Destination
}

function Get-SjcExplorerExecEntryText([string]$Status,[string]$Reason){
    $s=switch($Status){'Recycled'{'已移入回收站'} 'Skipped'{'已跳过（未处理）'} 'NotAttempted'{'未尝试处理'} 'Attempting'{'已记录尝试意图，尚无最终确认'} 'UnknownOrFailed'{'未知或失败，需核对'} default{'未知（'+$Status+'）'}}
    if($Reason){return ($s+'：'+$Reason)}
    return $s
}

function Initialize-SjcExplorerApprovalState($S){
    $S['Storage']=$null;$S['SessionInfo']=$null;$S['StorageNotice']='';$S['HistoryFilter']='';$S['AbandonedPrep']=$null
    $S.Analysis=$null; $S.AnalysisTick=0
    $S.Suggestions=@(); $S.SugIndex=@{}; $S.SugNext=$null; $S.SugStack=[Collections.Generic.List[string]]::new(); $S.SugStack.Add(''); $S.SugDirty=$true; $S.SugStatus=$null
    $S.Selected=[Collections.Generic.Dictionary[string,bool]]::new()
    $S.SugFilesFor=$null; $S.SugFiles=@(); $S.SugFilesNext=$null; $S.SugFilesStack=[Collections.Generic.List[string]]::new(); $S.SugFilesStack.Add(''); $S.SugFilesDirty=$false
    $S.Draft=$null; $S.DraftItems=@(); $S.DraftNext=$null; $S.DraftStack=[Collections.Generic.List[int]]::new(); $S.DraftStack.Add(0); $S.DraftDirty=$false
    $S.Approval=$null; $S.Exec=$null; $S.ApprovalDirty=$true
    $S.TaskList=@(); $S.TaskListNext=$null; $S.TaskListStack=[Collections.Generic.List[string]]::new(); $S.TaskListStack.Add(''); $S.TaskListDirty=$false; $S.TaskListLoaded=$false
    $S['BatchList']=@(); $S['BatchListNext']=$null; $S['BatchListStack']=[Collections.Generic.List[string]]::new(); $S['BatchListStack'].Add(''); $S['BatchListDirty']=$false; $S['BatchListLoaded']=$false
}

function Reset-SjcExplorerApproval($S){
    # 任何新的盘点/分析都会使旧的建议、选择、复核草稿与批准在界面上作废（Host 侧批准绑定的是旧快照）。
    $d=$S.Draft
    if($d -and $d['Pending'] -eq $true -and $d['PreparationId']){
        $origTask=if($d['TaskId']){[string]$d['TaskId']}else{[string]$S.TaskId}
        Start-SjcExplorerAbandonedCancel $S $origTask ([string]$d['PreparationId'])
    }
    foreach($stalePrep in @($S.Queue | Where-Object {$_.Op -in 'BeginPrepareApproval','PrepareApproval','GetPreparationProgress' -and $_['AbandonedDrain'] -ne $true})){[void]$S.Queue.Remove($stalePrep)}
    $S.Suggestions=@(); $S.SugIndex=@{}; $S.SugNext=$null; $S.SugStack.Clear(); $S.SugStack.Add(''); $S.SugDirty=$true; $S.SugStatus=$null; $S.Selected.Clear()
    $S.SugFilesFor=$null; $S.SugFiles=@(); $S.SugFilesNext=$null; $S.SugFilesStack.Clear(); $S.SugFilesStack.Add(''); $S.SugFilesDirty=$true
    $S.Draft=$null; $S.DraftItems=@(); $S.DraftNext=$null; $S.DraftStack.Clear(); $S.DraftStack.Add(0); $S.DraftDirty=$true
    $S.Approval=$null; $S.Exec=$null; $S.ApprovalDirty=$true
    Step-SjcExplorerGen $S 'Draft'
}

function Test-SjcExplorerHostCap($S,[string]$Name){ return ($S.Capabilities.ContainsKey($Name) -and $S.Capabilities[$Name] -eq $true) }

function Test-SjcExplorerHasOp($S,[string]$Op){ return ($S.HostReady -and -not $S.Fault -and ($S.Operations -contains $Op)) }

function Set-SjcExplorerCurrentTask($S,[string]$TaskId,[string]$State){
    Step-SjcExplorerGen $S 'Task'; Step-SjcExplorerGen $S 'Analysis'
    $S.ProgressDirty=$true
    Reset-SjcExplorerProgressDisplay $S
    $S.TaskId=$TaskId; $script:SjcExplorerLastTaskId=$TaskId; $S.State=$State; $S.Reason=$null; $S.Revision=$null; $S.Coverage=$null
    $S.Groups=@();$S.Evidence=@();$S.ParentId=$null;$S.GroupsRevision=$null
    $S.GroupsStack.Clear();$S.GroupsStack.Add(0);$S.EvidenceStack.Clear();$S.EvidenceStack.Add(0)
    $S.GroupsNext=$null;$S.EvidenceNext=$null;$S.GroupsDirty=$true;$S.EvidenceDirty=$true
    $S.Space=@();$S.SpaceNext=$null;$S.SpaceRevision=$null;$S.SpaceStack.Clear();$S.SpaceStack.Add('');$S.SpaceDirty=$true
    $S.Analysis=$null; Reset-SjcExplorerApproval $S
    Add-SjcExplorerRequest $S 'GetProgress' $S.TaskId @{}
}

function Test-SjcExplorerCanAnalyze($S,[string]$ExplorationMode='Selected'){
    if(Test-SjcExplorerBatchActive $S){return $false}
    if(-not (Test-SjcExplorerHasOp $S 'Analyze') -or -not (Test-SjcExplorerHostCap $S 'HeuristicExploration')){return $false}
    if($ExplorationMode -notin 'Scope','Selected' -or -not $S.TaskId -or $S.State -notin 'Ready','Partial' -or $null -eq $S.Revision){return $false}
    if($ExplorationMode -eq 'Selected' -and $null -eq $S.ParentId){return $false}
    if($S.Analysis -and -not $S.Analysis.Terminal){return $false}
    if($S.Exec -and -not $S.Exec.Terminal){return $false}
    return $true
}

function Start-SjcExplorerAnalysis($S,[string]$ExplorationMode='Selected'){
    if(-not (Test-SjcExplorerCanAnalyze $S $ExplorationMode)){return $false}
    $prev=$S.Analysis
    if($prev -and $prev.Id){ Add-SjcExplorerRequest $S 'InvalidateAnalysis' $S.TaskId @{AnalysisId=[string]$prev.Id} }
    elseif($prev -and $prev.Requested){ return $false }
    Step-SjcExplorerGen $S 'Analysis'
    Reset-SjcExplorerApproval $S
    $target=$null;if($ExplorationMode -eq 'Selected'){$target=[string]$S.ParentId}
    $payload=@{TargetId=$target;ExpectedEvidenceRevision=[long]$S.Revision;ExplorationMode=$ExplorationMode}
    $tp=@($S.Groups | Where-Object {[string]$_['GroupId'] -eq [string]$S.ParentId} | ForEach-Object {[string]$_['Path']})
    $S.Analysis=@{Id=$null;Status='Starting';Reason=$null;Usage=$null;Progress=$null;Timing=$null;Outcome=$null;TargetPath=$(if($ExplorationMode -eq 'Scope'){'整个选定范围'}elseif($tp.Count){$tp[0]}else{''});TargetId=$target;Revision=[long]$S.Revision;Requested=$true;Terminal=$false;Ready=$false;Mode=$ExplorationMode;ErrorCode=$null;CancelRequested=$false}
    $S.AnalysisTick=[Environment]::TickCount
    Add-SjcExplorerRequest $S 'Analyze' $S.TaskId $payload
    $S.ApprovalDirty=$true; $S.SugDirty=$true
    return $true
}

function Stop-SjcExplorerAnalysis($S){
    if(-not $S.Analysis -or -not $S.Analysis.Id -or $S.Analysis.Terminal -or $S.Analysis.CancelRequested -or -not (Test-SjcExplorerHasOp $S 'CancelAnalysis')){return $false}
    $S.Analysis.CancelRequested=$true
    Add-SjcExplorerRequest $S 'CancelAnalysis' $S.TaskId @{AnalysisId=[string]$S.Analysis.Id}
    $S.ApprovalDirty=$true
    return $true
}

function Request-SjcExplorerSpacePage($S,[int]$Direction=0){
    if(-not $S.TaskId -or $S.State -notin 'Ready','Partial' -or -not (Test-SjcExplorerHasOp $S 'QuerySpace')){return $false}
    if($Direction -eq 0){$S.SpaceStack.Clear();$S.SpaceStack.Add('')}
    elseif($Direction -gt 0 -and $null -ne $S.SpaceNext){$S.SpaceStack.Add([string]$S.SpaceNext)}
    elseif($Direction -lt 0 -and $S.SpaceStack.Count -gt 1){$S.SpaceStack.RemoveAt($S.SpaceStack.Count-1)}else{return $false}
    $cursor=$S.SpaceStack[$S.SpaceStack.Count-1];if($cursor -eq ''){$cursor=$null}
    $spaceOp=if(Test-SjcExplorerHasOp $S 'QuerySpaceAsync'){'QuerySpaceAsync'}else{'QuerySpace'}
    Add-SjcExplorerRequest $S $spaceOp $S.TaskId @{AfterCursor=$cursor;PageSize=64}
    return $true
}

function Move-SjcExplorerSpacePage($S,[int]$Direction){[void](Request-SjcExplorerSpacePage $S $Direction)}

function Move-SjcExplorerSuggestionPage($S,[int]$Direction){
    if(-not $S.Analysis -or -not $S.Analysis.Id -or -not $S.Analysis.Ready){return}
    if($Direction -gt 0 -and $null -ne $S.SugNext){$S.SugStack.Add([string]$S.SugNext)}
    elseif($Direction -lt 0 -and $S.SugStack.Count -gt 1){$S.SugStack.RemoveAt($S.SugStack.Count-1)} else {return}
    $after=$S.SugStack[$S.SugStack.Count-1]; if($after -eq ''){$after=$null}
    Add-SjcExplorerRequest $S 'QuerySuggestions' $S.TaskId @{AnalysisId=[string]$S.Analysis.Id;AfterId=$after;PageSize=64}
}

function Select-SjcExplorerSuggestionFiles($S,[string]$SuggestionId){
    if(-not $S.Analysis -or -not $S.Analysis.Id -or -not $S.SugIndex.ContainsKey($SuggestionId)){return}
    $S.SugFilesFor=$SuggestionId; $S.SugFiles=@(); $S.SugFilesNext=$null; $S.SugFilesStack.Clear(); $S.SugFilesStack.Add(''); $S.SugFilesDirty=$true
    Add-SjcExplorerRequest $S 'QuerySuggestionFiles' $S.TaskId @{AnalysisId=[string]$S.Analysis.Id;SuggestionId=$SuggestionId;AfterId=$null;PageSize=64}
}

function Move-SjcExplorerSuggestionFilesPage($S,[int]$Direction){
    if(-not $S.SugFilesFor -or -not $S.Analysis -or -not $S.Analysis.Id){return}
    if($Direction -gt 0 -and $null -ne $S.SugFilesNext){$S.SugFilesStack.Add([string]$S.SugFilesNext)}
    elseif($Direction -lt 0 -and $S.SugFilesStack.Count -gt 1){$S.SugFilesStack.RemoveAt($S.SugFilesStack.Count-1)} else {return}
    $after=$S.SugFilesStack[$S.SugFilesStack.Count-1]; if($after -eq ''){$after=$null}
    Add-SjcExplorerRequest $S 'QuerySuggestionFiles' $S.TaskId @{AnalysisId=[string]$S.Analysis.Id;SuggestionId=[string]$S.SugFilesFor;AfterId=$after;PageSize=64}
}

function Test-SjcExplorerSuggestionSelectable($Item){
    if(-not $Item){return $false}
    if($Item['HardProtected'] -eq $true -or $Item['MayPrepareForReview'] -ne $true){return $false}
    if([string]$Item['Classification'] -in 'Unknown','UserData','Mixed','Portable','SpaceOnly'){return $false}
    if([int]$Item['CandidateCount'] -lt 1){return $false}
    return $true
}

function Set-SjcExplorerSuggestionSelected($S,[string]$SuggestionId,[bool]$On){
    if(-not $S.SugIndex.ContainsKey($SuggestionId)){return $false}
    if($S.Draft -or ($S.Exec -and -not $S.Exec.Terminal)){return $false}   # 已生成复核清单后选择集冻结，需「返回修改」
    if($On){
        if(-not (Test-SjcExplorerSuggestionSelectable $S.SugIndex[$SuggestionId])){return $false}
        if($S.Selected.Count -ge 128 -and -not $S.Selected.ContainsKey($SuggestionId)){return $false}
        $S.Selected[$SuggestionId]=$true
    } else { [void]$S.Selected.Remove($SuggestionId) }
    $S.ApprovalDirty=$true
    return $true
}

function Request-SjcExplorerPrepare($S){
    if(-not (Test-SjcExplorerHasOp $S 'PrepareApproval')){return $false}
    if(-not $S.Analysis -or -not $S.Analysis.Ready -or $S.Draft -or ($S.Exec -and -not $S.Exec.Terminal) -or $S.Selected.Count -lt 1){return $false}
    $ids=@($S.Selected.Keys | Where-Object {$S.SugIndex.ContainsKey($_) -and (Test-SjcExplorerSuggestionSelectable $S.SugIndex[$_])} | Sort-Object)
    if($ids.Count -lt 1){return $false}
    Step-SjcExplorerGen $S 'Draft'
    $prepareOp=if(Test-SjcExplorerHasOp $S 'BeginPrepareApproval'){'BeginPrepareApproval'}else{'PrepareApproval'}
    Add-SjcExplorerRequest $S $prepareOp $S.TaskId @{AnalysisId=[string]$S.Analysis.Id;SuggestionIds=[string[]]$ids;ExpectedEvidenceRevision=[long]$S.Analysis.Revision}
    $S.Draft=@{Pending=$true;TaskId=[string]$S.TaskId;DraftId=$null;DisplayHash=$null;DisplayedHash=$null;CandidateSetHash=$null;LogicalBytes=0;ItemCount=0;RecycleEnabled=$false;ConfirmError=$null}; $S.ApprovalDirty=$true
    return $true
}

function Move-SjcExplorerDraftPage($S,[int]$Direction){
    if(-not $S.Draft -or -not $S.Draft.DraftId){return}
    if($Direction -gt 0 -and $null -ne $S.DraftNext){$S.DraftStack.Add([int]$S.DraftNext)}
    elseif($Direction -lt 0 -and $S.DraftStack.Count -gt 1){$S.DraftStack.RemoveAt($S.DraftStack.Count-1)} else {return}
    Add-SjcExplorerRequest $S 'QueryApprovalItems' $S.TaskId @{DraftId=[string]$S.Draft.DraftId;AfterId=[int]$S.DraftStack[$S.DraftStack.Count-1];PageSize=64}
}

function Undo-SjcExplorerDraft($S){
    # 「返回修改」：丢弃界面上的草稿与批准；已经 Confirm 的批准在 Host 中仍是一次性封印，但界面不再提供执行入口。
    if($S.Exec -and -not $S.Exec.Terminal){return}
    $d=$S.Draft
    if($d -and $d['Pending'] -eq $true -and $d['PreparationId']){
        $origTask=if($d['TaskId']){[string]$d['TaskId']}else{[string]$S.TaskId}
        Start-SjcExplorerAbandonedCancel $S $origTask ([string]$d['PreparationId'])
    }
    foreach($stalePrep in @($S.Queue | Where-Object {$_.Op -in 'BeginPrepareApproval','PrepareApproval','GetPreparationProgress' -and $_['AbandonedDrain'] -ne $true})){[void]$S.Queue.Remove($stalePrep)}
    $S.Draft=$null; $S.DraftItems=@(); $S.DraftNext=$null; $S.DraftStack.Clear(); $S.DraftStack.Add(0); $S.Approval=$null; $S.Exec=$null; $S.DraftDirty=$true; $S.ApprovalDirty=$true
    Step-SjcExplorerGen $S 'Draft'
}

function Confirm-SjcExplorerApproval($S,[bool]$UserConfirmed){
    if(-not $UserConfirmed){return $false}
    $d=$S.Draft
    if(-not (Test-SjcExplorerHasOp $S 'ConfirmApproval') -or -not $d -or -not $d.DraftId -or -not $d.DisplayedHash -or $d.DisplayedHash -ne $d.DisplayHash -or $S.Approval){return $false}
    Add-SjcExplorerRequest $S 'ConfirmApproval' $S.TaskId @{DraftId=[string]$d.DraftId;DisplayHash=[string]$d.DisplayedHash}
    return $true
}

function Test-SjcExplorerCanExecute($S){
    $a=$S.Approval
    return [bool]($a -and $a.ApprovalId -and $a.CanExecute -eq $true -and -not $S.Exec -and (Test-SjcExplorerHasOp $S 'ExecuteApproved'))
}

function Invoke-SjcExplorerExecute($S,[bool]$UserConfirmed){
    if(-not $UserConfirmed -or -not (Test-SjcExplorerCanExecute $S)){return $false}
    $S.Bridge.ArmExecution([string]$S.Approval.ApprovalId)
    Add-SjcExplorerRequest $S 'ExecuteApproved' $S.TaskId @{ApprovalId=[string]$S.Approval.ApprovalId}
    $S.Exec=@{ApprovalId=[string]$S.Approval.ApprovalId;ExecutionId=$null;Status='Requested';Entries=[Collections.Generic.List[object]]::new();Next=$null;Terminal=$false;Rejected=$false;ErrorCode=$null;RecycledBytes=0;Tick=[Environment]::TickCount}
    $S.ApprovalDirty=$true
    return $true
}

function Stop-SjcExplorerExecution($S){
    if($S.Exec -and -not $S.Exec.Terminal -and $S.Approval -and (Test-SjcExplorerHasOp $S 'CancelExecution')){
        Add-SjcExplorerRequest $S 'CancelExecution' $S.TaskId @{ApprovalId=[string]$S.Approval.ApprovalId}
    }
}

function Request-SjcExplorerTaskList($S,[int]$Direction=0){
    if(-not (Test-SjcExplorerHasOp $S 'ListTasks')){return}
    if($Direction -gt 0 -and $null -ne $S.TaskListNext){$S.TaskListStack.Add([string]$S.TaskListNext)}
    elseif($Direction -lt 0){ if($S.TaskListStack.Count -gt 1){$S.TaskListStack.RemoveAt($S.TaskListStack.Count-1)} else {return} }
    elseif($Direction -eq 0){ $S.TaskListStack.Clear(); $S.TaskListStack.Add('') }
    $after=$S.TaskListStack[$S.TaskListStack.Count-1]; if($after -eq ''){$after=$null}
    $payload=@{AfterTaskId=$after;PageSize=64};if(Test-SjcExplorerHasOp $S 'GetStorageInfo'){$payload['PathFilter']=[string]$S['HistoryFilter']}
    Add-SjcExplorerRequest $S 'ListTasks' $null $payload
}

function Restore-SjcExplorerTask($S,[string]$TaskId){
    if(Test-SjcExplorerBatchActive $S){return $false}
    if(Test-SjcExplorerTaskCommandPending $S){return $false}
    if(($S['InFlight'] -and $S.InFlight.Op -eq 'CreateInventory') -or @($S.Queue | Where-Object {$_.Op -eq 'CreateInventory'}).Count){return $false}
    if($S.Analysis -and -not $S.Analysis.Terminal){return $false}
    if($S.Exec -and -not $S.Exec.Terminal){return $false}   # 执行进行中不得切换任务覆盖执行状态
    if(-not (Test-SjcExplorerHasOp $S 'GetProgress') -or $S.Fault -or ($S.State -eq 'Inventory' -and $S.TaskId -ne $TaskId)){return $false}
    $items=@($S.TaskList | Where-Object {[string]$_['TaskId'] -eq $TaskId}); if($items.Count -ne 1){return $false};$item=$items[0]
    if($S.Analysis -and $S.Analysis.Id -and $S.TaskId){ Add-SjcExplorerRequest $S 'InvalidateAnalysis' $S.TaskId @{AnalysisId=[string]$S.Analysis.Id} }
    Set-SjcExplorerCurrentTask $S $TaskId ([string]$item['State'])
    return $true
}

function Release-SjcExplorerTask($S,[string]$TaskId,[bool]$UserConfirmed){
    if(Test-SjcExplorerBatchActive $S){return $false}
    if($S.Analysis -and -not $S.Analysis.Terminal){return $false}
    if(-not $UserConfirmed -or -not (Test-SjcExplorerHasOp $S 'ReleaseTask')){return $false}
    $items=@($S.TaskList | Where-Object {[string]$_['TaskId'] -eq $TaskId})
    if($items.Count -ne 1){return $false};$item=$items[0]
    if([string]$item['State'] -notin 'Ready','Partial','Cancelled','Failed'){return $false}
    if($S.TaskId -eq $TaskId -and $S.Analysis -and $S.Analysis.Id){ Add-SjcExplorerRequest $S 'InvalidateAnalysis' $TaskId @{AnalysisId=[string]$S.Analysis.Id} }
    Add-SjcExplorerRequest $S 'ReleaseTask' $TaskId @{}
    return $true
}

function Receive-SjcExplorerFailure($S,$Req,[string]$Code){
    # 过期请求的失败不得改写当前任务/分析/草稿/执行状态；但若当前已放弃准备（原 TaskId + PreparationId 均匹配）的取消或终态轮询失败，必须报告取消未确认并撤回尚未发出的新准备，不得静默放行队列。
    if($Req.Op -eq 'CancelPreparation' -or $Req['AbandonedDrain'] -eq $true){
        $ab=$S['AbandonedPrep']
        Register-SjcExplorerStale $S $Req 'Failure' $Code
        if($ab -and $Req.Payload -and [string]$ab['TaskId'] -eq [string]$Req.TaskId -and [string]$ab['PreparationId'] -eq [string]$Req.Payload['PreparationId']){
            Complete-SjcExplorerAbandonedUnconfirmed $S
        }
        return
    }
    if(-not (Test-SjcExplorerReqOwned $S $Req)){ Register-SjcExplorerStale $S $Req 'Failure' $Code; return }
    $S.LastError=$Code; $S.ProgressDirty=$true; $S.ApprovalDirty=$true
    if($Req.Op -eq 'GetStorageInfo'){$S['StorageReadFailed']=$true;$S['Storage']=$null}
    if($Req.Op -eq 'GetSessionInfo'){$S['SessionReadFailed']=$true;$S['SessionInfo']=$null}
    switch($Req.Op){
        'Health'{$S.Fault='HealthFailed:'+$Code}
        'CreateInventory'{
            if($Req['BatchId'] -and $S['Batch'] -and $Req['BatchId'] -eq $S.Batch.Id){
                $b=$S.Batch;$entry=$b.Entries[[int]$Req['BatchIndex']];$entry.State='Failed';$entry.Reason=$Code;$b.Pending=$false;$b.NextTick=[Environment]::TickCount+100
                if($b.CancelRequested){$b.Status='Cancelled'}
                elseif($Code -in 'WorkerBusy','IndexQuotaExceededReleaseCompletedTask'){$b.Status='Stopped'}
                $S['BatchDirty']=$true
            }
            if($Code -eq 'IndexQuotaExceededReleaseCompletedTask'){
                $S['ShowQuotaHistory']=$true
                Request-SjcExplorerTaskList $S 0
            }
        }
        'CreateBatch'{
            if($S['Batch'] -and $Req['BatchId'] -eq $S.Batch.Id){
                $S.Batch['Creating']=$false;$S.Batch['ActiveIntent']=$false;$S.Batch.Pending=$false;$S.Batch.Status='Stopped';$S.Batch.Reason=$Code;$S['BatchDirty']=$true
            }
            if($Code -eq 'IndexQuotaExceededReleaseCompletedTask'){$S['ShowQuotaHistory']=$true;Request-SjcExplorerTaskList $S 0}
        }
        'GetBatch'{
            if($S['Batch'] -and [string]$Req.Payload['BatchId'] -eq [string]$S.Batch.Id){
                $S.Batch.Pending=$false;$S.Batch['ActiveIntent']=$false;$S.Batch['SyncNeeded']=$false
                if($S.Batch.Status -eq 'Loading'){$S.Batch.Status='Stopped'}
                $S['BatchDirty']=$true
            }
        }
        { $_ -in 'ContinueBatch','StartBatchEntry','PauseBatch','CancelBatch','StopBatch' }{
            $b=$S['Batch']
            if($b -and [string]$Req.Payload['BatchId'] -eq [string]$b.Id){
                $b.Pending=$false;$b['ActiveIntent']=$false;$b['SyncNeeded']=$false;$b.CancelRequested=$false;$b.Hold=($b.Status -eq 'Paused')
                if($Req.Op -eq 'StartBatchEntry' -and $null -ne $Req['BatchIndex'] -and [int]$Req['BatchIndex'] -lt $b.Entries.Count){
                    if($b.Entries[[int]$Req['BatchIndex']].State -eq 'Starting'){$b.Entries[[int]$Req['BatchIndex']].State='Pending'}
                }
                if($Code -eq 'IndexQuotaExceededReleaseCompletedTask'){
                    $b.Status='Stopped';$S['ShowQuotaHistory']=$true;Request-SjcExplorerTaskList $S 0
                }
                if(@($S.Queue | Where-Object {$_.Op -eq 'GetBatch' -and [string]$_.Payload['BatchId'] -eq [string]$b.Id}).Count -eq 0 -and -not $S.Closing){
                    Add-SjcExplorerRequest $S 'GetBatch' $null @{BatchId=[string]$b.Id}
                    $S.Queue[$S.Queue.Count-1]['PassiveView']=$true;$S.Queue[$S.Queue.Count-1]['BatchId']=$b.Id
                }
                $S['BatchDirty']=$true
            }
        }
        'Analyze'{ if($S.Analysis){$S.Analysis.Terminal=$true;$S.Analysis.Status='Failed';$S.Analysis.ErrorCode=$Code;$S.Analysis.Requested=$false} }
        'GetAnalysisProgress'{ if($S.Analysis){$S.Analysis.Terminal=$true;$S.Analysis.Status='Failed';$S.Analysis.ErrorCode=$Code;$S.Analysis.Ready=$false} }
        'QuerySpace'{$S.Space=@();$S.SpaceNext=$null;$S.SpaceDirty=$true}
        'QuerySuggestions'{Reset-SjcExplorerApproval $S}
        { $_ -in 'PrepareApproval','BeginPrepareApproval','GetPreparationProgress' }{ $S.Draft=$null }
        'ConfirmApproval'{ if($S.Draft){$S.Draft.ConfirmError=$Code} }
        'QueryApprovalItems'{ if($S.Draft){$S.Draft.ConfirmError=$Code} }
        'ExecuteApproved'{ $S.Exec=@{ApprovalId=$null;Status='NotExecuted';Entries=[Collections.Generic.List[object]]::new();Next=$null;Terminal=$true;Rejected=$true;ErrorCode=$Code;RecycledBytes=0} }
        'GetExecutionResult'{ if($S.Exec){$S.Exec.Terminal=$true;$S.Exec.Status='Unknown';$S.Exec.ErrorCode=$Code} }
    }
}

function Get-SjcExplorerLogicalText($Value){ if($null -eq $Value){return '未知'}; return (Format-SjcExplorerBytes $Value) }

function ConvertTo-SjcExplorerSuggestionRow($S,$Item){
    $id=[string]$Item['SuggestionId']
    $sel=Test-SjcExplorerSuggestionSelectable $Item
    $note=''
    if($Item.ContainsKey('ReasonCategory')){$note=Get-SjcExplorerReasonCategoryText ([string]$Item['ReasonCategory'])}
    elseif($Item['HardProtected'] -eq $true){$note='受保护，不可处理'}
    elseif($Item['MayPrepareForReview'] -ne $true){$note=Get-SjcExplorerBlockedText ([string]$Item['ApprovalBlockedReason'])}
    elseif(-not $sel){$note='仅展示，无可处理候选'}
    else{$note='可进入复核（默认未勾选）'}
    $target=[string]$Item['TargetPath']
    if(-not $target){$target=$S.Analysis.TargetPath; if(-not $target -or [string]$Item['TargetId'] -ne [string]$S.Analysis.TargetId){$target='对象 '+[string]$Item['TargetId']}}
    [pscustomobject]@{Id=$id;Checked=[bool]$S.Selected.ContainsKey($id);Selectable=[bool]$sel;Class=(Get-SjcExplorerClassText ([string]$Item['Classification']));Level=(Get-SjcExplorerLevelText ([string]$Item['Level']));Count=[string]$Item['CandidateCount'];Logical=(Get-SjcExplorerLogicalText $Item['LogicalBytes']);Target=$target;Note=$note}
}

function Get-SjcExplorerSuggestionDetail($Item){
    if(-not $Item){return ''}
    $lines=New-Object Collections.Generic.List[string]
    $lines.Add('影响：'+(Get-SjcExplorerImpactText ([string]$Item['Impact'])))
    $d=@($Item['Doubts'] | ForEach-Object {Get-SjcExplorerDoubtText ([string]$_)}); if($d.Count){$lines.Add('疑点：'+($d -join '；'))}else{$lines.Add('疑点：Host 未给出。')}
    $ev=@($Item['EvidenceIds'] | ForEach-Object {$m=Get-SjcExplorerEvidenceCodeText ([string]$_); if($m -ne ('未识别事实：'+[string]$_)){$m}else{[string]$_}})
    $lines.Add('依据（Host 证据编号或事实）：'+$(if($ev.Count){$ev -join '、'}else{'无'}))
    $dup=$Item['DuplicateSummary']; if($dup -is [Collections.IDictionary]){ $lines.Add(('重复文件：保留副本 {0} 个；保留选择是否已确认：{1}' -f $dup['RetainedCount'],$(if($dup['RetainedChoiceConfirmed'] -eq $true){'是'}else{'否'}))) }
    if($Item.ContainsKey('ReasonCode')){$lines.Add('原因：'+(Get-SjcExplorerReasonCategoryText ([string]$Item['ReasonCategory']))+'（'+[string]$Item['ReasonCode']+'）')}
    $lines.Add('说明：来自探索服务实际收集的元数据与有预算的格式证据；未知信息不作推测。')
    return ($lines -join "`n")
}

function Get-SjcExplorerExecutionText($S){
    $e=$S.Exec; if(-not $e){return ''}
    if($e.Rejected){ return ('未处理任何文件。原因：'+(Get-SjcExplorerErrorText $e.ErrorCode)) }
    $final=@{};foreach($entry in $e.Entries){$final[[string]$entry['ObjectId']]=$entry}
    $n=$final.Count; $rec=@($final.Values | Where-Object {[string]$_['Status'] -eq 'Recycled'}).Count
    $total=$(if($S.Draft){[int]$S.Draft.ItemCount}else{-1})
    switch($e.Status){
        'Requested'{ return '已发出处理请求，等待探索服务回应…' }
        'Queued'{ return '已排队，等待处理…' }
        'Running'{ return ('处理中：已记录 {0} 项…' -f $n) }
        'NotStarted'{ return '尚未开始处理（没有任何文件被移动）。' }
        'Completed'{
            if($total -ge 0 -and $rec -eq $total -and $n -eq $total){ return ('已完成：{0} 项均已移入回收站（逻辑大小 {1}）。回收站文件仍占用磁盘空间，清空回收站后才会释放。' -f $rec,(Format-SjcExplorerBytes $e.RecycledBytes)) }
            return ('探索服务报告「已完成」，但逐项记录（{0}/{1}，已回收 {2}）与清单不一致；请按「结果未知」处理，到回收站核对。' -f $n,$total,$rec)
        }
        'PartialOrInterrupted'{ return ('部分完成或被中断：已记录 {0} 项，其中 {1} 项移入回收站，其余未处理或结果未知；请查看逐项记录并到回收站核对。' -f $n,$rec) }
        default{ return ('结果未知（状态 '+$e.Status+'）：已记录 '+$n+' 项，其中 '+$rec+' 项移入回收站。请到回收站核对。') }
    }
}

function Update-SjcExplorerApprovalView($W,$S){
    $e=$W.Tag.Controls
    $hasGroup=($null -ne $S.ParentId)
    $canAn=(Test-SjcExplorerCanAnalyze $S)
    $e.AnalyzeButton.IsEnabled=$canAn
    $e.ToSuggestButton.IsEnabled=(Test-SjcExplorerCanAnalyze $S 'Scope')
    $e.ScopeAnalyzeButton.IsEnabled=(Test-SjcExplorerCanAnalyze $S 'Scope')
    $e.CancelAnalysisButton.IsEnabled=[bool]($S.Analysis -and $S.Analysis.Id -and -not $S.Analysis.Terminal -and -not $S.Analysis.CancelRequested -and (Test-SjcExplorerHasOp $S 'CancelAnalysis'))
    $e.EngineNote.Text='无模型启发式：按结构线索、空间收益和检查成本逐步调查；大小、名称与年龄仅影响检查顺序，不代表可删除。探索服务不加载或下载任何模型。'
    $tp=''; if($hasGroup){ $g=@($S.Groups | Where-Object {[string]$_['GroupId'] -eq [string]$S.ParentId}); if($g.Count){$tp=[string]$g[0]['Path']} }
    $e.TargetText.Text=$(if(-not $S.TaskId){'请先在「盘点」页选择范围并完成盘点。'}elseif($S.State -notin 'Ready','Partial'){'盘点尚未结束（'+(Get-SjcExplorerStateText $S.State)+'），结束后才能深入调查。'}elseif(-not $hasGroup){'可自动深入整个选定范围；也可在「盘点」页选一个目录单独分析。'}else{'所选目录：'+$tp+'；也可自动深入整个范围。'})
    $a=$S.Analysis
    if($a){
        $txt=Get-SjcExplorerAnalysisStatusText $a.Status
        $why=Get-SjcExplorerAnalysisReasonText ([string]$a.Reason); if($why){$txt+='（'+$why+'）'}
        $failed=[bool]($a.Status -eq 'Failed' -or [string]$a.Status -like 'AnalysisFailed:*' -or $a.ErrorCode)
        if($failed){
            $code=[string]$a.ErrorCode
            if(-not $code){$code=([string]$a.Reason).Split('|')[0]}
            if(-not $code -and [string]$a.Status -like 'AnalysisFailed:*'){$code=([string]$a.Status).Substring(15)}
            $e.AnalysisText.Text=('本次分析未完成，不能据此判断清理结果。'+(Get-SjcExplorerAnalysisFailureAction $code)+'错误详情可在问题报告中查看。')
            $e.AnalysisText.ToolTip=$(if($code){'错误代码：'+$code+'。'+(Get-SjcExplorerErrorText $code)}else{'错误代码：未提供'})
        } else { $e.AnalysisText.ToolTip=$null }
        if($a.ErrorCode -and -not $failed){$txt+='　'+(Get-SjcExplorerErrorText ([string]$a.ErrorCode))}
        $p=$a.Progress;if($p -is [Collections.IDictionary]){$txt+=('　目标 {0}　队列 {1}　检查 {2}' -f $p['VisitedTargets'],$p['QueuedTargets'],$p['CompletedActions']);if(-not $a.Terminal -and $p['Reason']){$txt+='　'+(Get-SjcExplorerAnalysisReasonText ([string]$p['Reason']))}}
        if($a.CancelRequested -and -not $a.Terminal){$txt+='　正在取消…'}
        $u=$a.Usage; if($u -is [Collections.IDictionary] -and -not $failed){ $txt+=('　已读元数据对象 {0}，读取文件 {1}，哈希文件 {2}' -f $u['MetadataObjects'],$u['ReadFiles'],$u['HashFiles']) }
        if(-not $failed -and $a.ContainsKey('Timing') -and $a.Timing -is [Collections.IDictionary]){
            $t=$a.Timing; $txt+=('　快照 {0:N1}s／分析 {1:N1}s／证明与展示 {2:N1}s' -f ([double]$t['SnapshotMilliseconds']/1000),([double]$t['AnalysisMilliseconds']/1000),([double]$t['ProofAndDisplayMilliseconds']/1000))
        }
        if($a.ContainsKey('Outcome') -and $a.Outcome -is [Collections.IDictionary]){
            $o=$a.Outcome; $txt+=('　可复核 {0} 组（逻辑 {1}），仅展示 {2} 组，覆盖不完整对象 {3}' -f $o['ReviewGroups'],(Format-SjcExplorerBytes $o['ReviewLogicalBytes']),$o['DisplayOnlyGroups'],$o['IncompleteObjects'])
            if($o.ContainsKey('ReasonCounts') -and $o['ReasonCounts'] -is [Collections.IDictionary]){$parts=@();foreach($key in $o['ReasonCounts'].Keys){$parts+=((Get-SjcExplorerReasonCategoryText ([string]$key))+' '+[string]$o['ReasonCounts'][$key])};if($parts.Count){$txt+="`n原因分布："+($parts -join '；')}}
        }
        if(-not $failed){$e.AnalysisText.Text=$txt}
    } else { $e.AnalysisText.Text='尚未分析。';$e.AnalysisText.ToolTip=$null }
    if($S.SugDirty){
        $S.SugDirty=$false
        $S.RenderingSuggestions=$true
        try{$e.SuggestionsList.ItemsSource=@($S.Suggestions | ForEach-Object {ConvertTo-SjcExplorerSuggestionRow $S $_})}finally{$S.RenderingSuggestions=$false}
        $e.SugPageText.Text=$(if($S.Analysis -and $S.Analysis.Ready){('第 {0} 页，本页 {1} 项{2}' -f $S.SugStack.Count,$S.Suggestions.Count,$(if($S.Suggestions.Count -eq 0){$(if($S['NoResultReason'] -eq 'InvestigationBudgetExceeded'){'：本轮调查预算用尽，尚无可展示结果；可缩小范围重试'}else{'：未找到当前支持的布局证据，不代表没有占用或全都可安全删除'})}else{''}))}else{''})
        $e.SugPrev.IsEnabled=($S.SugStack.Count -gt 1); $e.SugNext.IsEnabled=($null -ne $S.SugNext)
    }
    if($S.SugFilesDirty){
        $S.SugFilesDirty=$false
        $e.SugFilesList.ItemsSource=@($S.SugFiles | ForEach-Object {[pscustomobject]@{Path=[string]$_['Path'];Logical=(Get-SjcExplorerLogicalText $_['LogicalBytes'])}})
        $e.SugFilesPageText.Text=$(if($S.SugFilesFor){('第 {0} 页，本页 {1} 个文件' -f $S.SugFilesStack.Count,$S.SugFiles.Count)}else{''})
        $e.SugFilesPrev.IsEnabled=($S.SugFilesStack.Count -gt 1); $e.SugFilesNext.IsEnabled=($null -ne $S.SugFilesNext)
    }
    $count=0; $bytes=[long]0
    foreach($k in $S.Selected.Keys){ if($S.SugIndex.ContainsKey($k)){ $count++; $bytes+=[long]$S.SugIndex[$k]['LogicalBytes'] } }
    $e.SelectionText.Text=$(if($count -eq 0){'尚未勾选任何建议（默认全部不勾选）。'}else{('已勾选 {0} 项建议，约 {1}（逻辑大小，来自文件元数据）。' -f $count,(Format-SjcExplorerBytes $bytes))})
    $prepDraining=[bool]($S['AbandonedPrep'] -or ($S['Queue'] -and @($S.Queue | Where-Object {$_.Op -in 'PrepareApproval','BeginPrepareApproval','CancelPreparation' -or $_['AbandonedDrain'] -eq $true}).Count -gt 0))
    $e.PrepareButton.IsEnabled=[bool]($count -gt 0 -and -not $S.Draft -and -not $prepDraining -and $S.Analysis -and $S.Analysis.Ready -and (Test-SjcExplorerHasOp $S 'PrepareApproval') -and -not $S.InFlight)
    # 复核浮层
    $d=$S.Draft
    $e.ApprovalOverlay.Visibility=$(if($d){'Visible'}else{'Collapsed'})
    if($d){
        $recAvail=(Test-SjcExplorerHostCap $S 'RecycleAvailable')
        if($d.Pending -or -not $d.DraftId){
            $e.DraftSummary.Text='正在后台准备复核清单，尚未批准或处理文件。可返回取消。'
            if($d['PrepareProgress']){
                $pr=$d['PrepareProgress']
                if([long]$pr['TotalFiles'] -gt 0){$e.DraftSummary.Text+=(' 已核查 {0}/{1} 个文件，用时 {2:N1} 秒。' -f $pr['CheckedFiles'],$pr['TotalFiles'],([double]$pr['ElapsedMilliseconds']/1000))}
                else{$e.DraftSummary.Text+=(' 正在整理所选项目，用时 {0:N1} 秒。' -f ([double]$pr['ElapsedMilliseconds']/1000))}
            }
        }
        else{
            $sum=('将处理 {0} 个文件，逻辑大小合计 {1}。方式：只移入回收站（不永久删除）。移入回收站不会立即释放磁盘空间，清空回收站后才会释放。' -f $d.ItemCount,(Format-SjcExplorerBytes $d.LogicalBytes))
            $sum+="`n清单指纹："+$d.DisplayHash.Substring(0,16)+'…（确认时绑定该指纹，清单变化会被拒绝）。检查优先级不参与批准。'
            $sum+="`n哪些文件实际无法回收，探索服务不会预判；处理时逐项记录，失败或结果未知的项目会如实显示。"
            if(-not $recAvail){ $sum+="`n阶段状态：回收站处理在当前探索服务中不可用，只能到「确认此清单」，不能执行。" }
            elseif($d.RecycleEnabled -ne $true -and -not $S.Approval){ $sum+="`n阶段状态：回收站处理需在确认后由探索服务给出是否可执行。" }
            if($d.ConfirmError){ $sum+="`n错误："+(Get-SjcExplorerErrorText ([string]$d.ConfirmError)) }
            if($S.Approval){ $sum+=$(if($S.Approval.CanExecute){"`n已确认。可执行：是（仍需你点击「第二步」并再次确认）。"}else{"`n已确认，但探索服务声明当前不可执行：不会处理任何文件。"}) }
            $e.DraftSummary.Text=$sum
        }
        if($S.DraftDirty){
            $S.DraftDirty=$false
            $e.DraftList.ItemsSource=@($S.DraftItems | ForEach-Object {
                $f=$_['File']; $anc=@($_['Ancestors']).Count; $ret=@($_['RetainedCopies']).Count
                [pscustomobject]@{Path=[string]$f['Path'];Size=(Format-SjcExplorerBytes $f['Size']);Modified=[string]$f['ModifiedUtc'];Tip=("上级目录 {0} 层；保留副本 {1} 个" -f $anc,$ret)}
            })
            $e.DraftPageText.Text=('第 {0} 页，本页 {1} 项' -f $S.DraftStack.Count,$S.DraftItems.Count)
            $e.DraftPrev.IsEnabled=($S.DraftStack.Count -gt 1 -and -not $S.InFlight); $e.DraftNext.IsEnabled=($null -ne $S.DraftNext)
        }
        $execRunning=($S.Exec -and -not $S.Exec.Terminal)
        $e.ConfirmButton.IsEnabled=[bool]($d.DraftId -and $d.DisplayedHash -and $d.DisplayedHash -eq $d.DisplayHash -and -not $d.ConfirmError -and -not $S.Approval -and -not $S.Exec -and -not $S.InFlight -and (Test-SjcExplorerHasOp $S 'ConfirmApproval'))
        $e.ExecuteButton.IsEnabled=[bool](Test-SjcExplorerCanExecute $S)
        $e.BackButton.IsEnabled=(-not $execRunning)
        $e.StopExecButton.IsEnabled=[bool]($execRunning -and $S.Approval)
        $e.ResultText.Text=(Get-SjcExplorerExecutionText $S)
    }
    # 历史任务
    if($S.TaskListDirty){
        $S.TaskListDirty=$false
        $e.TaskList.ItemsSource=@($S.TaskList | ForEach-Object {[pscustomobject]@{Id=[string]$_['TaskId'];Short=([string]$_['TaskId']).Substring(0,8)+'…';Root=$(if($_.ContainsKey('RootPath')){[string]$_['RootPath']}else{'旧接口未记录'});Mode=$(if($_.ContainsKey('ScanMode')){switch([string]$_['ScanMode']){'Selected'{'所选范围'} 'AllFixedDisks'{'全盘批次'} default{'旧记录未记录'}}}else{'未记录'});Observed=$(if($_.ContainsKey('ObservedObjects')){[string]$_['ObservedObjects']}else{'未知'});Skipped=$(if($_.ContainsKey('SkippedObjects')){[string]$_['SkippedObjects']}else{'未知'});Logical=$(if($_.ContainsKey('ObservedLogicalBytes')){Format-SjcExplorerBytes $_['ObservedLogicalBytes']}else{'未知'});State=(Get-SjcExplorerStateText ([string]$_['State']));RawState=[string]$_['State'];Revision=[string]$_['EvidenceRevision'];Created=[string]$_['CreatedUtc'];Updated=[string]$_['UpdatedUtc']}})
        $e.TaskPageText.Text=$(if($S.TaskListLoaded){('第 {0} 页，本页 {1} 个任务' -f $S.TaskListStack.Count,$S.TaskList.Count)}else{''})
        $e.TaskPrev.IsEnabled=($S.TaskListStack.Count -gt 1); $e.TaskNext.IsEnabled=($null -ne $S.TaskListNext)
    }
    $canList=(Test-SjcExplorerCanListTasks $S)
    $e.TaskRefresh.IsEnabled=$canList
    $sel=$e.TaskList.SelectedItem
    $analysisRunning=[bool]($S.Analysis -and -not $S.Analysis.Terminal)
    $e.TaskRestore.IsEnabled=[bool](-not (Test-SjcExplorerBatchActive $S) -and $canList -and $sel -and $S.State -ne 'Inventory' -and -not $analysisRunning -and -not ($S.Exec -and -not $S.Exec.Terminal) -and -not (Test-SjcExplorerTaskCommandPending $S) -and -not ($S.InFlight -and $S.InFlight.Op -eq 'CreateInventory') -and @($S.Queue | Where-Object {$_.Op -eq 'CreateInventory'}).Count -eq 0)
    $e.TaskRelease.IsEnabled=[bool](-not (Test-SjcExplorerBatchActive $S) -and $canList -and $sel -and (Test-SjcExplorerHasOp $S 'ReleaseTask') -and $sel.RawState -in 'Ready','Partial','Cancelled','Failed' -and -not $analysisRunning -and -not ($S.Exec -and -not $S.Exec.Terminal))
    $e.HistoryNote.Text=$(if($S.LastError -eq 'IndexQuotaExceededReleaseCompletedTask'){Get-SjcExplorerQuotaText $S}elseif($canList){('本页 {0} 条扫描记录，历史条数不限制，仍受索引空间配额保护。释放只移除扫描记录，不删除磁盘文件；暂停中的任务请先恢复或取消。' -f $S.TaskList.Count)}else{'当前探索服务未声明历史任务功能。'})
    if($e.ContainsKey('BatchHistorySection')){
        $canPersistBatch=(Test-SjcExplorerCanPersistBatch $S)
        $e.BatchHistorySection.Visibility=$(if($canPersistBatch){'Visible'}else{'Collapsed'})
        if($canPersistBatch){
            if($S['BatchListDirty']){
                $S['BatchListDirty']=$false
                $e.BatchHistoryList.ItemsSource=@($S['BatchList'] | ForEach-Object {[pscustomobject]@{Id=[string]$_['BatchId'];Short=([string]$_['BatchId']).Substring(0,8)+'…';State=(Get-SjcExplorerStateText ([string]$_['State']));RawState=[string]$_['State'];EntryCount=[string]$_['EntryCount'];Revision=[string]$_['Revision'];Reason=[string]$_['Reason'];Created=[string]$_['CreatedUtc'];Updated=[string]$_['UpdatedUtc']}})
                $blStack=$S['BatchListStack'];$pageNum=$(if($blStack -and $blStack.Count -ge 1){$blStack.Count}else{1})
                $e.BatchHistoryPageText.Text=$(if($S['BatchListLoaded']){('第 {0} 页，本页 {1} 个批次' -f $pageNum,@($S['BatchList']).Count)}else{''})
                $e.BatchHistoryPrev.IsEnabled=[bool]($blStack -and $blStack.Count -gt 1)
                $e.BatchHistoryNext.IsEnabled=($null -ne $S['BatchListNext'])
            }
            $e.BatchHistoryRefresh.IsEnabled=(-not $S.Fault -and -not $S.Closing)
            $selBatch=$e.BatchHistoryList.SelectedItem
            $e.BatchHistoryView.IsEnabled=[bool](-not (Test-SjcExplorerBatchActive $S) -and $selBatch -and $S.State -ne 'Inventory' -and -not $analysisRunning -and -not ($S.Exec -and -not $S.Exec.Terminal))
        }
    }
    if($e.ContainsKey('StorageText')){Update-SjcExplorerRecordView $W $S}
    if($e.ContainsKey('ExecutionDetails')){$e.ExecutionDetails.IsEnabled=[bool]($S.Exec -and $S.Exec.Entries.Count -gt 0)}
    $S.ApprovalDirty=$false
}

# ---- 窗口（样式沿用 Gui.ps1 的调色与按钮风格）----
$script:SjcExplorerXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="深度探索：盘点、建议与回收站复核" Width="1040" Height="720" MinWidth="820" MinHeight="560" WindowStartupLocation="CenterOwner" Background="#F3F6FB" FontFamily="Microsoft YaHei UI" FontSize="13" Foreground="#16213A" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
 <Window.Resources>
  <SolidColorBrush x:Key="Line" Color="#E6EBF3"/>
  <Style x:Key="Muted" TargetType="TextBlock"><Setter Property="Foreground" Value="#6B7890"/><Setter Property="FontSize" Value="12"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
  <Style x:Key="Cell" TargetType="TextBlock"><Setter Property="TextWrapping" Value="NoWrap"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style TargetType="Button"><Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#3D4A63"/><Setter Property="BorderBrush" Value="#D5DEEB"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="12,6"/><Setter Property="MinHeight" Value="32"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/></Border><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="#2F6BFF"/><Setter TargetName="Chrome" Property="BorderThickness" Value="2"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F4F7FC"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/><Setter Property="Cursor" Value="Arrow"/></Trigger></Style.Triggers></Style>
  <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Background" Value="#2F6BFF"/><Setter Property="BorderBrush" Value="#2F6BFF"/><Setter Property="Foreground" Value="White"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#245BE0"/></Trigger></Style.Triggers></Style>
  <Style TargetType="GridViewColumnHeader"><Setter Property="Background" Value="#F7F9FD"/><Setter Property="Foreground" Value="#6B7890"/><Setter Property="FontSize" Value="12"/><Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="Padding" Value="8,6"/></Style>
 </Window.Resources>
 <Grid Margin="16,12,16,12">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Border Grid.Row="0" Background="#EAF1FF" BorderBrush="#D6E3FF" BorderThickness="1" CornerRadius="8" Padding="12,7" Margin="0,0,0,10"><TextBlock x:Name="BannerText" Foreground="#1C3F9E" FontSize="12" TextWrapping="Wrap" Text="先盘点、再启发式探索：只调查你选定的范围，不加载模型。结构线索决定先检查什么，不代表可以删除；只有精确复核清单经两步明确确认后才尝试回收，不能回收就跳过。"/></Border>
  <TabControl x:Name="MainTabs" Grid.Row="1" Background="Transparent" BorderBrush="{StaticResource Line}">
   <TabItem x:Name="InventoryTab" Header="盘点" AutomationProperties.Name="盘点页">
    <Grid Margin="0,10,0,0">
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
     <Border Grid.Row="0" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
      <StackPanel>
       <DockPanel Margin="0,0,0,10">
        <RadioButton x:Name="ScopeFolderRadio" GroupName="SjcExplorerScope" Content="所选文件夹或磁盘" IsChecked="True" VerticalAlignment="Center" Margin="0,0,10,0" AutomationProperties.Name="范围：所选文件夹或磁盘"/>
        <Button x:Name="BrowseButton" DockPanel.Dock="Right" Margin="8,0,0,0" Content="选择文件夹…"/>
        <TextBox x:Name="FolderPathBox" MinHeight="30" VerticalContentAlignment="Center" AutomationProperties.Name="所选文件夹或磁盘路径"/>
       </DockPanel>
       <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
        <RadioButton x:Name="ScopeDiskRadio" GroupName="SjcExplorerScope" Content="全盘扫描" IsChecked="False" VerticalAlignment="Center" Margin="0,0,10,0" AutomationProperties.Name="范围：全盘扫描（可用固定磁盘）"/>
        <TextBlock Text="快速选盘（写入上方路径）" VerticalAlignment="Center" Margin="12,0,8,0"/>
        <ComboBox x:Name="DiskCombo" MinWidth="160" MinHeight="28" AutomationProperties.Name="固定磁盘列表"/>
       </StackPanel>
       <WrapPanel>
        <Button x:Name="StartButton" Style="{StaticResource PrimaryButton}" Content="开始探索" IsEnabled="False"/>
        <Button x:Name="PauseButton" Content="暂停" IsEnabled="False"/>
        <Button x:Name="ResumeButton" Content="继续" IsEnabled="False"/>
        <Button x:Name="CancelButton" Content="取消" IsEnabled="False"/>
        <Button x:Name="ToSuggestButton" Content="去“建议与处理”自动深入…" IsEnabled="False" ToolTip="盘点完成后可自动深入整个选定范围，也可先选择一个目录单独分析。"/>
       </WrapPanel>
       <StackPanel x:Name="BatchPanel" Visibility="Collapsed" Margin="0,8,0,0">
        <TextBlock x:Name="BatchText" Style="{StaticResource Muted}"/>
        <DockPanel Margin="0,6,0,0"><Button x:Name="BatchContinueButton" DockPanel.Dock="Right" Margin="8,0,0,0" Content="继续剩余扫描…" Visibility="Collapsed" IsEnabled="False"/><Button x:Name="BatchOpenButton" DockPanel.Dock="Right" Margin="8,0,0,0" Content="查看所选盘结果" IsEnabled="False"/><ComboBox x:Name="BatchList" MinHeight="28" DisplayMemberPath="Text" AutomationProperties.Name="各盘扫描结果"/></DockPanel>
       </StackPanel>
      </StackPanel>
     </Border>
     <Border Grid.Row="1" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="12,8" Margin="0,0,0,10">
      <StackPanel>
       <DockPanel Margin="0,0,0,6"><TextBlock x:Name="StateText" DockPanel.Dock="Left" FontWeight="SemiBold" Text="正在连接探索服务…"/><TextBlock x:Name="CoverageText" Style="{StaticResource Muted}" HorizontalAlignment="Right" TextAlignment="Right"/></DockPanel>
       <ProgressBar x:Name="ExplorerProgress" Height="6" IsIndeterminate="False" Minimum="0" Maximum="1" Value="0" AutomationProperties.Name="探索进度"/>
       <TextBlock x:Name="ProgressDetailText" Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,0"/>
       <TextBlock x:Name="ProgressNote" Style="{StaticResource Muted}" Margin="0,4,0,0" Text="总量未知，进度只显示已观察数量，不代表百分比。"/>
       <TextBlock x:Name="CoverageExplanation" Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,0" Visibility="Collapsed" AutomationProperties.Name="未覆盖原因说明"/>
      </StackPanel>
     </Border>
     <Grid Grid.Row="2">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid Grid.Column="0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
       <TextBlock Text="目录分组（直接子项）" FontWeight="SemiBold" Margin="0,0,0,4"/>
       <ListView x:Name="GroupsList" Grid.Row="1" SelectionMode="Single" BorderBrush="{StaticResource Line}" AutomationProperties.Name="目录分组列表"><ListView.View><GridView>
        <GridViewColumn Header="路径" Width="260"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Style="{StaticResource Cell}" Text="{Binding Path}" ToolTip="{Binding Path}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="覆盖" DisplayMemberBinding="{Binding Coverage}" Width="80"/>
        <GridViewColumn Header="子项" DisplayMemberBinding="{Binding Children}" Width="60"/>
        <GridViewColumn Header="逻辑大小" DisplayMemberBinding="{Binding Logical}" Width="90"/>
        <GridViewColumn Header="保护" DisplayMemberBinding="{Binding Protection}" Width="90"/>
       </GridView></ListView.View></ListView>
       <DockPanel Grid.Row="2" Margin="0,6,0,0"><Button x:Name="GroupsPrev" Content="上一页" IsEnabled="False"/><Button x:Name="GroupsNext" Content="下一页" IsEnabled="False"/><TextBlock x:Name="GroupsPageText" Style="{StaticResource Muted}" VerticalAlignment="Center"/></DockPanel>
      </Grid>
      <Grid Grid.Column="2"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="110"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
       <TextBlock Text="证据明细（所选分组的直接子项）" FontWeight="SemiBold" Margin="0,0,0,4"/>
       <ListView x:Name="EvidenceList" Grid.Row="1" SelectionMode="Single" BorderBrush="{StaticResource Line}" AutomationProperties.Name="证据明细列表"><ListView.View><GridView>
        <GridViewColumn Header="路径" Width="230"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Style="{StaticResource Cell}" Text="{Binding Path}" ToolTip="{Binding Path}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="类型" DisplayMemberBinding="{Binding Kind}" Width="70"/>
        <GridViewColumn Header="逻辑大小" DisplayMemberBinding="{Binding Logical}" Width="90"/>
        <GridViewColumn Header="占用" DisplayMemberBinding="{Binding Allocated}" Width="90"/>
       </GridView></ListView.View></ListView>
       <TextBox x:Name="DetailText" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Margin="0,6,0,0" AutomationProperties.Name="证据详情"/>
       <DockPanel Grid.Row="3" Margin="0,6,0,0"><Button x:Name="EvPrev" Content="上一页" IsEnabled="False"/><Button x:Name="EvNext" Content="下一页" IsEnabled="False"/><TextBlock x:Name="EvPageText" Style="{StaticResource Muted}" VerticalAlignment="Center"/></DockPanel>
      </Grid>
     </Grid>
    </Grid>
   </TabItem>
   <TabItem x:Name="SuggestTab" Header="建议与处理" AutomationProperties.Name="建议与处理页">
    <Grid Margin="0,10,0,0">
     <Grid>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="150"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Border Grid.Row="0" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="12,8" Margin="0,0,0,8">
       <StackPanel>
        <TextBlock x:Name="TargetText" TextWrapping="Wrap" Margin="0,0,0,6" Text="请先完成盘点，再自动深入整个选定范围或只分析所选目录。"/>
        <WrapPanel>
         <Button x:Name="ScopeAnalyzeButton" Style="{StaticResource PrimaryButton}" Content="自动深入整个范围" IsEnabled="False" AutomationProperties.Name="自动深入整个选定范围"/>
         <Button x:Name="AnalyzeButton" Content="只分析所选目录" IsEnabled="False"/>
         <Button x:Name="CancelAnalysisButton" Content="停止深入" IsEnabled="False"/>
        </WrapPanel>
        <TextBlock x:Name="EngineNote" Style="{StaticResource Muted}" Margin="0,4,0,0" Text="无模型启发式：先检查便宜而有价值的线索，再按预算继续调查；线索不等于可删除。"/>
        <TextBlock x:Name="AnalysisText" FontWeight="SemiBold" Margin="0,6,0,0" Text="尚未分析。"/>
       </StackPanel>
      </Border>
      <Grid Grid.Row="1">
       <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
       <TextBlock Text="建议（默认全部不勾选；受保护或未确定的项不能勾选）" FontWeight="SemiBold" Margin="0,0,0,4"/>
       <ListView x:Name="SuggestionsList" Grid.Row="1" SelectionMode="Single" BorderBrush="{StaticResource Line}" AutomationProperties.Name="建议列表"><ListView.View><GridView>
        <GridViewColumn Header="选择" Width="52"><GridViewColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Checked, Mode=OneWay}" IsEnabled="{Binding Selectable, Mode=OneWay}" Tag="{Binding Id}" AutomationProperties.Name="选择此建议用于复核"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="类别" DisplayMemberBinding="{Binding Class}" Width="90"/>
        <GridViewColumn Header="级别" DisplayMemberBinding="{Binding Level}" Width="120"/>
        <GridViewColumn Header="候选文件" DisplayMemberBinding="{Binding Count}" Width="70"/>
        <GridViewColumn Header="逻辑大小" DisplayMemberBinding="{Binding Logical}" Width="90"/>
        <GridViewColumn Header="目标" Width="250"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Style="{StaticResource Cell}" Text="{Binding Target}" ToolTip="{Binding Target}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="状态" Width="260"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Style="{StaticResource Cell}" Text="{Binding Note}" ToolTip="{Binding Note}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
       </GridView></ListView.View></ListView>
       <DockPanel Grid.Row="2" Margin="0,6,0,0"><Button x:Name="SugPrev" Content="上一页" IsEnabled="False"/><Button x:Name="SugNext" Content="下一页" IsEnabled="False"/><TextBlock x:Name="SugPageText" Style="{StaticResource Muted}" VerticalAlignment="Center"/></DockPanel>
      </Grid>
      <Grid Grid.Row="2" Margin="0,8,0,0">
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
       <TextBox x:Name="SugDetailText" Grid.Column="0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AutomationProperties.Name="建议说明"/>
       <Grid Grid.Column="2"><Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <ListView x:Name="SugFilesList" SelectionMode="Single" BorderBrush="{StaticResource Line}" AutomationProperties.Name="建议包含的文件"><ListView.View><GridView>
         <GridViewColumn Header="候选文件（点击建议后加载）" Width="330"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Style="{StaticResource Cell}" Text="{Binding Path}" ToolTip="{Binding Path}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
         <GridViewColumn Header="逻辑大小" DisplayMemberBinding="{Binding Logical}" Width="90"/>
        </GridView></ListView.View></ListView>
        <DockPanel Grid.Row="1" Margin="0,4,0,0"><Button x:Name="SugFilesPrev" Content="上一页" IsEnabled="False"/><Button x:Name="SugFilesNext" Content="下一页" IsEnabled="False"/><TextBlock x:Name="SugFilesPageText" Style="{StaticResource Muted}" VerticalAlignment="Center"/></DockPanel>
       </Grid>
      </Grid>
      <DockPanel Grid.Row="3" Margin="0,8,0,0">
       <Button x:Name="PrepareButton" DockPanel.Dock="Right" Style="{StaticResource PrimaryButton}" Margin="8,0,0,0" Content="生成复核清单…" IsEnabled="False"/>
       <TextBlock x:Name="SelectionText" Style="{StaticResource Muted}" VerticalAlignment="Center" Text="尚未勾选任何建议。"/>
      </DockPanel>
     </Grid>
     <Border x:Name="ApprovalOverlay" Background="#B016213A" Visibility="Collapsed">
      <Border Background="White" CornerRadius="10" Margin="16,8,16,8" Padding="14,10,14,10" BorderBrush="{StaticResource Line}" BorderThickness="1">
       <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*" MinHeight="96"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <TextBlock Text="复核清单（只回收，不永久删除）" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" MaxHeight="88" Margin="0,0,0,6" Focusable="False"><TextBlock x:Name="DraftSummary" TextWrapping="Wrap" Text="正在生成复核清单…"/></ScrollViewer>
        <ListView x:Name="DraftList" Grid.Row="2" SelectionMode="Single" BorderBrush="{StaticResource Line}" AutomationProperties.Name="复核清单逐项列表"><ListView.View><GridView>
         <GridViewColumn Header="将要移入回收站的文件（精确路径）" Width="450"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Style="{StaticResource Cell}" Text="{Binding Path}" ToolTip="{Binding Path}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
         <GridViewColumn Header="大小" DisplayMemberBinding="{Binding Size}" Width="85"/>
         <GridViewColumn Header="修改时间" DisplayMemberBinding="{Binding Modified}" Width="145"/>
        </GridView></ListView.View></ListView>
        <DockPanel Grid.Row="3" Margin="0,4,0,4"><Button x:Name="DraftPrev" Content="上一页" IsEnabled="False"/><Button x:Name="DraftNext" Content="下一页" IsEnabled="False"/><TextBlock x:Name="DraftPageText" Style="{StaticResource Muted}" VerticalAlignment="Center"/></DockPanel>
        <TextBox x:Name="ResultText" Grid.Row="4" MinHeight="28" MaxHeight="48" Padding="6,4" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AutomationProperties.Name="处理结果"/>
        <WrapPanel Grid.Row="5" Margin="0,6,0,0" HorizontalAlignment="Right">
         <Button x:Name="BackButton" Content="返回修改"/>
         <Button x:Name="ConfirmButton" Content="第一步：确认此清单" IsEnabled="False"/>
         <Button x:Name="ExecuteButton" Style="{StaticResource PrimaryButton}" Content="第二步：移入回收站…" IsEnabled="False"/>
         <Button x:Name="StopExecButton" Content="停止处理" IsEnabled="False"/><Button x:Name="ExecutionDetails" Content="查看逐项记录…" IsEnabled="False"/>
        </WrapPanel>
       </Grid>
      </Border>
     </Border>
    </Grid>
   </TabItem>
   <TabItem x:Name="SpaceTab" Header="空间排行" AutomationProperties.Name="空间排行页">
    <Grid Margin="0,10,0,0">
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
     <TextBlock Style="{StaticResource Muted}" Margin="0,0,0,8" Text="按递归已观察逻辑量排序；目录会相互包含，不能把各行相加。覆盖不足和占用未知不会当成零；大不代表垃圾，回收也不会立即释放空间。"/>
     <ListView x:Name="SpaceList" Grid.Row="1" SelectionMode="Single" BorderBrush="{StaticResource Line}" AutomationProperties.Name="递归空间排行列表"><ListView.View><GridView>
      <GridViewColumn Header="路径" Width="420"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Style="{StaticResource Cell}" Text="{Binding Path}" ToolTip="{Binding Path}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
      <GridViewColumn Header="类型" DisplayMemberBinding="{Binding Kind}" Width="70"/>
      <GridViewColumn Header="已观察逻辑量" DisplayMemberBinding="{Binding Logical}" Width="115"/>
      <GridViewColumn Header="占用" DisplayMemberBinding="{Binding Allocated}" Width="95"/>
      <GridViewColumn Header="覆盖" DisplayMemberBinding="{Binding Coverage}" Width="95"/>
      <GridViewColumn Header="占用未知项" DisplayMemberBinding="{Binding Unknown}" Width="90"/>
      <GridViewColumn Header="硬链接项" DisplayMemberBinding="{Binding HardLinks}" Width="80"/>
     </GridView></ListView.View></ListView>
     <DockPanel Grid.Row="2" Margin="0,8,0,0"><Button x:Name="SpacePrev" Content="上一页" IsEnabled="False"/><Button x:Name="SpaceNext" Content="下一页" IsEnabled="False"/><TextBlock x:Name="SpacePageText" Style="{StaticResource Muted}" VerticalAlignment="Center"/></DockPanel>
    </Grid>
   </TabItem>
   <TabItem x:Name="HistoryTab" Header="历史任务" AutomationProperties.Name="历史任务页">
    <Grid Margin="0,10,0,0">
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
     <StackPanel>
      <TextBlock x:Name="HistoryNote" Style="{StaticResource Muted}" Margin="0,0,0,6" Text="历史任务条数不限制，仍受索引空间配额保护。释放只移除扫描记录，不删除磁盘文件。"/>
      <DockPanel Margin="0,0,0,8"><Button x:Name="HistorySearch" DockPanel.Dock="Right" Content="按路径筛选"/><TextBox x:Name="HistoryFilter" MinHeight="30" VerticalContentAlignment="Center" ToolTip="输入路径片段后点击筛选；筛选仅影响显示，不扩大释放范围。"/></DockPanel>
     </StackPanel>
     <ListView x:Name="TaskList" Grid.Row="1" SelectionMode="Single" BorderBrush="{StaticResource Line}" AutomationProperties.Name="历史任务列表"><ListView.View><GridView>
      <GridViewColumn Header="扫描根路径" Width="320"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Root}" ToolTip="{Binding Root}" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
      <GridViewColumn Header="模式" DisplayMemberBinding="{Binding Mode}" Width="90"/><GridViewColumn Header="已观察" DisplayMemberBinding="{Binding Observed}" Width="75"/><GridViewColumn Header="跳过" DisplayMemberBinding="{Binding Skipped}" Width="65"/><GridViewColumn Header="逻辑量" DisplayMemberBinding="{Binding Logical}" Width="90"/>
      <GridViewColumn Header="任务" DisplayMemberBinding="{Binding Short}" Width="110"/>
      <GridViewColumn Header="状态" DisplayMemberBinding="{Binding State}" Width="100"/>
      <GridViewColumn Header="盘点版本" DisplayMemberBinding="{Binding Revision}" Width="80"/>
      <GridViewColumn Header="创建（UTC）" DisplayMemberBinding="{Binding Created}" Width="170"/>
      <GridViewColumn Header="更新（UTC）" DisplayMemberBinding="{Binding Updated}" Width="170"/>
     </GridView></ListView.View></ListView>
     <WrapPanel Grid.Row="2" Margin="0,6,0,0">
      <Button x:Name="TaskRefresh" Content="刷新" IsEnabled="False"/><Button x:Name="TaskPrev" Content="上一页" IsEnabled="False"/><Button x:Name="TaskNext" Content="下一页" IsEnabled="False"/>
      <Button x:Name="TaskRestore" Content="恢复所选任务" IsEnabled="False"/><Button x:Name="TaskRelease" Content="释放所选（已结束）任务…" IsEnabled="False"/>
      <TextBlock x:Name="TaskPageText" Style="{StaticResource Muted}" VerticalAlignment="Center"/><TextBlock x:Name="HistoryPathDetail" Style="{StaticResource Muted}" TextWrapping="Wrap" Width="900" Margin="0,8,0,0"/>
     </WrapPanel>
     <StackPanel x:Name="BatchHistorySection" Grid.Row="3" Visibility="Collapsed" Margin="0,10,0,0">
      <TextBlock Text="全盘批次历史（重开仅只读展示；需先「查看所选批次」并在盘点页明确确认后才继续剩余项）" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <ListView x:Name="BatchHistoryList" Height="130" SelectionMode="Single" BorderBrush="{StaticResource Line}" AutomationProperties.Name="全盘批次历史列表"><ListView.View><GridView>
       <GridViewColumn Header="批次" DisplayMemberBinding="{Binding Short}" Width="110"/>
       <GridViewColumn Header="状态" DisplayMemberBinding="{Binding State}" Width="110"/>
       <GridViewColumn Header="盘数" DisplayMemberBinding="{Binding EntryCount}" Width="65"/>
       <GridViewColumn Header="批次版本" DisplayMemberBinding="{Binding Revision}" Width="80"/>
       <GridViewColumn Header="原因" DisplayMemberBinding="{Binding Reason}" Width="180"/>
       <GridViewColumn Header="创建（UTC）" DisplayMemberBinding="{Binding Created}" Width="175"/>
       <GridViewColumn Header="更新（UTC）" DisplayMemberBinding="{Binding Updated}" Width="175"/>
      </GridView></ListView.View></ListView>
      <WrapPanel Margin="0,6,0,0">
       <Button x:Name="BatchHistoryRefresh" Content="刷新批次" IsEnabled="False"/>
       <Button x:Name="BatchHistoryPrev" Content="上一页" IsEnabled="False"/>
       <Button x:Name="BatchHistoryNext" Content="下一页" IsEnabled="False"/>
       <Button x:Name="BatchHistoryView" Content="查看所选批次（只读）" IsEnabled="False"/>
       <TextBlock x:Name="BatchHistoryPageText" Style="{StaticResource Muted}" VerticalAlignment="Center"/>
      </WrapPanel>
     </StackPanel>
    </Grid>
   </TabItem>
   <TabItem x:Name="ResourceTab" Header="记录与帮助" AutomationProperties.Name="记录与帮助页">
    <ScrollViewer VerticalScrollBarVisibility="Auto" Background="White"><StackPanel Margin="12">
      <TextBlock Text="本机扫描记录" FontSize="16" FontWeight="SemiBold"/>
      <TextBlock x:Name="StorageSummaryText" Text="尚未读取扫描记录占用。" TextWrapping="Wrap" Margin="0,10,0,4" AutomationProperties.Name="扫描记录占用摘要"/>
      <TextBlock x:Name="StorageMaintenanceText" Text="维护状态尚未读取。" TextWrapping="Wrap" Margin="0,0,0,8" AutomationProperties.Name="扫描记录维护状态"/>
      <TextBlock x:Name="StorageText" Visibility="Collapsed" Text="尚未读取扫描记录占用。" TextWrapping="Wrap"/>
     <WrapPanel><Button x:Name="StorageRefresh" Content="刷新记录状态" IsEnabled="False" AutomationProperties.Name="刷新扫描记录状态"/><Button x:Name="StorageCompact" Content="整理扫描记录占用…" IsEnabled="False" AutomationProperties.Name="整理扫描记录占用"/></WrapPanel>
       <TextBlock Text="这里只整理本程序的记录，不删除你的文件。备份也会占用空间，整理不保证释放磁盘空间。" Style="{StaticResource Muted}" Margin="0,10,0,24"/>
      <TextBlock x:Name="StorageNotice" TextWrapping="Wrap" FontWeight="SemiBold" Margin="0,0,0,18" AutomationProperties.Name="记录维护结果"/>
      <TextBlock Text="遇到问题？" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10"/>
     <Button x:Name="DiagnosticExport" Content="保存问题报告…" HorizontalAlignment="Left" AutomationProperties.Name="保存问题报告"/>
       <TextBlock Text="报告只保存到你选择的位置，不会自动上传，也不包含文件路径、正文或账号信息。" Style="{StaticResource Muted}" Margin="0,10,0,24"/>
      <Expander x:Name="StorageDetailsExpander" IsExpanded="False" AutomationProperties.Name="技术详情">
        <Expander.Header><TextBlock Text="高级维护与技术详情" FontWeight="SemiBold"/></Expander.Header>
        <StackPanel Margin="0,8,0,0">
         <TextBlock x:Name="StorageDetailText" Text="技术详情尚未读取。" TextWrapping="Wrap" AutomationProperties.Name="扫描记录技术详情"/>
         <TextBlock Text="本次会话的扫描记录空间预算（MiB，512–16384）。不限制文件数量；磁盘剩余不足时仍会停止。重开恢复512MiB默认值。" TextWrapping="Wrap" Margin="0,12,0,6"/>
         <WrapPanel><TextBox x:Name="StorageBudget" Text="512" Width="100" MinHeight="32" AutomationProperties.Name="本次会话记录预算MiB"/><Button x:Name="StorageBudgetApply" Content="应用记录空间预算…" Margin="8,0,0,0"/></WrapPanel>
         <TextBlock Text="分析记录维护" FontSize="14" FontWeight="SemiBold" Margin="0,18,0,6"/>
         <TextBlock x:Name="SessionSummaryText" Text="尚未读取已结束的分析状态。" TextWrapping="Wrap" Margin="0,0,0,8" AutomationProperties.Name="已结束分析状态"/>
         <TextBlock x:Name="SessionText" Visibility="Collapsed" Text="尚未读取分析与批准材料状态。" TextWrapping="Wrap"/>
         <WrapPanel><Button x:Name="SessionRelease" Content="重置已结束的分析…" IsEnabled="False" AutomationProperties.Name="重置已结束的分析"/><Button x:Name="DraftArchive" Content="整理未确认的复核材料…" IsEnabled="False" AutomationProperties.Name="整理未确认的复核材料"/></WrapPanel>
         <TextBlock Text="重置会让旧建议、复核清单和未执行批准失效，扫描记录及你的文件保留。已确认凭据、防重放记录和执行账本不会删除；整理未确认材料会保留可恢复副本。" Style="{StaticResource Muted}" Margin="0,10,0,8"/>
        <TextBlock x:Name="SessionDetailText" Text="分析与批准材料的技术详情尚未读取。" TextWrapping="Wrap" Margin="0,10,0,0" AutomationProperties.Name="分析与批准材料技术详情"/>
       </StackPanel>
      </Expander>
     </StackPanel></ScrollViewer>
    </TabItem>
  </TabControl>
  <TextBlock x:Name="StatusText" Grid.Row="2" Style="{StaticResource Muted}" Margin="0,8,0,0"/>
 </Grid>
</Window>
'@

function Get-SjcExplorerFixedDisks {
    @([IO.DriveInfo]::GetDrives() | Where-Object {$_.DriveType -eq 'Fixed' -and $_.IsReady} | ForEach-Object {$_.RootDirectory.FullName})
}

function ConvertTo-SjcExplorerRow($Item,[string]$Kind){
    $row=[ordered]@{Path=[string]$Item['Path'];Coverage=[string]$Item['Coverage'];Protection=[string]$Item['Protection'];Raw=$Item}
    if($Kind -eq 'Group'){$row.Id=$Item['GroupId'];$row.Children=[string]$Item['ObservedDirectChildren'];$row.Logical=Format-SjcExplorerBytes $Item['DirectLogicalBytes'];$row.Allocated=Format-SjcExplorerBytes $Item['DirectAllocatedBytes']}
    else{$row.Id=$Item['EvidenceId'];$row.Kind=[string]$Item['Kind'];$row.Logical=Format-SjcExplorerBytes $Item['LogicalBytes'];$row.Allocated=Format-SjcExplorerBytes $Item['AllocatedBytes']}
    [pscustomobject]$row
}

function Update-SjcExplorerWindow($W,$S){
    $e=$W.Tag.Controls
    if($S['ShowQuotaHistory']){$S['ShowQuotaHistory']=$false;$e.MainTabs.SelectedItem=$e.HistoryTab}
    # 进度/列表轮询不改变任务控制按钮；只有控制命令待回应时阻止重复点击。
    $busy=($S.State -eq 'Inventory'); $paused=($S.State -eq 'Paused'); $ready=($S.HostReady -and -not $S.Fault -and -not $S.Closing -and -not (Test-SjcExplorerTaskCommandPending $S))
    $batchActive=Test-SjcExplorerBatchActive $S
    $pb=$S['Batch']
    $persistedSessionPaused=($pb -and $pb['Persisted'] -eq $true -and $pb['SessionCreated'] -eq $true -and $pb.Status -eq 'Paused' -and $pb['CanContinue'] -eq $true -and -not $pb.Pending)
    $isBatchTask=($pb -and $pb['Persisted'] -eq $true -and $S.TaskId -and @($pb.Entries | Where-Object {$_.TaskId -and [string]$_.TaskId -eq [string]$S.TaskId}).Count -gt 0)
    $execRunning=[bool]($S.Exec -and -not $S.Exec.Terminal)
    $analysisRunning=[bool]($S.Analysis -and -not $S.Analysis.Terminal)
    $e.StartButton.IsEnabled=($S.HostReady -and $S.CanInventory -and -not $S.Fault -and -not $busy -and (-not $paused -or $isBatchTask) -and -not $persistedSessionPaused -and -not $execRunning -and -not $analysisRunning -and -not $batchActive -and -not ($S.InFlight -and $S.InFlight.Op -in 'CreateInventory','CreateBatch') -and @($S.Queue | Where-Object {$_.Op -in 'CreateInventory','CreateBatch'}).Count -eq 0 -and [bool]$W.Tag.Scope)
    $e.PauseButton.IsEnabled=($ready -and $busy -and -not $isBatchTask); $e.ResumeButton.IsEnabled=($ready -and $paused -and -not $isBatchTask); $e.CancelButton.IsEnabled=($ready -and ($busy -or ($paused -and -not $isBatchTask)))
    if($batchActive){
        if($pb -and $pb['Persisted'] -eq $true){
            $e.PauseButton.IsEnabled=($ready -and -not $pb.CancelRequested -and -not $pb['PauseAfterStart'] -and -not $pb['PauseAfterCreate'] -and ($pb['Creating'] -eq $true -or ($pb['ActiveIntent'] -eq $true -and $pb.Status -eq 'Running')))
            $e.ResumeButton.IsEnabled=$false
            $e.CancelButton.IsEnabled=($ready -and -not $pb.CancelRequested -and ($pb['Creating'] -eq $true -or $null -ne $pb['Revision']))
        }else{
            $e.PauseButton.IsEnabled=($ready -and -not $S.Batch.Hold -and -not $S.Batch.CancelRequested)
            $e.ResumeButton.IsEnabled=($ready -and $S.Batch.Hold -and -not $S.Batch.CancelRequested)
            $e.CancelButton.IsEnabled=($ready -and -not $S.Batch.CancelRequested)
        }
    }elseif($persistedSessionPaused){
        $e.PauseButton.IsEnabled=$false
        $e.ResumeButton.IsEnabled=($ready -and (Test-SjcExplorerCanContinueBatch $S))
        $e.CancelButton.IsEnabled=($ready -and $null -ne $pb['Revision'])
    }
    $e.ScopeFolderRadio.IsEnabled=(-not $batchActive -and -not $busy -and (-not $paused -or $isBatchTask))
    $e.ScopeDiskRadio.IsEnabled=$e.ScopeFolderRadio.IsEnabled
    $e.BrowseButton.IsEnabled=$e.ScopeFolderRadio.IsEnabled
    $e.DiskCombo.IsEnabled=$e.ScopeFolderRadio.IsEnabled
    $e.FolderPathBox.IsEnabled=($e.ScopeFolderRadio.IsEnabled -and $e.ScopeFolderRadio.IsChecked)
    if($e.ContainsKey('BatchPanel')){
        $e.BatchPanel.Visibility=$(if($S['Batch']){'Visible'}else{'Collapsed'})
        if($S['Batch']){
            $e.BatchText.Text=Get-SjcExplorerBatchText $S
            if($S['BatchDirty']){
                $S['BatchDirty']=$false;$selected=$e.BatchList.SelectedIndex
                $e.BatchList.ItemsSource=@($S.Batch.Entries | ForEach-Object {[pscustomobject]@{Text=($_.Root+' — '+(Get-SjcExplorerStateText $_.State)+$(if($_.Reason){'（'+$_.Reason+'）'}else{''}));TaskId=$_.TaskId;RawState=$_.State}})
                if($selected -ge 0 -and $selected -lt $e.BatchList.Items.Count){$e.BatchList.SelectedIndex=$selected}elseif($e.BatchList.Items.Count){$e.BatchList.SelectedIndex=0}
            }
            $e.BatchOpenButton.IsEnabled=(-not $batchActive -and -not $S.InFlight -and $S.Queue.Count -eq 0 -and $null -ne $e.BatchList.SelectedItem -and [bool]$e.BatchList.SelectedItem.TaskId -and $e.BatchList.SelectedItem.RawState -ne 'Released' -and -not $analysisRunning -and -not $execRunning)
            if($e.ContainsKey('BatchContinueButton')){
                $canCont=(Test-SjcExplorerCanContinueBatch $S)
                $showCont=($S.Batch['Persisted'] -eq $true -and ($S.Batch['CanContinue'] -eq $true -or $S.Batch.Status -in 'Paused','Interrupted','Stopped'))
                $e.BatchContinueButton.Visibility=$(if($showCont){'Visible'}else{'Collapsed'})
                $e.BatchContinueButton.IsEnabled=$canCont
            }
        }
    }
    if($e.ContainsKey('ProgressDetailText')){$e.ProgressDetailText.Text=Get-SjcExplorerProgressDisplayText $S}
    if($e.ContainsKey('CoverageExplanation')){$explanation=Get-SjcExplorerCoverageExplanation $S;$e.CoverageExplanation.Text=$explanation;$e.CoverageExplanation.Visibility=if($explanation){'Visible'}else{'Collapsed'}}
    $headline=Get-SjcExplorerHeadline $S
    if($S.ProgressDirty -or $e.StateText.Text -ne $headline){
        $S.ProgressDirty=$false
        $e.StateText.Text=$headline
        $e.ExplorerProgress.IsIndeterminate=($busy -and -not $S.Fault)
        $c=$S.Coverage
        if($c){$e.CoverageText.Text=('已观察 {0}　待处理目录 {1}　跳过 {2}　逻辑 {3}　占用 {4}　占用未知 {5}' -f $c['ObservedObjects'],$c['PendingDirectories'],$c['SkippedObjects'],(Format-SjcExplorerBytes $c['ObservedLogicalBytes']),(Format-SjcExplorerBytes $c['ObservedAllocatedBytes']),$c['UnknownAllocationObjects'])}
        $msg=@(); if($S.Mode){$msg+='Host 模式 '+$S.Mode}; if($S.LastError){$msg+='最近错误：'+(Get-SjcExplorerErrorText $S.LastError)}; if($S.Stderr.Count){$msg+='Host：'+$S.Stderr[$S.Stderr.Count-1]}; if($W.Tag.TickError){$msg+='界面刷新异常：'+$W.Tag.TickError}; if($S.TaskId){$msg+='任务 '+$S.TaskId}
        $e.StatusText.Text=($msg -join '　')
    }
    if($S.GroupsDirty){
        $S.GroupsDirty=$false
        $selected=$S.ParentId
        $e.GroupsList.ItemsSource=@($S.Groups | ForEach-Object {ConvertTo-SjcExplorerRow $_ 'Group'})
        if($null -ne $selected){foreach($it in $e.GroupsList.Items){if($it.Id -eq $selected){$e.GroupsList.SelectedItem=$it;break}}}
        $e.GroupsPageText.Text=('第 {0} 页，本页 {1} 项' -f $S.GroupsStack.Count,$S.Groups.Count)
        $e.GroupsPrev.IsEnabled=($S.GroupsStack.Count -gt 1); $e.GroupsNext.IsEnabled=($null -ne $S.GroupsNext)
    }
    if($S.SpaceDirty){
        $S.SpaceDirty=$false
        $e.SpaceList.ItemsSource=@($S.Space | ForEach-Object {[pscustomobject]@{Id=[string]$_['ObjectId'];Path=[string]$_['Path'];Kind=[string]$_['Kind'];Logical=(Format-SjcExplorerBytes $_['ObservedLogicalBytes']);Allocated=(Format-SjcExplorerBytes $_['ObservedAllocatedBytes']);Coverage=[string]$_['Coverage'];Unknown=[string]$_['UnknownAllocationObjects'];HardLinks=[string]$_['HardLinkedFiles']}})
        $e.SpacePageText.Text=('第 {0} 页，本页 {1} 项（仅已观察量，非可释放量）' -f $S.SpaceStack.Count,$S.Space.Count)
        $e.SpacePrev.IsEnabled=($S.SpaceStack.Count -gt 1);$e.SpaceNext.IsEnabled=($null -ne $S.SpaceNext)
    }
    if($S.EvidenceDirty){
        $S.EvidenceDirty=$false
        $e.EvidenceList.ItemsSource=@($S.Evidence | ForEach-Object {ConvertTo-SjcExplorerRow $_ 'Evidence'})
        $e.EvPageText.Text=('第 {0} 页，本页 {1} 项' -f $S.EvidenceStack.Count,$S.Evidence.Count)
        $e.EvPrev.IsEnabled=($S.EvidenceStack.Count -gt 1); $e.EvNext.IsEnabled=($null -ne $S.EvidenceNext)
    }
    Update-SjcExplorerApprovalView $W $S
}

function Open-SjcExplorerWindow($Owner,$LaunchSpec,[switch]$NoShow){
    $singleton=$script:SjcExplorerSingleton
    $existing=$singleton.Window
    if($existing -and $existing.IsVisible -and -not $LaunchSpec){
        try{ if($existing.WindowState -eq [Windows.WindowState]::Minimized){$existing.WindowState=[Windows.WindowState]::Normal}; [void]$existing.Activate(); return $existing }catch{}
    }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
    $w=[Windows.Markup.XamlReader]::Parse($script:SjcExplorerXaml)
    if($Owner){ if($Owner.Icon){$w.Icon=$Owner.Icon}; if($Owner.IsLoaded){$w.Owner=$Owner} }
    $names='ProgressDetailText','BatchHistorySection','BatchHistoryList','BatchHistoryRefresh','BatchHistoryPrev','BatchHistoryNext','BatchHistoryView','BatchHistoryPageText','BatchContinueButton','ResourceTab','StorageSummaryText','StorageMaintenanceText','StorageText','StorageDetailText','StorageRefresh','StorageCompact','SessionSummaryText','SessionText','SessionDetailText','StorageDetailsExpander','SessionRelease','DraftArchive','StorageNotice','DiagnosticExport','HistorySearch','HistoryFilter','HistoryPathDetail','ExecutionDetails','BatchPanel','BatchText','BatchOpenButton','BatchList','MainTabs','InventoryTab','SuggestTab','HistoryTab','SpaceTab','SpaceList','SpacePrev','SpaceNext','SpacePageText','ToSuggestButton','AnalyzeButton','ScopeAnalyzeButton','CancelAnalysisButton','EngineNote','TargetText','AnalysisText','SuggestionsList','SugPrev','SugNext','SugPageText','SugDetailText','SugFilesList','SugFilesPrev','SugFilesNext','SugFilesPageText','PrepareButton','SelectionText','ApprovalOverlay','DraftSummary','DraftList','DraftPrev','DraftNext','DraftPageText','ResultText','BackButton','ConfirmButton','ExecuteButton','StopExecButton','HistoryNote','TaskList','TaskRefresh','TaskPrev','TaskNext','TaskRestore','TaskRelease','TaskPageText','ScopeFolderRadio','BrowseButton','FolderPathBox','ScopeDiskRadio','DiskCombo','StartButton','PauseButton','ResumeButton','CancelButton','StateText','CoverageText','ExplorerProgress','GroupsList','GroupsPrev','GroupsNext','GroupsPageText','EvidenceList','EvPrev','EvNext','EvPageText','DetailText','StatusText'
    $c=@{}; foreach($n in $names){$c[$n]=$w.FindName($n)}
    $c['CoverageExplanation']=$w.FindName('CoverageExplanation')
    $c['StorageBudget']=$w.FindName('StorageBudget');$c['StorageBudgetApply']=$w.FindName('StorageBudgetApply')
    foreach($d in Get-SjcExplorerFixedDisks){[void]$c.DiskCombo.Items.Add($d)}
    if($c.DiskCombo.Items.Count){$c.DiskCombo.SelectedIndex=0}
    $state=@{Controls=$c;Scope=$null;Session=$null;TickCount=0;TickError=$null;TickErrors=[Collections.Generic.List[string]]::new()}
    $w.Tag=$state
    $c.StorageBudgetApply.Add_Click({
        $s0=$state.Session;if(-not $s0 -or -not (Test-SjcExplorerMaintenanceReady $s0)){return}
        $amount=0;if(-not [int]::TryParse($c.StorageBudget.Text,[ref]$amount) -or $amount -lt 512 -or $amount -gt 16384){$s0['StorageNotice']='请输入512到16384之间的MiB数值。';$s0.ApprovalDirty=$true;return}
        if(-not (Test-SjcExplorerHasOp $s0 'ConfigureStorageBudget')){$s0['StorageNotice']='当前探索服务不支持可调预算。';$s0.ApprovalDirty=$true;return}
        $confirmed=[Windows.MessageBox]::Show($w,('本次会话允许扫描记录最多占用 {0} MiB。不会删除旧记录或更改清理授权；磁盘余量保护仍生效。是否应用？' -f $amount),'记录空间预算','OKCancel','Question','Cancel')
        if($confirmed -eq 'OK'){Add-SjcExplorerRequest $s0 'ConfigureStorageBudget' $null @{Mebibytes=$amount;Confirmed=$true}}
    }.GetNewClosure())
    try{ $state.Session=New-SjcExplorerSession $LaunchSpec $null }
    catch{ $c.StateText.Text='无法启动探索服务：'+(Get-SjcExplorerReasonText $_.Exception.Message); $state.Session=$null; $c.StatusText.Text='探索功能不可用，不影响原有清理功能。' }
    $getScope={
        if($c.ScopeFolderRadio.IsChecked){ return $c.FolderPathBox.Text }
        if($c.ScopeDiskRadio.IsChecked){return 'AllFixedDisks'}
        return $null
    }.GetNewClosure()
    $refreshScope={ $state.Scope=(& $getScope) }.GetNewClosure()
    $c.BrowseButton.Add_Click({
        $dlg=New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description='选择要只读探索的文件夹'; $dlg.ShowNewFolderButton=$false
        if($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){$c.FolderPathBox.Text=$dlg.SelectedPath; $c.ScopeFolderRadio.IsChecked=$true}
        & $refreshScope
    }.GetNewClosure())
    foreach($ctl in $c.ScopeFolderRadio,$c.ScopeDiskRadio){ $ctl.Add_Checked({& $refreshScope}.GetNewClosure()) }
    $c.FolderPathBox.Add_TextChanged({if($c.ScopeFolderRadio.IsChecked){& $refreshScope}}.GetNewClosure())
    $c.DiskCombo.Add_SelectionChanged({
        if(-not $c.DiskCombo.IsDropDownOpen -and $c.DiskCombo.SelectedItem){$c.FolderPathBox.Text=[string]$c.DiskCombo.SelectedItem;$c.ScopeFolderRadio.IsChecked=$true;& $refreshScope}
    }.GetNewClosure())
    # Reconfirming the current ComboBox value does not raise SelectionChanged.
    # Commit a closed dropdown as well; Escape is an explicit cancellation.
    $c.DiskCombo.Add_DropDownOpened({$state['QuickDiskCancelled']=$false}.GetNewClosure())
    $c.DiskCombo.Add_PreviewKeyDown({param($sender,$event) if($event.Key -eq [Windows.Input.Key]::Escape){$state['QuickDiskCancelled']=$true}}.GetNewClosure())
    $c.DiskCombo.Add_DropDownClosed({
        if(-not $state['QuickDiskCancelled'] -and $c.DiskCombo.SelectedItem){$c.FolderPathBox.Text=[string]$c.DiskCombo.SelectedItem;$c.ScopeFolderRadio.IsChecked=$true;& $refreshScope}
    }.GetNewClosure())
    $c.StartButton.Add_Click({
        & $refreshScope
        if($state.Session -and $state.Scope){
            if($c.ScopeDiskRadio.IsChecked){[void](Start-SjcExplorerAllDisks $state.Session)}
            else{Start-SjcExplorerInventory $state.Session $state.Scope}
        }
    }.GetNewClosure())
    $c.BatchOpenButton.Add_Click({$it=$c.BatchList.SelectedItem;if($it -and $it.TaskId -and $state.Session){[void](Open-SjcExplorerBatchResult $state.Session ([string]$it.TaskId))}}.GetNewClosure())
    $c.BatchContinueButton.Add_Click({
        $s0=$state.Session;if(-not $s0 -or -not (Test-SjcExplorerCanContinueBatch $s0)){return}
        $manifest=Get-SjcExplorerBatchContinueManifest $s0
        if(-not $manifest){return}
        $r=[Windows.MessageBox]::Show($w,($manifest+"`n`n默认选项为「取消」。是否明确确认继续此批次的剩余扫描？"),'确认继续全盘批次',[Windows.MessageBoxButton]::OKCancel,[Windows.MessageBoxImage]::Question,[Windows.MessageBoxResult]::Cancel)
        [void](Request-SjcExplorerContinueBatch $s0 ($r -eq [Windows.MessageBoxResult]::OK))
    }.GetNewClosure())
    $c.BatchHistoryRefresh.Add_Click({if($state.Session){[void](Request-SjcExplorerBatchList $state.Session 0)}}.GetNewClosure())
    $c.BatchHistoryPrev.Add_Click({if($state.Session){[void](Request-SjcExplorerBatchList $state.Session -1)}}.GetNewClosure())
    $c.BatchHistoryNext.Add_Click({if($state.Session){[void](Request-SjcExplorerBatchList $state.Session 1)}}.GetNewClosure())
    $c.BatchHistoryList.Add_SelectionChanged({if($state.Session){$state.Session['BatchListDirty']=$false}}.GetNewClosure())
    $c.BatchHistoryView.Add_Click({
        $it=$c.BatchHistoryList.SelectedItem
        if($it -and $state.Session -and (Open-SjcExplorerHistoricalBatch $state.Session ([string]$it.Id))){$c.MainTabs.SelectedItem=$c.InventoryTab}
    }.GetNewClosure())
    $c.PauseButton.Add_Click({ Invoke-SjcExplorerTaskCommand $state.Session 'Pause' }.GetNewClosure())
    $c.ResumeButton.Add_Click({ Invoke-SjcExplorerTaskCommand $state.Session 'Resume' }.GetNewClosure())
    $c.CancelButton.Add_Click({ Invoke-SjcExplorerTaskCommand $state.Session 'Cancel' }.GetNewClosure())
    $c.GroupsPrev.Add_Click({ Move-SjcExplorerPage $state.Session 'Groups' -1 }.GetNewClosure())
    $c.GroupsNext.Add_Click({ Move-SjcExplorerPage $state.Session 'Groups' 1 }.GetNewClosure())
    $c.EvPrev.Add_Click({ Move-SjcExplorerPage $state.Session 'Evidence' -1 }.GetNewClosure())
    $c.EvNext.Add_Click({ Move-SjcExplorerPage $state.Session 'Evidence' 1 }.GetNewClosure())
    $c.ToSuggestButton.Add_Click({ $c.MainTabs.SelectedItem=$c.SuggestTab }.GetNewClosure())
    # 深入调查仅由用户主动发起；整个范围与单目录共用预算和精确复核链。
    $c.AnalyzeButton.Add_Click({ if($state.Session){ [void](Start-SjcExplorerAnalysis $state.Session 'Selected') } }.GetNewClosure())
    $c.ScopeAnalyzeButton.Add_Click({ if($state.Session){ [void](Start-SjcExplorerAnalysis $state.Session 'Scope') } }.GetNewClosure())
    $c.CancelAnalysisButton.Add_Click({ if($state.Session){ [void](Stop-SjcExplorerAnalysis $state.Session) } }.GetNewClosure())
    $c.SpacePrev.Add_Click({ if($state.Session){ Move-SjcExplorerSpacePage $state.Session -1 } }.GetNewClosure())
    $c.SpaceNext.Add_Click({ if($state.Session){ Move-SjcExplorerSpacePage $state.Session 1 } }.GetNewClosure())
    $c.SugPrev.Add_Click({ Move-SjcExplorerSuggestionPage $state.Session -1 }.GetNewClosure())
    $c.SugNext.Add_Click({ Move-SjcExplorerSuggestionPage $state.Session 1 }.GetNewClosure())
    $c.SugFilesPrev.Add_Click({ Move-SjcExplorerSuggestionFilesPage $state.Session -1 }.GetNewClosure())
    $c.SugFilesNext.Add_Click({ Move-SjcExplorerSuggestionFilesPage $state.Session 1 }.GetNewClosure())
    $c.DraftPrev.Add_Click({ Move-SjcExplorerDraftPage $state.Session -1 }.GetNewClosure())
    $c.DraftNext.Add_Click({ Move-SjcExplorerDraftPage $state.Session 1 }.GetNewClosure())
    # Checked/Unchecked 同时覆盖普通点击与辅助功能 Toggle；模板绑定刷新不改变批准集合。
    $selectionChanged=[Windows.RoutedEventHandler]{
        param($sender,$e)
        $cb=$e.OriginalSource -as [Windows.Controls.CheckBox]
        $s0=$state.Session
        if($cb -and $cb.Tag -and $s0 -and -not $s0.RenderingSuggestions){
            $sid=[string]$cb.Tag; $on=($cb.IsChecked -eq $true); $selected=$s0.Selected.ContainsKey($sid)
            if($on -eq $selected){return}
            $ok=Set-SjcExplorerSuggestionSelected $s0 $sid $on
            if(-not $ok){$cb.IsChecked=$selected}
            elseif($cb.DataContext){$cb.DataContext.Checked=$on}
        }
    }.GetNewClosure()
    $c.SuggestionsList.AddHandler([Windows.Controls.Primitives.ToggleButton]::CheckedEvent,$selectionChanged)
    $c.SuggestionsList.AddHandler([Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,$selectionChanged)
    $c.SuggestionsList.Add_SelectionChanged({
        $it=$c.SuggestionsList.SelectedItem
        if($it -and $state.Session){
            $c.SugDetailText.Text=Get-SjcExplorerSuggestionDetail $state.Session.SugIndex[[string]$it.Id]
            Select-SjcExplorerSuggestionFiles $state.Session ([string]$it.Id)
        }
    }.GetNewClosure())
    $c.PrepareButton.Add_Click({ if($state.Session){ [void](Request-SjcExplorerPrepare $state.Session) } }.GetNewClosure())
    $c.BackButton.Add_Click({ if($state.Session){ Undo-SjcExplorerDraft $state.Session; $state.Session.SugDirty=$true } }.GetNewClosure())
    $c.ConfirmButton.Add_Click({
        $s0=$state.Session; if(-not $s0 -or -not $s0.Draft){return}
        $r=[Windows.MessageBox]::Show($w,("确认这份复核清单？`n`n共 {0} 个文件，约 {1}，方式：只移入回收站。`n此步骤只是批准清单，不会处理任何文件；之后还需要再点一次「第二步」才会真正移入回收站。" -f $s0.Draft.ItemCount,(Format-SjcExplorerBytes $s0.Draft.LogicalBytes)),'确认复核清单',[Windows.MessageBoxButton]::OKCancel,[Windows.MessageBoxImage]::Question,[Windows.MessageBoxResult]::Cancel)
        [void](Confirm-SjcExplorerApproval $s0 ($r -eq [Windows.MessageBoxResult]::OK))
    }.GetNewClosure())
    $c.ExecuteButton.Add_Click({
        $s0=$state.Session; if(-not $s0 -or -not (Test-SjcExplorerCanExecute $s0)){return}
        $r=[Windows.MessageBox]::Show($w,("最后确认：把这 {0} 个文件（约 {1}）移入回收站？`n`n不是永久删除，可在回收站还原；但磁盘空间要清空回收站后才会释放。`n默认选项是「取消」。" -f $s0.Draft.ItemCount,(Format-SjcExplorerBytes $s0.Draft.LogicalBytes)),'移入回收站',[Windows.MessageBoxButton]::OKCancel,[Windows.MessageBoxImage]::Warning,[Windows.MessageBoxResult]::Cancel)
        [void](Invoke-SjcExplorerExecute $s0 ($r -eq [Windows.MessageBoxResult]::OK))
    }.GetNewClosure())
    $c.StopExecButton.Add_Click({ if($state.Session){ Stop-SjcExplorerExecution $state.Session } }.GetNewClosure())
    $c.TaskRefresh.Add_Click({ if($state.Session){ Request-SjcExplorerTaskList $state.Session 0 } }.GetNewClosure())
    $c.TaskPrev.Add_Click({ if($state.Session){ Request-SjcExplorerTaskList $state.Session -1 } }.GetNewClosure())
    $c.TaskNext.Add_Click({ if($state.Session){ Request-SjcExplorerTaskList $state.Session 1 } }.GetNewClosure())
    $c.TaskList.Add_SelectionChanged({ if($state.Session){ $state.Session.TaskListDirty=$false } }.GetNewClosure())
    $c.TaskRestore.Add_Click({
        $it=$c.TaskList.SelectedItem; if($it -and $state.Session -and (Restore-SjcExplorerTask $state.Session ([string]$it.Id))){ $c.MainTabs.SelectedItem=$c.InventoryTab }
    }.GetNewClosure())
    $c.HistorySearch.Add_Click({if($state.Session){Set-SjcExplorerHistoryFilter $state.Session $c.HistoryFilter.Text}}.GetNewClosure())
    $c.TaskList.Add_SelectionChanged({$it=$c.TaskList.SelectedItem;$c.HistoryPathDetail.Text=$(if($it){'完整扫描路径：'+$it.Root+'　任务：'+$it.Id}else{''})}.GetNewClosure())
    $c.StorageRefresh.Add_Click({if($state.Session){$state.Session['StorageReadFailed']=$false;$state.Session['SessionReadFailed']=$false;Request-SjcExplorerStorage $state.Session}}.GetNewClosure())
    $c.MainTabs.Add_SelectionChanged({
        if($state.Session -and $c.MainTabs.SelectedItem -eq $c.ResourceTab){Request-SjcExplorerStorageAutoRead $state.Session}
    }.GetNewClosure())
    $c.StorageCompact.Add_Click({
        $s0=$state.Session;if(-not $s0 -or -not $s0['Storage']){return};$st=$s0.Storage
        $text=('整理扫描记录占用？保留所有扫描记录，不删除你的文件，也不保证释放磁盘空间。整理前会生成备份，预计额外占用 {0}，当前可用 {1}。备份仍占磁盘空间且不会自动删除。整理时请等待结果，不要重复执行。' -f (Format-SjcExplorerBytes $st['EstimatedExtraBytes']),(Format-SjcExplorerBytes $st['AvailableDriveBytes']))
        $r=[Windows.MessageBox]::Show($w,$text,'确认整理扫描记录占用','OKCancel','Question','Cancel');[void](Request-SjcExplorerMaintenance $s0 'CompactState' ($r -eq 'OK'))
    }.GetNewClosure())
    $c.SessionRelease.Add_Click({$s0=$state.Session;if(-not $s0){return};$r=[Windows.MessageBox]::Show($w,'重置已结束的分析？旧建议、复核清单及未执行批准将失效；扫描历史、防重放记录和执行账本保留，不删除你的文件。','确认重置已结束的分析','OKCancel','Question','Cancel');[void](Request-SjcExplorerMaintenance $s0 'ReleaseFinishedSessions' ($r -eq 'OK'))}.GetNewClosure())
    $c.DraftArchive.Add_Click({$s0=$state.Session;if(-not $s0){return};$r=[Windows.MessageBox]::Show($w,'整理可证明未确认、未使用的复核材料？材料会移入保留区，已确认凭据和执行账本不动。保留材料仍占磁盘空间，不删除你的文件。','确认整理未确认的复核材料','OKCancel','Question','Cancel');[void](Request-SjcExplorerMaintenance $s0 'ArchiveUnconfirmedDrafts' ($r -eq 'OK'))}.GetNewClosure())
    $c.ExecutionDetails.Add_Click({if($state.Session){Show-SjcExplorerExecutionEntries $w $state.Session}}.GetNewClosure())
    $c.DiagnosticExport.Add_Click({
        $s0=$state.Session;if(-not $s0){return};$dlg=New-Object Microsoft.Win32.SaveFileDialog;$dlg.Filter='问题报告 (*.json)|*.json';$dlg.FileName='SafeJunkCleaner-diagnostic-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json';$dlg.OverwritePrompt=$true
        if($dlg.ShowDialog($w)){
            try{$path=Export-SjcExplorerDiagnostic $s0 $dlg.FileName;$s0['StorageNotice']='问题报告已仅保存本地：'+$path;$s0.ApprovalDirty=$true}
            catch{$s0['StorageNotice']='问题报告未保存：'+$_.Exception.Message;$s0.ApprovalDirty=$true}
        }
    }.GetNewClosure())
    $c.TaskRelease.Add_Click({
        $it=$c.TaskList.SelectedItem; if(-not $it -or -not $state.Session){return}
        $r=[Windows.MessageBox]::Show($w,("释放任务 {0}？`n释放后该任务的盘点记录与分析将不再可恢复（不会删除任何磁盘文件）。" -f $it.Id),'释放任务',[Windows.MessageBoxButton]::OKCancel,[Windows.MessageBoxImage]::Question,[Windows.MessageBoxResult]::Cancel)
        [void](Release-SjcExplorerTask $state.Session ([string]$it.Id) ($r -eq [Windows.MessageBoxResult]::OK))
    }.GetNewClosure())
    $c.GroupsList.Add_SelectionChanged({
        $it=$c.GroupsList.SelectedItem
        if($it -and $state.Session -and $it.Id -ne $state.Session.ParentId){Select-SjcExplorerGroup $state.Session $it.Id}
    }.GetNewClosure())
    $c.EvidenceList.Add_SelectionChanged({
        $it=$c.EvidenceList.SelectedItem
        if($it){
            $r=$it.Raw
            $c.DetailText.Text=("路径：{0}`n类型：{1}　覆盖：{2}　保护：{3}`n逻辑大小：{4}　占用：{5}　链接数：{6}`n修改：{7}　观察：{8}`n跳过原因：{9}`n检测版本：{10}`n（以上为只读元数据，不构成清理建议。）" -f $r['Path'],$r['Kind'],$r['Coverage'],$r['Protection'],$it.Logical,$it.Allocated,$r['LinkCount'],$r['ModifiedUtc'],$r['ObservedUtc'],$r['SkippedReason'],$r['DetectorVersion'])
        }
    }.GetNewClosure())
    # 定时器异常不得被事件系统吞掉：记录到 TickErrors 并显示在状态栏，同时保持定时器继续运行。
    $timer=New-Object Windows.Threading.DispatcherTimer; $timer.Interval=[TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({
        $state.TickCount++
        try{ if($state.Session){ Step-SjcExplorerSession $state.Session; Update-SjcExplorerWindow $w $state.Session } }
        catch{
            $text=$_.Exception.GetType().Name+': '+$_.Exception.Message
            $state.TickError=$text; if($state.TickErrors.Count -lt 20){$state.TickErrors.Add($text)}
            try{ $c.StatusText.Text='界面刷新异常：'+$text }catch{}
        }
    }.GetNewClosure())
    $timer.Start(); $state.Timer=$timer
    $w.Add_Closing({ $timer.Stop(); if($state.Session){ [void](Close-SjcExplorerSession $state.Session) } }.GetNewClosure())
    $w.Add_Closed({ if([object]::ReferenceEquals($singleton.Window,$w)){$singleton.Window=$null} }.GetNewClosure())
    if($state.Session){ $state.Session.ProgressDirty=$true }
    & $refreshScope
    if(-not $LaunchSpec){ $singleton.Window=$w }
    if(-not $NoShow){ $w.Show() }
    return $w
}
