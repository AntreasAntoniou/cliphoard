using System.Text;
using System.Text.Json;

namespace Cliphoard.Companion;
internal sealed record SharedClip(string Id, string Kind, string Text);
internal sealed class AgentConnection : IDisposable
{
    private readonly object gate = new();
    private BrokerProcess? reader, writer;
    private long generation, readerDeadline;
    private SharedClip[] shared = Array.Empty<SharedClip>();
    private readonly Dictionary<string, string> unresolved = new(StringComparer.Ordinal);
    private readonly Dictionary<string, SharedClip> saved = new(StringComparer.Ordinal);
    private readonly Queue<string> savedOrder = new();
    private readonly SemaphoreSlim saves = new(1);
    internal async Task<object> ConnectAsync(bool writing, CancellationToken cancellation)
    {
        BrokerProcess child; long current;
        lock (gate)
        {
            if (writing ? writer is not null : reader is not null || readerDeadline > Environment.TickCount64) throw new IOException("Disconnect the existing connection before connecting again.");
            child = new BrokerProcess(writing); current = generation;
            if (writing) writer = child; else reader = child;
        }
        try
        {
            JsonElement value = await child.ReceiveAsync(writing ? 2048 : 100 * 1024 * 1024, cancellation);
            lock (gate)
            {
                if (generation != current || (writing ? writer : reader) != child) throw new IOException("Connection ended.");
                if (writing)
                {
                    if (value.GetProperty("status").GetString() != "ready") throw new IOException("Writer connection was cancelled or is unavailable.");
                    return value;
                }
                if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > 4096) throw new IOException("Invalid shared export.");
                var clips = new List<SharedClip>(); long bytes = 0;
                foreach (JsonElement item in value.EnumerateArray())
                {
                    string id = item.GetProperty("id").GetString() ?? "", kind = item.GetProperty("kind").GetString() ?? "", text = item.GetProperty("text").GetString() ?? "";
                    int size = Encoding.UTF8.GetByteCount(text); bytes += size;
                    if (!Guid.TryParseExact(id, "D", out _) || kind is not ("text" or "link" or "color") || size is 0 or > 65536 || bytes > 16 * 1024 * 1024) throw new IOException("Invalid shared export.");
                    clips.Add(new(id, kind, text));
                }
                shared = clips.ToArray(); readerDeadline = Environment.TickCount64 + 900000; reader = null; child.Dispose();
                return new { status = "connected", clips = shared.Length, expires_in_seconds = 900 };
            }
        }
        catch
        {
            lock (gate) { if (writer == child) writer = null; if (reader == child) reader = null; child.Dispose(); }
            throw;
        }
    }
    internal async Task<object> SaveAsync(string text, CancellationToken cancellation)
    {
        if (string.IsNullOrWhiteSpace(text) || Encoding.UTF8.GetByteCount(text) > 32768) throw new ArgumentException("A note must contain 1–32768 UTF-8 bytes.");
        await saves.WaitAsync(cancellation);
        try
        {
            BrokerProcess child; string id = Guid.NewGuid().ToString("D"); long current;
            lock (gate)
            {
                child = writer ?? throw new IOException("Connect the writer first."); current = generation;
                if (unresolved.Count >= 32) throw new IOException("Check unresolved saves before submitting more notes.");
                unresolved.Add(id, text);
            }
            try
            {
                JsonElement result = await child.CommandAsync(new { action = "write", request_id = id, text }, cancellation);
                for (int attempt = 0; attempt < 40 && result.GetProperty("status").GetString() == "pending"; ++attempt)
                {
                    await Task.Delay(500, cancellation);
                    result = await child.CommandAsync(new { action = "check", request_id = id }, cancellation);
                }
                return Complete(child, current, id, result);
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or JsonException or InvalidOperationException)
            {
                return new { status = "unknown", request_id = id, message = "Use check_save with this request_id. Do not resubmit the note." };
            }
        }
        finally { saves.Release(); }
    }
    internal async Task<object> CheckAsync(string id, CancellationToken cancellation)
    {
        if (!Guid.TryParseExact(id, "D", out Guid parsed)) throw new ArgumentException("Use the original request_id."); id = parsed.ToString("D");
        BrokerProcess child; long current;
        lock (gate)
        {
            child = writer ?? throw new IOException("The original writer connection has ended."); current = generation;
            if (saved.ContainsKey(id)) return new { status = "saved", request_id = id, clip_id = id };
            if (!unresolved.ContainsKey(id)) throw new ArgumentException("Unknown request_id for this connection.");
        }
        return Complete(child, current, id, await child.CommandAsync(new { action = "check", request_id = id }, cancellation));
    }
    private object Complete(BrokerProcess child, long current, string id, JsonElement result)
    {
        lock (gate)
        {
            if (generation != current || writer != child) throw new IOException("The original writer connection has ended.");
            if (result.GetProperty("request_id").GetString() != id) throw new IOException("Receipt identity changed.");
            string status = result.GetProperty("status").GetString() ?? "unknown";
            if (status == "saved" && unresolved.TryGetValue(id, out string? text))
            {
                saved[id] = new(id, "text", text); savedOrder.Enqueue(id);
                while (savedOrder.Count > 32) saved.Remove(savedOrder.Dequeue());
            }
            if (status is "saved" or "rejected" or "expired") unresolved.Remove(id);
            return result;
        }
    }
    private SharedClip[] Snapshot()
    {
        lock (gate)
        {
            if (readerDeadline != 0 && Environment.TickCount64 >= readerDeadline) { shared = Array.Empty<SharedClip>(); readerDeadline = 0; }
            return shared.Concat(saved.Values).DistinctBy(clip => clip.Id).ToArray();
        }
    }
    internal object Search(string query, int limit)
    {
        if (query.Length is < 1 or > 256 || limit is < 1 or > 25) throw new ArgumentException("Use a query of 1–256 characters and a limit of 1–25.");
        string[] terms = query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (terms.Length == 0) throw new ArgumentException("Enter a search query.");
        return Snapshot().Where(clip => terms.All(term => clip.Text.Contains(term, StringComparison.OrdinalIgnoreCase))).Take(limit).Select(clip => new { id = clip.Id, kind = clip.Kind, preview = Slice(clip.Text, 0, 160), untrusted_data = true }).ToArray();
    }
    internal object Get(string id, int offset)
    {
        if (offset < 0 || !Guid.TryParseExact(id, "D", out Guid parsed)) throw new ArgumentException("Invalid clip id or offset.");
        SharedClip clip = Snapshot().FirstOrDefault(clip => clip.Id == parsed.ToString("D")) ?? throw new ArgumentException("Clip unavailable in this connection.");
        int total = clip.Text.EnumerateRunes().Count();
        if (offset > total) throw new ArgumentException("Offset exceeds the clip length.");
        return new { id = clip.Id, kind = clip.Kind, text = Slice(clip.Text, offset, 4000), next_offset = offset + 4000 < total ? (int?)(offset + 4000) : null, untrusted_data = true };
    }
    private static string Slice(string text, int offset, int count) => string.Concat(text.EnumerateRunes().Skip(offset).Take(count).Select(rune => rune.ToString()));
    internal object Disconnect()
    {
        lock (gate)
        {
            ++generation; reader?.Dispose(); writer?.Dispose(); reader = null; writer = null;
            shared = Array.Empty<SharedClip>(); readerDeadline = 0; unresolved.Clear(); saved.Clear(); savedOrder.Clear();
            return new { status = "disconnected" };
        }
    }
    public void Dispose() => Disconnect();
}
