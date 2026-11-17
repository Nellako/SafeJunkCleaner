using System.Text;
using SafeJunkCleaner.Explorer.Execution;
using System.Text.Json;
using System.Threading.Channels;

namespace SafeJunkCleaner.Explorer.Host;

// Separate from the frozen Inventory JSONL implementation. ContractVersion identifies
// additive Host capabilities; ProtocolVersion retains the original strict envelope.
internal static class HostProtocol
{
    private const int MaxInput = 32768, MaxOutput = 262144;
    internal static async Task RunAsync(InventoryEngine engine, ExplorerCoordinator coordinator,
        Func<string?, int, object> listTasks, Stream input, TextWriter output)
    {
        var replies = Channel.CreateBounded<string>(new BoundedChannelOptions(8) { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
        var writer = Task.Run(async () => { await foreach (var line in replies.Reader.ReadAllAsync()) { await output.WriteLineAsync(line); await output.FlushAsync(); } });
        var seen = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            while (true)
            {
                var read = await ReadLine(input); if (read.Line == null && !read.TooLarge) break;
                string? requestId = null, taskId = null; object response;
                try
                {
                    if (read.TooLarge) throw new InvalidOperationException("MessageTooLarge");
                    using var doc = JsonDocument.Parse(read.Line!, new JsonDocumentOptions { MaxDepth = 8 }); var r = doc.RootElement;
                    Fields(r, "ProtocolVersion", "RequestId", "TaskId", "Operation", "Payload");
                    if (r.GetProperty("ProtocolVersion").GetInt32() != 1) throw new InvalidOperationException("ProtocolVersionMismatch");
                    requestId = Id(r.GetProperty("RequestId"));
                    if (seen.Count >= 100000) throw new InvalidOperationException("SessionRequestLimitRestartRequired");
                    if (!seen.Add(requestId)) throw new InvalidOperationException("DuplicateRequestId");
                    taskId = r.GetProperty("TaskId").ValueKind == JsonValueKind.Null ? null : Id(r.GetProperty("TaskId"));
                    string op = r.GetProperty("Operation").GetString() ?? throw new InvalidOperationException("OperationRequired"); var p = r.GetProperty("Payload");
                    if (op is "Health" or "CreateInventory" or "ListTasks" or "GetStorageInfo" or "CompactState" or "GetSessionInfo" or "ArchiveUnconfirmedDrafts" or "ReleaseFinishedSessions" or "CreateBatch" or "ListBatches" or "GetBatch" or "ContinueBatch" or "StartBatchEntry" or "PauseBatch" or "CancelBatch" or "StopBatch") { if (taskId != null) throw new InvalidOperationException("UnexpectedTaskId"); }
                    else if (op == "ConfigureStorageBudget") { if (taskId != null) throw new InvalidOperationException("UnexpectedTaskId"); }
                    else if (taskId == null) throw new InvalidOperationException("TaskIdRequired");
                    object? result;
                    switch (op)
                    {
                        case "Health":
                            Fields(p); result = new { ProtocolVersion = 1, SchemaVersion = 1, ContractVersion = 3, Mode = "LocalExploration", ModelMode = "Absent", AlgorithmMode = "Heuristic", MaxMessageBytes = MaxInput, MaxResponseBytes = MaxOutput, MaxPageSize = 64, MaxCursorLength = OpaqueCursorCodec.MaximumLength,
                                Capabilities = new { InventoryReady = true, AnalysisFactsReady = true, HeuristicExploration = true, ModelReady = false, ModelAvailable = false, ModelIncluded = false, ModelEnabledByDefault = false, ModelAvailabilityStatus = "NotIncluded", ApprovalReady = true, RecycleAvailable = coordinator.RecycleAvailable, RecycleEnabledByDefault = false, RecycleEnabled = false, StaExecutionQueueReady = true },
                                Operations = new[] { "Health", "GetStorageInfo", "CompactState", "GetSessionInfo", "ArchiveUnconfirmedDrafts", "ReleaseFinishedSessions", "ListTasks", "CreateInventory", "GetProgress", "QueryGroups", "QueryEvidence", "QuerySpace", "Pause", "Resume", "Cancel", "ReleaseTask", "Analyze", "CancelAnalysis", "GetAnalysisProgress", "QuerySuggestions", "QuerySuggestionFiles", "InvalidateAnalysis", "PrepareApproval", "QueryApprovalItems", "ConfirmApproval", "ExecuteApproved", "GetExecutionResult", "CancelExecution", "CreateBatch", "ListBatches", "GetBatch", "ContinueBatch", "StartBatchEntry", "PauseBatch", "CancelBatch", "StopBatch" } }; break;
                        case "CreateBatch":
                            Fields(p, "BatchId", "Roots"); var roots = p.GetProperty("Roots");
                            if (roots.ValueKind != JsonValueKind.Array || roots.GetArrayLength() is < 1 or > 26) throw new InvalidOperationException("InvalidBatchRoots");
                            var batchRoots = roots.EnumerateArray().Select(e => e.ValueKind == JsonValueKind.String ? e.GetString()! : throw new InvalidOperationException("InvalidBatchRoots")).ToArray();
                            coordinator.AssertIdle(); result = engine.CreateBatch(Id(p.GetProperty("BatchId")), batchRoots); break;
                        case "ListBatches": Fields(p, "AfterBatchId", "PageSize"); result = engine.ListBatches(OptionalId(p.GetProperty("AfterBatchId")), p.GetProperty("PageSize").GetInt32()); break;
                        case "GetBatch": Fields(p, "BatchId"); result = engine.GetBatch(Id(p.GetProperty("BatchId"))); break;
                        case "ContinueBatch": Fields(p, "BatchId", "ExpectedRevision", "Confirmed"); coordinator.AssertIdle(); result = engine.ContinueBatch(Id(p.GetProperty("BatchId")), p.GetProperty("ExpectedRevision").GetInt64(), p.GetProperty("Confirmed").GetBoolean()); break;
                        case "StartBatchEntry": Fields(p, "BatchId", "EntryIndex", "ExpectedRevision"); coordinator.AssertIdle(); result = engine.StartBatchEntry(Id(p.GetProperty("BatchId")), p.GetProperty("EntryIndex").GetInt32(), p.GetProperty("ExpectedRevision").GetInt64()); break;
                        case "PauseBatch": Fields(p, "BatchId", "ExpectedRevision"); coordinator.AssertIdle(); result = engine.PauseBatch(Id(p.GetProperty("BatchId")), p.GetProperty("ExpectedRevision").GetInt64()); break;
                        case "CancelBatch": Fields(p, "BatchId", "ExpectedRevision"); coordinator.AssertIdle(); result = engine.CancelBatch(Id(p.GetProperty("BatchId")), p.GetProperty("ExpectedRevision").GetInt64()); break;
                        case "StopBatch": Fields(p, "BatchId", "ExpectedRevision"); coordinator.AssertIdle(); result = engine.StopBatch(Id(p.GetProperty("BatchId")), p.GetProperty("ExpectedRevision").GetInt64()); break;
                        case "GetStorageInfo": Fields(p); result = engine.GetStorageInfo(); break;
                        case "ConfigureStorageBudget": Fields(p, "Mebibytes", "Confirmed"); coordinator.AssertIdle(); result = engine.ConfigureStorageBudget(p.GetProperty("Mebibytes").GetInt32(), p.GetProperty("Confirmed").GetBoolean()); break;
                        case "CompactState": Fields(p, "Confirmed"); coordinator.AssertIdle(); result = engine.CompactState(p.GetProperty("Confirmed").GetBoolean()); break;
                        case "GetSessionInfo": Fields(p); result = coordinator.GetSessionInfo(); break;
                        case "ReleaseFinishedSessions": Fields(p, "Confirmed"); result = coordinator.ReleaseFinishedSessions(p.GetProperty("Confirmed").GetBoolean()); break;
                        case "ArchiveUnconfirmedDrafts": Fields(p, "Confirmed"); coordinator.AssertIdle(); if (!engine.GetStorageInfo().CanCompact) throw new InvalidOperationException("InventoryActive"); result = coordinator.ArchiveUnconfirmedDrafts(p.GetProperty("Confirmed").GetBoolean()); break;
                        case "ListTasks":
                            FieldsWithOptional(p, "PathFilter", "AfterTaskId", "PageSize");
                            result = p.TryGetProperty("PathFilter", out var filter)
                                ? engine.ListTasks(OptionalId(p.GetProperty("AfterTaskId")), p.GetProperty("PageSize").GetInt32(), filter.ValueKind == JsonValueKind.Null ? null : filter.GetString())
                                : listTasks(OptionalId(p.GetProperty("AfterTaskId")), p.GetProperty("PageSize").GetInt32()); break;
                        case "CreateInventory":
                            FieldsWithOptional(p, "ScanMode", "SelectedPath"); taskId = engine.CreateInventory(p.GetProperty("SelectedPath").GetString() ?? throw new InvalidOperationException("SelectedPathRequired"),
                                p.TryGetProperty("ScanMode", out var scanMode) ? scanMode.GetString() ?? throw new InvalidOperationException("InvalidScanMode") : "Selected"); result = new { TaskId = taskId }; break;
                        case "GetProgress": Fields(p); result = engine.GetProgress(taskId!); break;
                        case "QueryGroups": Fields(p, "AfterId", "PageSize"); result = engine.QueryGroups(taskId!, p.GetProperty("AfterId").GetInt64(), p.GetProperty("PageSize").GetInt32()); break;
                        case "QuerySpace": Fields(p, "AfterCursor", "PageSize"); result = engine.QuerySpace(taskId!, Cursor(p.GetProperty("AfterCursor")), p.GetProperty("PageSize").GetInt32()); break;
                        case "QuerySpaceAsync":
                            Fields(p, "AfterCursor", "PageSize"); string? spaceCursor = Cursor(p.GetProperty("AfterCursor")); int spaceSize = p.GetProperty("PageSize").GetInt32(); string spaceTask = taskId!;
                            result = coordinator.QuerySpaceAsync(spaceTask, spaceCursor, spaceSize, () => engine.QuerySpace(spaceTask, spaceCursor, spaceSize)); break;
                        case "QueryEvidence":
                            Fields(p, "AfterId", "PageSize", "ParentId"); var parent = p.GetProperty("ParentId"); long? parentId = parent.ValueKind == JsonValueKind.Null ? null : parent.GetInt64();
                            if (parentId < 1) throw new InvalidOperationException("InvalidParentId"); result = engine.QueryEvidence(taskId!, p.GetProperty("AfterId").GetInt64(), p.GetProperty("PageSize").GetInt32(), parentId); break;
                        case "Pause": Fields(p); engine.Pause(taskId!); result = new { Accepted = true, State = "PauseRequested" }; break;
                        case "Resume": Fields(p); coordinator.AssertCanChangeInventory(taskId!); engine.Resume(taskId!); result = new { Accepted = true }; break;
                        case "Cancel": Fields(p); engine.Cancel(taskId!); result = new { Accepted = true, State = "CancelRequested" }; break;
                        case "ReleaseTask": Fields(p); coordinator.AssertReleasable(taskId!); engine.ReleaseTask(taskId!); result = new { Released = true }; break;
                        case "Analyze":
                            FieldsWithOptional(p, "ExplorationMode", "TargetId", "ExpectedEvidenceRevision");
                            result = coordinator.Analyze(taskId!, p.GetProperty("TargetId").ValueKind == JsonValueKind.Null ? null : ObjectId(p.GetProperty("TargetId")), p.GetProperty("ExpectedEvidenceRevision").GetInt64(), p.TryGetProperty("ExplorationMode", out var mode) ? mode.GetString() ?? throw new InvalidOperationException("InvalidExplorationModeTarget") : "Selected"); break;
                        case "CancelAnalysis": Fields(p, "AnalysisId"); coordinator.CancelAnalysis(taskId!, Id(p.GetProperty("AnalysisId"))); result = new { CancellationRequested = true }; break;
                        case "GetAnalysisProgress": Fields(p, "AnalysisId"); result = coordinator.GetAnalysisProgress(taskId!, Id(p.GetProperty("AnalysisId"))); break;
                        case "QuerySuggestions": Fields(p, "AnalysisId", "AfterId", "PageSize"); result = coordinator.QuerySuggestions(taskId!, Id(p.GetProperty("AnalysisId")), Cursor(p.GetProperty("AfterId")), p.GetProperty("PageSize").GetInt32()); break;
                        case "QuerySuggestionFiles": Fields(p, "AnalysisId", "SuggestionId", "AfterId", "PageSize"); result = coordinator.QuerySuggestionFiles(taskId!, Id(p.GetProperty("AnalysisId")), Id(p.GetProperty("SuggestionId")), Cursor(p.GetProperty("AfterId")), p.GetProperty("PageSize").GetInt32()); break;
                        case "InvalidateAnalysis": Fields(p, "AnalysisId"); coordinator.InvalidateAnalysis(taskId!, Id(p.GetProperty("AnalysisId"))); result = new { Invalidated = true }; break;
                        case "BeginPrepareApproval":
                        case "PrepareApproval":
                            Fields(p, "AnalysisId", "SuggestionIds", "ExpectedEvidenceRevision"); var ids = p.GetProperty("SuggestionIds");
                            if (ids.ValueKind != JsonValueKind.Array || ids.GetArrayLength() is < 1 or > 128) throw new InvalidOperationException("InvalidSuggestionSet");
                            result = op == "BeginPrepareApproval" ? coordinator.BeginPrepareApproval(taskId!, Id(p.GetProperty("AnalysisId")), ids.EnumerateArray().Select(Id).ToArray(), p.GetProperty("ExpectedEvidenceRevision").GetInt64())
                                : coordinator.PrepareApproval(taskId!, Id(p.GetProperty("AnalysisId")), ids.EnumerateArray().Select(Id).ToArray(), p.GetProperty("ExpectedEvidenceRevision").GetInt64()); break;
                        case "GetPreparationProgress": Fields(p, "PreparationId"); result = coordinator.GetPreparationProgress(taskId!, Id(p.GetProperty("PreparationId"))); break;
                        case "CancelPreparation": Fields(p, "PreparationId"); coordinator.CancelPreparation(taskId!, Id(p.GetProperty("PreparationId"))); result = new { CancellationRequested = true }; break;
                        case "QueryApprovalItems": Fields(p, "DraftId", "AfterId", "PageSize"); result = coordinator.QueryApprovalItems(taskId!, Id(p.GetProperty("DraftId")), p.GetProperty("AfterId").GetInt32(), p.GetProperty("PageSize").GetInt32()); break;
                        case "ConfirmApproval": Fields(p, "DraftId", "DisplayHash"); result = coordinator.ConfirmApproval(taskId!, Id(p.GetProperty("DraftId")), Hash(p.GetProperty("DisplayHash"))); break;
                        case "ExecuteApproved": Fields(p, "ApprovalId"); result = coordinator.ExecuteApproved(taskId!, Id(p.GetProperty("ApprovalId"))); break;
                        case "GetExecutionResult": Fields(p, "ApprovalId", "AfterEntry", "PageSize"); result = coordinator.GetExecutionResult(taskId!, Id(p.GetProperty("ApprovalId")), p.GetProperty("AfterEntry").GetInt32(), p.GetProperty("PageSize").GetInt32()); break;
                        case "CancelExecution": Fields(p, "ApprovalId"); coordinator.CancelExecution(taskId!, Id(p.GetProperty("ApprovalId"))); result = new { CancellationRequested = true }; break;
                        default: throw new InvalidOperationException("UnknownOperation");
                    }
                    if (op == "Health")
                    {
                        // Capabilities are additive; legacy operations keep their strict shapes.
                        var health = JsonSerializer.SerializeToElement(result);
                        var properties = JsonSerializer.Deserialize<Dictionary<string, object>>(health.GetRawText())!;
                        properties["Operations"] = health.GetProperty("Operations").EnumerateArray().Select(e => e.GetString()!)
                            .Concat(["BeginPrepareApproval", "GetPreparationProgress", "CancelPreparation", "ConfigureStorageBudget", "QuerySpaceAsync"]).ToArray();
                        result = properties;
                    }
                    response = new { ProtocolVersion = 1, RequestId = requestId, TaskId = taskId, Ok = true, Result = result };
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    string code = ex is InvalidOperationException ? ex.Message : ex.GetType().Name;
                    if (code.Length > 100 || code.Any(c => !(char.IsAsciiLetterOrDigit(c) || c == '_'))) code = ex.GetType().Name;
                    Console.Error.WriteLine("Request rejected: " + code);
                    object error = ex is StateCompactionException compact
                        ? new { Code = code, compact.Stage, compact.BackupPath, compact.BeforeBytes, compact.BackupBytes, StatePathRetained = true, BackupExists = compact.BackupPath != null && File.Exists(compact.BackupPath), AutomaticRestorePerformed = false }
                        : ex is ApprovalArchiveException archive ? new { Code = code, archive.ArchivePath, archive.MovedFiles } : new { Code = code };
                    response = new { ProtocolVersion = 1, RequestId = requestId, TaskId = taskId, Ok = false, Error = error };
                }
                string text = JsonSerializer.Serialize(response);
                if (Encoding.UTF8.GetByteCount(text) > MaxOutput) text = JsonSerializer.Serialize(new { ProtocolVersion = 1, RequestId = requestId, TaskId = taskId, Ok = false, Error = new { Code = "ResponseTooLargeReducePageSize" } });
                await replies.Writer.WriteAsync(text);
            }
        }
        finally { replies.Writer.Complete(); await writer; }
    }
    private static void FieldsWithOptional(JsonElement e, string optional, params string[] names)
    {
        if (e.ValueKind != JsonValueKind.Object) throw new InvalidOperationException("ObjectRequired");
        var seen = new HashSet<string>();
        foreach (var p in e.EnumerateObject()) if ((p.Name != optional && !names.Contains(p.Name, StringComparer.Ordinal)) || !seen.Add(p.Name)) throw new InvalidOperationException("UnknownOrDuplicateField");
        if (names.Any(n => !seen.Contains(n))) throw new InvalidOperationException("MissingField");
    }
    private static void Fields(JsonElement e, params string[] names)
    {
        if (e.ValueKind != JsonValueKind.Object) throw new InvalidOperationException("ObjectRequired"); var seen = new HashSet<string>();
        foreach (var p in e.EnumerateObject()) if (!names.Contains(p.Name, StringComparer.Ordinal) || !seen.Add(p.Name)) throw new InvalidOperationException("UnknownOrDuplicateField");
        if (seen.Count != names.Length) throw new InvalidOperationException("MissingField");
    }
    private static string Id(JsonElement e) { if (!Guid.TryParseExact(e.GetString(), "D", out var id) || id == Guid.Empty) throw new InvalidOperationException("InvalidId"); return id.ToString("D"); }
    private static string? Cursor(JsonElement e)
    {
        if (e.ValueKind == JsonValueKind.Null) return null;
        var value = e.GetString();
        if (value is not { Length: > 0 and <= OpaqueCursorCodec.MaximumLength } || value.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('-' or '_'))) throw new InvalidOperationException("InvalidCursor");
        return value;
    }
    private static string? OptionalId(JsonElement e) => e.ValueKind == JsonValueKind.Null ? null : Id(e);
    private static string ObjectId(JsonElement e) { var s = e.GetString(); if (s is not { Length: > 0 and <= 80 } || !s.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')) throw new InvalidOperationException("InvalidObjectId"); return s; }
    private static string Hash(JsonElement e) { var s = e.GetString(); if (s is not { Length: 64 } || !s.All(Uri.IsHexDigit)) throw new InvalidOperationException("InvalidHash"); return s; }
    private static async Task<(string? Line, bool TooLarge)> ReadLine(Stream stream)
    {
        var bytes = new byte[MaxInput]; var one = new byte[1]; int count = 0; bool large = false;
        while (await stream.ReadAsync(one) != 0)
        {
            if (one[0] == 10) return large ? (null, true) : (Decode(bytes, count), false);
            if (count == bytes.Length) large = true; else bytes[count++] = one[0];
        }
        return large ? (null, true) : count == 0 ? (null, false) : (Decode(bytes, count), false);
    }
    private static string Decode(byte[] bytes, int count) { try { return new UTF8Encoding(false, true).GetString(bytes, 0, count); } catch (DecoderFallbackException) { return "!invalid-utf8"; } }
}
