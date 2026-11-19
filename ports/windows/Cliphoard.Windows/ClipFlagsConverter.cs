using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
namespace Cliphoard.Windows;
internal sealed class ClipFlagsConverter : JsonConverter<long>
{
    public override long Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.Number) throw new JsonException("Invalid clip flags.");
        if (reader.TryGetInt64(out long signed)) return signed;
        if (reader.TryGetUInt64(out ulong unsigned)) return unchecked((long)unsigned);
        throw new JsonException("Invalid clip flags.");
    }
    public override void Write(Utf8JsonWriter writer, long value, JsonSerializerOptions options) => writer.WriteNumberValue(unchecked((ulong)value));
    internal static long FromNode(JsonNode? node)
    {
        if (node is null) return 0;
        if (node is JsonValue value)
        {
            if (value.TryGetValue<long>(out long signed)) return signed;
            if (value.TryGetValue<ulong>(out ulong unsigned)) return unchecked((long)unsigned);
        }
        throw new IOException("Invalid clip flags.");
    }
}
