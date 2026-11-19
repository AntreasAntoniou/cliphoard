using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace Cliphoard.Windows;
internal static partial class MacHistoryArchive
{
    internal static MacArchiveStage OpenFile(string path, string passphrase, CancellationToken cancellation = default, IProgress<int>? progress = null)
    {
        using var file = LocalFileLease.Open(path, long.MaxValue); return OpenStaged(file, passphrase, cancellation, progress);
    }
    internal static MacArchiveStage OpenStaged(Stream input, string passphrase, CancellationToken cancellation = default, IProgress<int>? progress = null)
    {
        using var reader = new ChunkReader(input, passphrase, cancellation);
        var stage = new MacArchiveStage();
        try
        {
            int clips = 0, payloads = 0, features = 0, dismissals = 0; long payloadBytes = 0; bool manifest = false, ended = false;
            while (!ended)
            {
                cancellation.ThrowIfCancellationRequested();
                byte[] head = new byte[3]; reader.ReadExactly(head); byte type = head[0];
                int nameLength = BinaryPrimitives.ReadUInt16BigEndian(head.AsSpan(1)); if (nameLength > 4096) throw Invalid();
                byte[] nameBytes = new byte[nameLength]; reader.ReadExactly(nameBytes); string name = Utf8.GetString(nameBytes);
                byte[] lengthBytes = new byte[8]; reader.ReadExactly(lengthBytes); ulong size = BinaryPrimitives.ReadUInt64BigEndian(lengthBytes);
                if (size > 64 * 1024 * 1024 || type is 3 or 4 && size > 1024 * 1024 || type == 5 && size > 8 * 1024 * 1024) throw Invalid();
                byte[] body = new byte[(int)size];
                try
                {
                    reader.ReadExactly(body);
                    switch (type)
                    {
                        case 1:
                            if (manifest || name != "manifest.json" || !JsonNode.DeepEquals(JsonNode.Parse(body), reader.Summary)) throw Invalid(); manifest = true; break;
                        case 2:
                            if (!Guid.TryParse(name, out _) || JsonNode.Parse(body) is not JsonObject clip || !string.Equals(clip["id"]?.GetValue<string>(), name, StringComparison.OrdinalIgnoreCase)) throw Invalid();
                            stage.Add(type, name, body); ++clips; progress?.Report(clips); break;
                        case 3:
                        case 4:
                            if (!Guid.TryParse(name, out _)) throw Invalid(); ValidateSupplementary(new() { Type = type, Name = name, Body = body }); stage.Add(type, name, body);
                            if (type == 3) ++features; else ++dismissals; break;
                        case 5:
                            if (!ClipboardContent.IsPng(body) || name != Convert.ToHexString(SHA256.HashData(body)).ToLowerInvariant() + ".png") throw Invalid();
                            stage.Add(type, name, body); ++payloads; payloadBytes += body.LongLength; break;
                        case 6:
                            if (name.Length != 0 || body.AsSpan().IndexOfAnyExcept((byte)0) >= 0) throw Invalid(); break;
                        case 255:
                            if (name.Length != 0 || body.Length != 0) throw Invalid(); reader.VerifyEnd(); ended = true; break;
                        default: throw Invalid();
                    }
                }
                finally { CryptographicOperations.ZeroMemory(body); }
            }
            JsonObject summary = reader.Summary;
            if (!manifest || !ended || summary["clipCount"]?.GetValue<int>() != clips || summary["payloadCount"]?.GetValue<int>() != payloads || summary["payloadBytes"]?.GetValue<long>() != payloadBytes || summary["imageFeatureCount"]?.GetValue<int>() != features || summary["dismissalCount"]?.GetValue<int>() != dismissals || stage.HasOrphanExtras()) throw Invalid();
            var kinds = new Dictionary<string, int>();
            foreach ((string id, byte[] bytes) in stage.Clips())
            {
                cancellation.ThrowIfCancellationRequested();
                try
                {
                    JsonObject clip = JsonNode.Parse(bytes) as JsonObject ?? throw Invalid(); string kind = clip["kind"]?.GetValue<string>() ?? throw Invalid(); kinds[kind] = kinds.GetValueOrDefault(kind) + 1;
                    HistoryItem item = DecodeClip(id, clip, stage.Extras(id), stage.Payload);
                    HistoryStore.ValidateState(new() { Limit = 0, Items = new() { item } });
                    if (item.Kind == "Image") stage.Attach(item, clip["payloadFile"]!.GetValue<string>());
                    stage.State.Items.Add(item);
                }
                finally { CryptographicOperations.ZeroMemory(bytes); }
            }
            if (!JsonNode.DeepEquals(JsonSerializer.SerializeToNode(kinds), summary["byKind"]) || summary["pinnedCount"]?.GetValue<int>() != stage.State.Items.Count(item => item.Pinned)) throw Invalid();
            return stage;
        }
        catch { stage.Dispose(); throw; }
    }
}
