using System.Security.Cryptography;
using System.Text.Json;

namespace SafeJunkCleaner.Explorer;

// Session-authenticated opaque pagination. The cursor is never a path, an ID offset
// chosen by the client, or authority to expand a candidate set.
public sealed class OpaqueCursorCodec
{
    public const int MaximumLength = 2048;
    public const int SchemaVersion = 1;
    private readonly byte[] key = RandomNumberGenerator.GetBytes(32);
    private sealed record Cursor(int Schema, string Task, long Revision, string Analysis, string Sort, string Partition, int Offset);
    public string Encode(string task, long revision, string analysis, string sort, string partition, int offset)
    {
        if (offset < 1) throw new InvalidOperationException("InvalidCursor");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new Cursor(SchemaVersion, task, revision, analysis, sort, partition, offset));
        var signature = HMACSHA256.HashData(key, bytes);
        return Base64(bytes.Concat(signature).ToArray());
    }
    public int Decode(string? cursor, string task, long revision, string analysis, string sort, string partition)
    {
        if (cursor == null) return 0;
        try
        {
            if (cursor.Length is < 1 or > MaximumLength || cursor.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('-' or '_'))) throw new InvalidOperationException("InvalidCursor");
            string encoded = cursor.Replace('-', '+').Replace('_', '/');
            var bytes = Convert.FromBase64String(encoded.PadRight((encoded.Length + 3) / 4 * 4, '='));
            if (bytes.Length <= 32 || Base64(bytes) != cursor) throw new InvalidOperationException("InvalidCursor");
            var body = bytes.AsSpan(0, bytes.Length - 32);
            if (!CryptographicOperations.FixedTimeEquals(HMACSHA256.HashData(key, body), bytes.AsSpan(bytes.Length - 32))) throw new InvalidOperationException("InvalidCursor");
            var value = JsonSerializer.Deserialize<Cursor>(body) ?? throw new InvalidOperationException("InvalidCursor");
            if (value.Schema != SchemaVersion || value.Task != task || value.Revision != revision || value.Analysis != analysis || value.Sort != sort || value.Partition != partition || value.Offset < 1) throw new InvalidOperationException("CursorContextChanged");
            return value.Offset;
        }
        catch (Exception ex) when (ex is FormatException or JsonException or ArgumentException) { throw new InvalidOperationException("InvalidCursor"); }
    }
    private static string Base64(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
