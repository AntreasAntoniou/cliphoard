using System.Security.Cryptography;
namespace Cliphoard.Windows;

/// Keeps receipt keys inside the explicitly connected writer process.
internal sealed class AgentWriterConnection : IDisposable
{
    private readonly AgentWriteDirectory directory;
    private readonly byte[] manifest;
    private readonly Dictionary<string, AgentPrepared> prepared = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> created = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Dictionary<string, string>> completed = new(StringComparer.Ordinal);
    private readonly Queue<string> completionOrder = new();
    private readonly Func<double> now;
    private readonly Func<long> ticks;
    private readonly long? deadline;
    private bool closed;
    internal AgentSession Session { get; }
    internal AgentWriterConnection(string folder, Func<double>? now = null, Func<long>? ticks = null)
    {
        this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0); this.ticks = ticks ?? (() => Environment.TickCount64);
        directory = new(folder);
        try
        {
            manifest = directory.Read("session.json", 1024) ?? throw new IOException("Agent session is unavailable.");
            Session = AgentWriteProtocol.DecodeSession(manifest, this.now());
            deadline = Session.ExpiresAt is double expiry ? this.ticks() + (long)(Math.Min(900, expiry - this.now()) * 1000) : null;
            Validate();
        }
        catch { directory.Dispose(); throw; }
    }
    internal void Validate()
    {
        if (closed || deadline is long end && ticks() >= end) throw new IOException("Agent connection has ended.");
        byte[]? current = directory.Read("session.json", 1024);
        if (current is null || !current.AsSpan().SequenceEqual(manifest)) throw new IOException("Agent session changed.");
        AgentWriteProtocol.ValidateSession(Session, now());
        if (Session.Host is AgentHost host && !AgentHostIdentity.IsAlive(host)) throw new IOException("Agent host has exited.");
    }
    internal Dictionary<string, string> Write(Guid id, string text)
    {
        Validate(); string key = id.ToString("D").ToUpperInvariant();
        if (prepared.ContainsKey(key) || completed.ContainsKey(key) || prepared.Count >= 32) throw new IOException("Agent request is unavailable or the pending bound is reached.");
        AgentPrepared value = AgentWriteProtocol.Prepare(new(1, Session.SessionId, key, now(), text), Session, now());
        prepared.Add(key, value); created.Add(key, ticks());
        try { directory.WriteExclusive(Name(key, ".request"), value.Data); return Result("pending", key); }
        catch (IOException) { return Result("unknown", key); }
    }
    internal Dictionary<string, string> Check(Guid id)
    {
        Validate(); string key = id.ToString("D").ToUpperInvariant();
        if (completed.TryGetValue(key, out var cached)) return new(cached, StringComparer.Ordinal);
        if (!prepared.TryGetValue(key, out AgentPrepared? value)) throw new IOException("Agent request is unavailable.");
        byte[]? data = directory.Read(Name(key, ".reply"), 2048);
        if (data is null) return Result(ticks() - created[key] < 120000 ? "pending" : "unknown", key);
        AgentReceipt receipt = AgentWriteProtocol.OpenReceipt(data, value, Session.SessionId, key);
        var response = Result(receipt.Status, key);
        if (receipt.ClipId is string clip) response["clip_id"] = clip.ToLowerInvariant();
        if (receipt.Status != "unavailable")
        {
            Cleanup(key, value); prepared.Remove(key); created.Remove(key); value.Dispose();
            completed[key] = response; completionOrder.Enqueue(key);
            while (completionOrder.Count > 32) completed.Remove(completionOrder.Dequeue());
        }
        return response;
    }
    private void Cleanup(string id, AgentPrepared value)
    {
        try
        {
            byte[]? request = directory.Read(Name(id, ".request"), 65536);
            if (request is not null && request.AsSpan().SequenceEqual(value.Data)) directory.Remove(Name(id, ".request"));
            byte[]? reply = directory.Read(Name(id, ".reply"), 2048);
            if (reply is not null) { _ = AgentWriteProtocol.OpenReceipt(reply, value, Session.SessionId, id); directory.Remove(Name(id, ".reply")); }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ObjectDisposedException or CryptographicException or System.Text.Json.JsonException) { }
    }
    private static string Name(string id, string suffix) => id.ToLowerInvariant() + suffix;
    private static Dictionary<string, string> Result(string status, string id) => new() { ["status"] = status, ["request_id"] = id.ToLowerInvariant() };
    public void Dispose()
    {
        if (closed) return; closed = true;
        foreach (var pair in prepared) { Cleanup(pair.Key, pair.Value); pair.Value.Dispose(); }
        prepared.Clear(); created.Clear(); completed.Clear(); completionOrder.Clear(); directory.Dispose();
    }
}
