using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace SafeJunkCleaner.Explorer;

public static class JsonProtocol
{
    public const int Version = 1, MaxMessageBytes = 32768, MaxResponseBytes = 262144;
    public static async Task RunAsync(InventoryEngine engine, Stream input, TextWriter output)
    {
        var replies = Channel.CreateBounded<string>(new BoundedChannelOptions(8) { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
        var writer = Task.Run(async () => { await foreach (var line in replies.Reader.ReadAllAsync()) { await output.WriteLineAsync(line); await output.FlushAsync(); } });
        var seen = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            while (true)
            {
                var (line, oversized) = await ReadLine(input);
                if (line == null && !oversized) break;
                string? requestId = null, taskId = null; object response;
                try
                {
                    if (oversized) throw new InvalidOperationException("MessageTooLarge");
                    using var doc = JsonDocument.Parse(line!, new JsonDocumentOptions { MaxDepth = 8 }); var root = doc.RootElement;
                    Fields(root, "ProtocolVersion", "RequestId", "TaskId", "Operation", "Payload");
                    if (root.GetProperty("ProtocolVersion").GetInt32() != Version) throw new InvalidOperationException("ProtocolVersionMismatch");
                    requestId = Id(root.GetProperty("RequestId"));
                    if (seen.Count >= 100000) throw new InvalidOperationException("SessionRequestLimitRestartRequired");
                    if (!seen.Add(requestId)) throw new InvalidOperationException("DuplicateRequestId");
                    var task = root.GetProperty("TaskId"); taskId = task.ValueKind == JsonValueKind.Null ? null : Id(task);
                    string operation = root.GetProperty("Operation").GetString() ?? throw new InvalidOperationException("OperationRequired");
                    var p = root.GetProperty("Payload"); object? result;
                    if (operation is "Health" or "CreateInventory")
                    {
                        if (taskId != null) throw new InvalidOperationException("UnexpectedTaskId");
                    }
                    else if (taskId == null) throw new InvalidOperationException("TaskIdRequired");
                    switch (operation)
                    {
                        case "Health": Fields(p); result = new { ProtocolVersion = Version, SchemaVersion = 1, Mode = "ReadOnly", MaxMessageBytes, MaxResponseBytes, MaxPageSize = 64, Operations = new[] { "Health", "CreateInventory", "GetProgress", "QueryGroups", "QueryEvidence", "Pause", "Resume", "Cancel", "ReleaseTask" } }; break;
                        case "CreateInventory":
                            Fields(p, "SelectedPath"); taskId = engine.CreateInventory(p.GetProperty("SelectedPath").GetString() ?? throw new InvalidOperationException("SelectedPathRequired")); result = new { TaskId = taskId }; break;
                        case "GetProgress": Fields(p); result = engine.GetProgress(taskId!); break;
                        case "QueryGroups": Fields(p, "AfterId", "PageSize"); result = engine.QueryGroups(taskId!, p.GetProperty("AfterId").GetInt64(), p.GetProperty("PageSize").GetInt32()); break;
                        case "QueryEvidence":
                            Fields(p, "AfterId", "PageSize", "ParentId"); var parent = p.GetProperty("ParentId"); long? parentId = parent.ValueKind == JsonValueKind.Null ? null : parent.GetInt64();
                            if (parentId < 1) throw new InvalidOperationException("InvalidParentId");
                            result = engine.QueryEvidence(taskId!, p.GetProperty("AfterId").GetInt64(), p.GetProperty("PageSize").GetInt32(), parentId); break;
                        case "Pause": Fields(p); engine.Pause(taskId!); result = new { Accepted = true, State = "PauseRequested" }; break;
                        case "Resume": Fields(p); engine.Resume(taskId!); result = new { Accepted = true }; break;
                        case "Cancel": Fields(p); engine.Cancel(taskId!); result = new { Accepted = true, State = "CancelRequested" }; break;
                        case "ReleaseTask": Fields(p); engine.ReleaseTask(taskId!); result = new { Released = true }; break;
                        default: throw new InvalidOperationException("UnknownOperation");
                    }
                    response = new { ProtocolVersion = Version, RequestId = requestId, TaskId = taskId, Ok = true, Result = result };
                }
                catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException or IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or Microsoft.Data.Sqlite.SqliteException)
                {
                    string code = ex is InvalidOperationException ? ex.Message : ex.GetType().Name;
                    if (code.Length > 100 || code.Any(c => !(char.IsAsciiLetterOrDigit(c) || c == '_'))) code = ex.GetType().Name;
                    Console.Error.WriteLine("Request rejected: " + code);
                    response = new { ProtocolVersion = Version, RequestId = requestId, TaskId = taskId, Ok = false, Error = new { Code = code } };
                }
                var text = JsonSerializer.Serialize(response);
                if (Encoding.UTF8.GetByteCount(text) > MaxResponseBytes)
                    text = JsonSerializer.Serialize(new { ProtocolVersion = Version, RequestId = requestId, TaskId = taskId, Ok = false, Error = new { Code = "ResponseTooLargeReducePageSize" } });
                await replies.Writer.WriteAsync(text);
            }
        }
        finally { replies.Writer.Complete(); await writer; }
    }
    private static void Fields(JsonElement element, params string[] fields)
    {
        if (element.ValueKind != JsonValueKind.Object) throw new InvalidOperationException("ObjectRequired");
        var seen = new HashSet<string>();
        foreach (var p in element.EnumerateObject()) if (!fields.Contains(p.Name, StringComparer.Ordinal) || !seen.Add(p.Name)) throw new InvalidOperationException("UnknownOrDuplicateField");
        if (seen.Count != fields.Length) throw new InvalidOperationException("MissingField");
    }
    private static string Id(JsonElement element)
    {
        var text = element.GetString(); if (!Guid.TryParseExact(text, "D", out var id) || id == Guid.Empty) throw new InvalidOperationException("InvalidId"); return id.ToString("D");
    }
    private static async Task<(string?, bool)> ReadLine(Stream input)
    {
        // Bounded memory even for an attacker-controlled line; drain its suffix.
        var bytes = new byte[MaxMessageBytes]; int used = 0; bool oversized = false; var one = new byte[1];
        while (await input.ReadAsync(one) != 0)
        {
            if (one[0] == 10)
            {
                if (oversized) return (null, true);
                return (Decode(bytes, used), false);
            }
            if (used == bytes.Length) oversized = true; else bytes[used++] = one[0];
        }
        if (oversized) return (null, true);
        return used == 0 ? (null, false) : (Decode(bytes, used), false);
    }
    private static string Decode(byte[] bytes, int used)
    {
        try { return new UTF8Encoding(false, true).GetString(bytes, 0, used); }
        catch (DecoderFallbackException) { return "!invalid-utf8"; }
    }
}
