using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace Cliphoard.Windows;
internal static partial class MacHistoryArchive
{
    private sealed class BoundedArchiveMemory(int maximum) : MemoryStream
    {
        public override void Write(byte[] bytes, int offset, int count) { if (Length + count > maximum) throw Invalid(); base.Write(bytes, offset, count); }
        public override void Write(ReadOnlySpan<byte> bytes) { if (Length + bytes.Length > maximum) throw Invalid(); base.Write(bytes); }
    }
    internal static HistoryState Snapshot(HistoryState source)
    {
        byte[] settings = JsonSerializer.SerializeToUtf8Bytes(source, HistoryDatabase.MetadataOptions);
        HistoryState state;
        try { state = JsonSerializer.Deserialize<HistoryState>(settings, HistoryDatabase.MetadataOptions) ?? throw Invalid(); }
        finally { CryptographicOperations.ZeroMemory(settings); }
        foreach (HistoryItem item in source.Items)
        {
            byte[] clear = JsonSerializer.SerializeToUtf8Bytes(item, HistoryDatabase.MetadataOptions);
            HistoryItem copy;
            try { copy = JsonSerializer.Deserialize<HistoryItem>(clear, HistoryDatabase.MetadataOptions) ?? throw Invalid(); }
            finally { CryptographicOperations.ZeroMemory(clear); }
            if (item.PayloadLength != 0)
            {
                Func<byte[]?> loader = item.PayloadLoader ?? throw new IOException("Save the pending payload before exporting.");
                copy.AttachPayload(loader, item.PayloadLength, item.PayloadDigest);
            }
            state.Items.Add(copy);
        }
        return state;
    }
    internal static async Task SealFileAsync(HistoryState state, string passphrase, string destination, CancellationToken cancellation = default, Action<string>? publish = null)
    {
        if (File.Exists(destination) && (File.GetAttributes(destination) & FileAttributes.ReparsePoint) != 0) throw Invalid();
        string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous))
            {
                await SealToStreamAsync(state, passphrase, output, cancellation); output.Flush(true);
            }
            cancellation.ThrowIfCancellationRequested();
            if (publish is not null) publish(temporary);
            else { if (File.Exists(destination) && (File.GetAttributes(destination) & FileAttributes.ReparsePoint) != 0) throw Invalid(); File.Move(temporary, destination, true); }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    internal static async Task SealToStreamAsync(HistoryState state, string passphrase, Stream destination, CancellationToken cancellation = default)
    {
        HistoryStore.ValidateState(state);
        if (state.Items.Select(item => Guid.Parse(item.Id)).Distinct().Count() != state.Items.Count) throw Invalid();
        var payloads = new Dictionary<string, (HistoryItem Item, int Size)>();
        var imageNames = new Dictionary<string, string>(StringComparer.Ordinal);
        int features = 0, dismissals = 0; long payloadBytes = 0;
        var kinds = new Dictionary<string, int>();
        foreach (HistoryItem item in state.Items)
        {
            cancellation.ThrowIfCancellationRequested(); string kind = Kind(item); kinds[kind] = kinds.GetValueOrDefault(kind) + 1;
            MacArchiveRecord[] extras = ExtrasFor(item); features = checked(features + extras.Count(record => record.Type == 3)); dismissals = checked(dismissals + extras.Count(record => record.Type == 4));
            if (item.Kind != "Image") continue;
            byte[] png = await ImageAnalysis.PngAsync(item, cancellation);
            try
            {
                string name = Convert.ToHexString(SHA256.HashData(png)).ToLowerInvariant() + ".png"; imageNames.Add(item.Id, name);
                if (payloads.TryAdd(name, (item, png.Length))) payloadBytes += png.LongLength;
            }
            finally { CryptographicOperations.ZeroMemory(png); }
        }
        double[] dates = state.Items.Select(item => (item.Captured - ReferenceDate).TotalSeconds).ToArray();
        var summary = new JsonObject
        {
            ["format"] = "cliphoard-archive", ["version"] = 1, ["appVersion"] = "1.2.0-windows", ["exportedAt"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"), ["machineName"] = "Windows",
            ["clipCount"] = state.Items.Count, ["byKind"] = JsonSerializer.SerializeToNode(kinds), ["pinnedCount"] = state.Items.Count(item => item.Pinned), ["oldestCreatedAt"] = dates.Length == 0 ? 0 : dates.Min(), ["newestCreatedAt"] = dates.Length == 0 ? 0 : dates.Max(),
            ["payloadCount"] = payloads.Count, ["payloadBytes"] = payloadBytes, ["imageFeatureCount"] = features, ["dismissalCount"] = dismissals, ["embeddingsIncluded"] = false, ["imageFeaturesIncluded"] = true, ["skippedUnreadableClips"] = 0, ["skippedUnreadablePayloads"] = 0
        };
        using var writer = new ChunkWriter(destination, summary, passphrase, cancellation);
        WriteClearRecord(writer, 1, "manifest.json", summary);
        foreach (HistoryItem item in state.Items)
        {
            cancellation.ThrowIfCancellationRequested(); JsonObject clip = EncodeClip(item, imageNames.GetValueOrDefault(item.Id)); WriteClearRecord(writer, 2, clip["id"]!.GetValue<string>(), clip);
            foreach (MacArchiveRecord extra in ExtrasFor(item)) WriteRecord(writer, extra.Type, extra.Name, extra.Body);
        }
        foreach ((string name, var value) in payloads)
        {
            cancellation.ThrowIfCancellationRequested(); byte[] png = await ImageAnalysis.PngAsync(value.Item, cancellation);
            try { if (png.Length != value.Size || Convert.ToHexString(SHA256.HashData(png)).ToLowerInvariant() + ".png" != name) throw Invalid(); WriteRecord(writer, 5, name, png); }
            finally { CryptographicOperations.ZeroMemory(png); }
        }
        int padding = (int)((ChunkSize - (writer.Written + 22) % ChunkSize) % ChunkSize);
        WriteRecord(writer, 6, "", new byte[padding]); WriteRecord(writer, 255, "", Array.Empty<byte>()); writer.Finish();
    }
    private static string Kind(HistoryItem item) => item.Kind switch { "Text" or "Code" => "text", "Link" => "link", "Color" => "color", "Image" => "image", "Files" => "file", _ => throw Invalid() };
    private static JsonObject EncodeClip(HistoryItem item, string? imageName)
    {
        JsonObject clip = item.MacMetadata is string metadata ? JsonNode.Parse(metadata) as JsonObject ?? throw Invalid() : new();
        clip["id"] = Guid.Parse(item.Id).ToString("D").ToUpperInvariant(); clip["kind"] = Kind(item); clip["text"] = item.Text; clip["createdAt"] = (item.Captured - ReferenceDate).TotalSeconds; clip["lastUsedAt"] = ((item.LastUsed ?? item.Captured) - ReferenceDate).TotalSeconds;
        clip["sourceApp"] = item.Source; clip["pinned"] = item.Pinned; clip["useCount"] = item.UseCount; clip["shape"] = item.Shape; clip["flags"] = unchecked((ulong)item.Flags); clip["userTags"] = JsonSerializer.SerializeToNode(item.Tags);
        clip["windowsKind"] = item.Kind == "Code" ? "Code" : null; clip["ocrText"] = item.Kind == "Files" ? item.DocumentText : item.OcrText;
        clip["windowsDocumentText"] = item.DocumentText; clip["windowsDocumentTruncated"] = item.DocumentTruncated; clip["windowsTranscript"] = item.Transcript;
        clip["rtfB64"] = item.RichText is null ? null : Convert.ToBase64String(item.RichText); clip["windowsHtmlB64"] = item.Html is null ? null : Convert.ToBase64String(item.Html);
        clip["payloadFile"] = imageName;
        if (item.Kind == "Files") { clip["filePath"] = item.Text.Split('\n')[0].TrimEnd('\r'); clip["windowsFilePaths"] = item.Text; }
        if (item.Kind == "Color") clip["colorHex"] = item.Text.Trim();
        return clip;
    }
    private static MacArchiveRecord[] ExtrasFor(HistoryItem item)
    {
        string id = Guid.Parse(item.Id).ToString("D").ToUpperInvariant();
        IEnumerable<string> legacy = item.MacRecords.Where(record => record.Type == 4).Select(record => JsonNode.Parse(record.Body)!["tag"]!.GetValue<string>());
        return item.MacRecords.Where(record => record.Type == 3).Select(record => new MacArchiveRecord { Type = 3, Name = id, Body = record.Body })
            .Concat(item.DismissedSuggestions.Concat(legacy).Distinct(StringComparer.Ordinal).Select(tag => new MacArchiveRecord { Type = 4, Name = id, Body = JsonSerializer.SerializeToUtf8Bytes(new { tag }) })).ToArray();
    }
    private static void WriteClearRecord(Stream output, byte type, string name, JsonObject value)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        try { if (bytes.Length > 64 * 1024 * 1024) throw Invalid(); WriteRecord(output, type, name, bytes); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
}
