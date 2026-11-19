using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cliphoard.Windows;

internal sealed class MacArchiveRecord
{
    public byte Type { get; set; }
    public string Name { get; set; } = "";
    public byte[] Body { get; set; } = Array.Empty<byte>();
}

/// Version-one CLIPHRD1 interoperability, including the Mac HKDF expansion and chunk AAD.
/// Parsing and authentication finish before the caller can commit any imported clips.
internal static partial class MacHistoryArchive
{
    private const int HeaderSize = 48, SummarySize = 1024, Maximum = 48 * 1024 * 1024, ChunkSize = 1048576;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly DateTimeOffset ReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private static IOException Invalid() => new("The Cliphoard archive is malformed, unsupported or exceeds the Windows history limits.");
    private static byte[] Derive(string passphrase, ReadOnlySpan<byte> salt, int rounds)
    {
        if (new System.Globalization.StringInfo(passphrase).LengthInTextElements < 12 || passphrase.Length > 1024) throw new ArgumentException("Use at least 12 characters.");
        byte[] password = Utf8.GetBytes(passphrase.Normalize(NormalizationForm.FormC));
        byte[] master = Rfc2898DeriveBytes.Pbkdf2(password, salt, rounds, HashAlgorithmName.SHA256, 32);
        try
        {
            // One HKDF-Expand block. The PBKDF2 result is already the PRK in the Mac format.
            return HMACSHA256.HashData(master, "cliphoard/export/v1/file-key\u0001"u8);
        }
        finally { CryptographicOperations.ZeroMemory(password); CryptographicOperations.ZeroMemory(master); }
    }
    private static byte[] Nonce(byte[] header, ulong index)
    {
        var nonce = new byte[12]; header.AsSpan(32, 4).CopyTo(nonce);
        BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), index); return nonce;
    }
    private static byte[] Aad(byte[] header, ulong index, byte final, int length)
    {
        var aad = new byte[61]; header.CopyTo(aad, 0);
        BinaryPrimitives.WriteUInt64BigEndian(aad.AsSpan(48), index); aad[56] = final;
        BinaryPrimitives.WriteInt32BigEndian(aad.AsSpan(57), length); return aad;
    }
    internal static HistoryState Open(byte[] envelope, string passphrase)
    {
        if (envelope.Length < HeaderSize + SummarySize + 16 || envelope.Length > Maximum) throw Invalid();
        byte[] header = envelope[..HeaderSize];
        int rounds = BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(12));
        int chunkSize = BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(36));
        if (!header.AsSpan(0, 8).SequenceEqual("CLIPHRD1"u8) || BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(8)) != 1 || header[10] != 1 || header[11] != 1 || rounds is < 600000 or > 10000000 || chunkSize is < 65536 or > 8388608 || BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(40)) != 1040 || BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(44)) != 0) throw Invalid();
        byte[] key = Derive(passphrase, header.AsSpan(16, 16), rounds);
        byte[] summaryBytes = new byte[SummarySize];
        using var clear = new MemoryStream();
        try
        {
            using var cipher = new AesGcm(key, 16);
            cipher.Decrypt(Nonce(header, 0), envelope.AsSpan(48, 1024), envelope.AsSpan(1072, 16), summaryBytes, header);
            int summaryLength = Array.FindLastIndex(summaryBytes, b => b != 0) + 1;
            var summary = JsonNode.Parse(summaryBytes.AsSpan(0, summaryLength)) as JsonObject ?? throw Invalid();
            if (summary["format"]?.GetValue<string>() != "cliphoard-archive" || summary["version"]?.GetValue<int>() != 1) throw Invalid();
            int offset = 1088;
            ulong index = 0;
            byte final = 0;
            while (final == 0)
            {
                if (envelope.Length - offset < 21) throw Invalid();
                int length = BinaryPrimitives.ReadInt32BigEndian(envelope.AsSpan(offset));
                final = envelope[offset + 4];
                if (length <= 0 || length > chunkSize || final > 1 || envelope.Length - offset - 21 < length || clear.Length + length > Maximum) throw Invalid();
                byte[] block = new byte[length];
                try
                {
                    cipher.Decrypt(Nonce(header, ++index), envelope.AsSpan(offset + 5, length), envelope.AsSpan(offset + 5 + length, 16), block, Aad(header, index, final, length));
                    clear.Write(block);
                }
                finally { CryptographicOperations.ZeroMemory(block); }
                offset += length + 21;
            }
            if (offset != envelope.Length) throw Invalid();
            return ReadRecords(clear.GetBuffer().AsSpan(0, (int)clear.Length), summary);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(summaryBytes);
            CryptographicOperations.ZeroMemory(clear.GetBuffer());
        }
    }
    private static HistoryState ReadRecords(ReadOnlySpan<byte> bytes, JsonObject summary)
    {
        var clips = new Dictionary<string, JsonObject>(StringComparer.OrdinalIgnoreCase);
        var payloads = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        var extras = new List<MacArchiveRecord>();
        bool manifest = false, ended = false;
        int offset = 0, payloadBytes = 0;
        while (offset < bytes.Length)
        {
            if (bytes.Length - offset < 11) throw Invalid();
            byte type = bytes[offset++];
            int nameLength = BinaryPrimitives.ReadUInt16BigEndian(bytes[offset..]); offset += 2;
            if (nameLength > bytes.Length - offset - 8) throw Invalid();
            string name = Utf8.GetString(bytes.Slice(offset, nameLength)); offset += nameLength;
            ulong bodySize = BinaryPrimitives.ReadUInt64BigEndian(bytes[offset..]); offset += 8;
            if (bodySize > (ulong)(bytes.Length - offset) || bodySize > Maximum) throw Invalid();
            var body = bytes.Slice(offset, (int)bodySize); offset += (int)bodySize;
            switch (type)
            {
                case 1:
                    if (manifest || name != "manifest.json" || !JsonNode.DeepEquals(JsonNode.Parse(body), summary)) throw Invalid();
                    manifest = true; break;
                case 2:
                    if (!Guid.TryParse(name, out _)) throw Invalid();
                    var clip = JsonNode.Parse(body) as JsonObject ?? throw Invalid();
                    if (!string.Equals(clip["id"]?.GetValue<string>(), name, StringComparison.OrdinalIgnoreCase) || !clips.TryAdd(name, clip)) throw Invalid();
                    break;
                case 3:
                case 4:
                    if (!Guid.TryParse(name, out _) || body.Length > 1024 * 1024 || extras.Count >= 1000000) throw Invalid();
                    var supplementary = new MacArchiveRecord { Type = type, Name = name, Body = body.ToArray() };
                    ValidateSupplementary(supplementary);
                    extras.Add(supplementary); break;
                case 5:
                    if (body.Length > 8 * 1024 * 1024 || name != Convert.ToHexString(SHA256.HashData(body)).ToLowerInvariant() + ".png" || !ClipboardContent.IsPng(body.ToArray()) || !payloads.TryAdd(name, body.ToArray())) throw Invalid();
                    payloadBytes += body.Length; break;
                case 6:
                    if (name.Length != 0 || body.IndexOfAnyExcept((byte)0) >= 0) throw Invalid();
                    break;
                case 255:
                    if (name.Length != 0 || body.Length != 0 || offset != bytes.Length) throw Invalid();
                    ended = true; break;
                default: throw Invalid();
            }
        }
        if (!manifest || !ended || summary["clipCount"]?.GetValue<int>() != clips.Count || summary["payloadCount"]?.GetValue<int>() != payloads.Count || summary["payloadBytes"]?.GetValue<int>() != payloadBytes || summary["imageFeatureCount"]?.GetValue<int>() != extras.Count(r => r.Type == 3) || summary["dismissalCount"]?.GetValue<int>() != extras.Count(r => r.Type == 4) || extras.Any(r => !clips.ContainsKey(r.Name))) throw Invalid();
        var state = new HistoryState { Limit = 0 };
        var byKind = new Dictionary<string, int>();
        foreach ((string id, JsonObject clip) in clips)
        {
            string kind = clip["kind"]?.GetValue<string>() ?? throw Invalid();
            byKind[kind] = byKind.GetValueOrDefault(kind) + 1;
            HistoryItem item = DecodeClip(id, clip, extras.Where(record => record.Name.Equals(id, StringComparison.OrdinalIgnoreCase)).ToArray(), name => payloads.GetValueOrDefault(name));
            state.Items.Add(item);
        }
        if (!JsonNode.DeepEquals(JsonSerializer.SerializeToNode(byKind), summary["byKind"]) || summary["pinnedCount"]?.GetValue<int>() != state.Items.Count(i => i.Pinned)) throw Invalid();
        HistoryStore.ValidateState(state);
        return state;
    }
    private static HistoryItem DecodeClip(string id, JsonObject clip, IReadOnlyList<MacArchiveRecord> extras, Func<string, byte[]?> payload)
    {
        string kind = clip["kind"]?.GetValue<string>() ?? throw Invalid();
        var item = new HistoryItem
        {
            Id = id, Text = clip["text"]?.GetValue<string>() ?? "",
            Kind = kind switch { "text" => "Text", "link" => "Link", "color" => "Color", "image" => "Image", "file" => "Files", _ => throw Invalid() },
            Source = clip["sourceApp"]?.GetValue<string>() ?? "Mac",
            Pinned = clip["pinned"]?.GetValue<bool>() ?? false,
            Captured = ReferenceDate.AddSeconds(clip["createdAt"]?.GetValue<double>() ?? 0),
            LastUsed = clip["lastUsedAt"] is JsonNode used ? ReferenceDate.AddSeconds(used.GetValue<double>()) : null,
            UseCount = clip["useCount"]?.GetValue<int>() ?? 0, Shape = clip["shape"]?.GetValue<string>(),
            Tags = clip["userTags"]?.Deserialize<List<string>>() ?? new(),
            Flags = ClipFlagsConverter.FromNode(clip["flags"]),
            OcrText = clip["ocrText"]?.GetValue<string>(), DocumentText = clip["windowsDocumentText"]?.GetValue<string>(), DocumentTruncated = clip["windowsDocumentTruncated"]?.GetValue<bool>() ?? false, Transcript = clip["windowsTranscript"]?.GetValue<string>(),
            MacMetadata = clip.ToJsonString(),
            DismissedSuggestions = extras.Where(record => record.Type == 4 && record.Name.Equals(id, StringComparison.OrdinalIgnoreCase)).Select(record => JsonNode.Parse(record.Body)!["tag"]!.GetValue<string>()).Distinct().ToList(),
            MacRecords = extras.Where(r => r.Name.Equals(id, StringComparison.OrdinalIgnoreCase)).ToList()
        };
        if (clip["rtfB64"]?.GetValue<string>() is string rtf) item.RichText = Convert.FromBase64String(rtf);
        if (clip["windowsHtmlB64"]?.GetValue<string>() is string html) item.Html = Convert.FromBase64String(html);
        if (item.Kind == "Image")
        {
            string name = clip["payloadFile"]?.GetValue<string>() ?? throw Invalid();
            item.Payload = payload(name) ?? throw Invalid(); item.Format = 0;
            if (item.Text.Length == 0) item.Text = $"{BinaryPrimitives.ReadUInt32BigEndian(item.Payload.AsSpan(16))} × {BinaryPrimitives.ReadUInt32BigEndian(item.Payload.AsSpan(20))} pixels";
        }
        else if (item.Kind == "Files")
        {
            item.Text = clip["windowsFilePaths"]?.GetValue<string>() ?? clip["filePath"]?.GetValue<string>() ?? throw Invalid();
            item.DocumentText ??= item.OcrText; item.OcrText = null;
            item.Payload = FileDrop(item.Text); item.Format = 15;
        }
        else if (item.Kind == "Color") item.Text = clip["colorHex"]?.GetValue<string>() ?? item.Text;
        else if (item.Kind == "Text" && clip["windowsKind"]?.GetValue<string>() == "Code") item.Kind = "Code";
        item.Flags |= ContentSafety.Flags(item.Text + "\n" + item.OcrText + "\n" + item.Transcript + "\n" + item.DocumentText);
        clip.Remove("windowsTranscript"); clip.Remove("rtfB64"); clip.Remove("windowsHtmlB64"); clip.Remove("windowsFilePaths");
        item.MacMetadata = clip.ToJsonString();
        return item;
    }
    internal static void ValidateSupplementary(MacArchiveRecord record)
    {
        using var document = JsonDocument.Parse(record.Body);
        if (record.Type == 3)
        {
            if (document.RootElement.GetProperty("revision").GetInt64() < 0) throw Invalid();
            byte[] vector = Convert.FromBase64String(document.RootElement.GetProperty("vectorB64").GetString() ?? throw Invalid());
            if (vector.Length == 0 || vector.Length % 4 != 0) throw Invalid();
            for (int offset = 0; offset < vector.Length; offset += 4)
                if (!float.IsFinite(BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(vector.AsSpan(offset))))) throw Invalid();
        }
        else
        {
            string tag = document.RootElement.GetProperty("tag").GetString() ?? throw Invalid();
            if (tag.Length > 1024 || tag.Contains('\0')) throw Invalid();
        }
    }
    private static byte[] FileDrop(string paths)
    {
        byte[] names = Encoding.Unicode.GetBytes(string.Join('\0', paths.Split('\n').Select(s => s.TrimEnd('\r'))) + "\0\0");
        var bytes = new byte[20 + names.Length]; BinaryPrimitives.WriteInt32LittleEndian(bytes, 20); bytes[16] = 1; names.CopyTo(bytes, 20); return bytes;
    }
    internal static async Task<byte[]> SealAsync(HistoryState state, string passphrase, CancellationToken cancellation = default)
    {
        using var output = new BoundedArchiveMemory(Maximum);
        await SealToStreamAsync(state, passphrase, output, cancellation);
        return output.ToArray();
    }
    private static void WriteRecord(Stream stream, byte type, string name, byte[] body)
    {
        byte[] nameBytes = Utf8.GetBytes(name), header = new byte[3]; header[0] = type;
        BinaryPrimitives.WriteUInt16BigEndian(header.AsSpan(1), checked((ushort)nameBytes.Length)); stream.Write(header); stream.Write(nameBytes);
        var length = new byte[8]; BinaryPrimitives.WriteUInt64BigEndian(length, (ulong)body.Length); stream.Write(length); stream.Write(body);
    }
}
