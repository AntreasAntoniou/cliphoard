using System.Security.Cryptography;
namespace Cliphoard.Windows;
internal enum AgentPermission { AskEveryTime, Session, FullAccess }
internal sealed class AgentPending : IDisposable
{
    internal AgentOpened Opened { get; }
    internal byte[] Bytes { get; }
    internal long Deadline { get; }
    internal bool ForcedApproval { get; set; }
    internal string Id => Opened.Request.RequestId;
    internal string Text => Opened.Request.Text;
    internal AgentPending(AgentOpened opened, byte[] bytes, long deadline) { Opened = opened; Bytes = bytes; Deadline = deadline; }
    public void Dispose() { Opened.Dispose(); CryptographicOperations.ZeroMemory(Bytes); }
}

/// Explicit, temporary write-only authority. Permission changes invalidate automatic admission.
internal sealed class AgentWriteController : IDisposable
{
    private sealed class Connection : IDisposable
    {
        internal AgentSession Session { get; }
        internal byte[] Key { get; }
        internal AgentWriteDirectory Directory { get; }
        internal double BeganAt { get; }
        internal long BeganTick { get; }
        internal Connection(AgentSession session, byte[] key, AgentWriteDirectory directory, double began, long tick) { Session = session; Key = key; Directory = directory; BeganAt = began; BeganTick = tick; }
        public void Dispose()
        {
            try
            {
                byte[]? published = Directory.Read("session.json", 1024);
                if (published is not null && published.AsSpan().SequenceEqual(AgentWriteProtocol.Encode(Session))) Directory.Remove("session.json");
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ObjectDisposedException) { }
            finally { CryptographicOperations.ZeroMemory(Key); Directory.Dispose(); }
        }
    }
    private readonly Func<string, string, bool> save;
    private readonly Func<bool> available;
    private readonly Action<AgentPermission> persistPermission;
    private readonly Func<double> now;
    private readonly Func<long> ticks;
    private readonly List<AgentPending> pending = new();
    private readonly Dictionary<string, double> handled = new(StringComparer.Ordinal);
    private Connection? connection;
    private long generation, policy;
    private bool polling, working, disposed;
    private Guid busy;
    internal AgentPermission Permission { get; private set; }
    internal string? Folder => connection?.Directory.Path;
    internal bool Connected => connection is not null;
    internal bool Working => working;
    internal IReadOnlyList<AgentPending> Pending => pending;
    internal string Message { get; private set; } = "Enable an agent connection to receive new plain-text notes.";
    internal event Action? Changed;
    internal event Action? ApprovalRequested;
    internal AgentWriteController(Func<string, string, bool> save, Func<bool> available, Action<AgentPermission> persistPermission, bool rememberedFullAccess = false, Func<double>? now = null, Func<long>? ticks = null)
    {
        this.save = save; this.available = available; this.persistPermission = persistPermission;
        this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0); this.ticks = ticks ?? (() => Environment.TickCount64);
        Permission = rememberedFullAccess ? AgentPermission.FullAccess : AgentPermission.AskEveryTime;
    }
    private void Update(string message) { Message = message; Changed?.Invoke(); }
    internal bool SetPermission(AgentPermission selected, bool confirmed)
    {
        if (!Enum.IsDefined(selected)) return false;
        if (disposed || selected == Permission) return !disposed;
        if (selected > Permission && !confirmed || selected == AgentPermission.Session && connection is null) return false;
        ++policy; Permission = selected; persistPermission(selected == AgentPermission.FullAccess ? selected : AgentPermission.AskEveryTime);
        foreach (AgentPending note in pending) note.ForcedApproval = true;
        if (connection?.Session.Lifetime == "whileAppRuns" && selected != AgentPermission.FullAccess) Disconnect(resetSession: false);
        Update("Agent permission updated. Review pending notes before saving."); return true;
    }
    internal async Task EnableAsync(string parent)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        Disconnect(resetSession: false);
        long captured = generation, capturedPolicy = policy;
        Guid operation = Guid.NewGuid(); busy = operation; working = true; Changed?.Invoke();
        Connection? created = null;
        try
        {
            if (!available()) throw new IOException("Agent saves are unavailable.");
            double began = now(); long tick = ticks(); bool continuous = Permission == AgentPermission.FullAccess;
            created = await Task.Run(() =>
            {
                AgentHost host = AgentHostIdentity.Current();
                AgentWriteDirectory directory = AgentWriteDirectory.Create(parent);
                byte[] key = RandomNumberGenerator.GetBytes(32);
                try
                {
                    var session = new AgentSession(2, Guid.NewGuid().ToString("D").ToUpperInvariant(), continuous ? null : began + 900, AgentWriteProtocol.PublicKey(key), continuous ? "whileAppRuns" : "bounded", host);
                    directory.WriteExclusive("session.json", AgentWriteProtocol.EncodeSession(session, began));
                    return new Connection(session, key, directory, began, tick);
                }
                catch { CryptographicOperations.ZeroMemory(key); directory.Dispose(); throw; }
            });
            if (disposed || captured != generation || capturedPolicy != policy || !available()) return;
            connection = created; created = null;
            Update(continuous ? "Agent connection is active until you disconnect or quit." : "Agent connection is active for 15 minutes.");
        }
        finally
        {
            created?.Dispose();
            if (busy == operation) { busy = Guid.Empty; working = false; Changed?.Invoke(); }
        }
    }
    private double EffectiveNow(Connection current) => Math.Max(now(), current.BeganAt + (ticks() - current.BeganTick) / 1000.0);
    private bool Active(Connection current, long captured) => !disposed && generation == captured && ReferenceEquals(connection, current) && available()
        && ticks() >= current.BeganTick && (current.Session.ExpiresAt is not double expiry || EffectiveNow(current) < expiry && ticks() - current.BeganTick < 900000);
    private bool Unexpired(AgentPending note, Connection current) => ticks() < note.Deadline && EffectiveNow(current) - note.Opened.Request.CreatedAt < 120;
    private static bool Sensitive(string text) => ContentSafety.Flags(text, "Cliphoard Agent") != 0 || NsfwPolicy.Labelled(new HistoryItem { Text = text });
    internal async Task PollAsync()
    {
        if (disposed || polling || working || connection is not Connection current) return;
        polling = true; long captured = generation, capturedPolicy = policy;
        try
        {
            if (!Active(current, captured)) { Disconnect(); return; }
            foreach (string id in handled.Where(pair => pair.Value <= EffectiveNow(current)).Select(pair => pair.Key).ToArray()) handled.Remove(id);
            foreach (AgentPending note in pending.ToArray())
            {
                if (!Active(current, captured) || working) return;
                if (!Unexpired(note, current)) { await FinishAsync(note, "expired", current, captured); continue; }
                byte[]? bytes;
                try { bytes = await Task.Run(() => current.Directory.Read(note.Id.ToLowerInvariant() + ".request", 65536)); }
                catch (IOException) { bytes = null; }
                if (!Active(current, captured) || !pending.Contains(note)) return;
                if (!Unexpired(note, current)) await FinishAsync(note, "expired", current, captured);
                else if (bytes is null || !bytes.AsSpan().SequenceEqual(note.Bytes))
                {
                    handled[note.Id] = note.Opened.Request.CreatedAt + 120; pending.Remove(note); note.Dispose(); Update("An agent cancelled or changed a pending request.");
                }
            }
            int capacity = Math.Min(32 - pending.Count, 64 - handled.Count - pending.Count);
            if (capacity <= 0) return;
            var excluded = pending.Select(note => note.Id).Concat(handled.Keys).ToHashSet(StringComparer.Ordinal);
            double time = EffectiveNow(current); long tick = ticks();
            var found = await Task.Run(() =>
            {
                var result = new List<AgentPending>();
                try
                {
                    foreach (string name in current.Directory.RequestNames())
                    {
                        string id = name[..^8].ToUpperInvariant();
                        if (excluded.Contains(id)) continue;
                        try
                        {
                            byte[]? bytes = current.Directory.Read(name, 65536); if (bytes is null) continue;
                            AgentOpened opened = AgentWriteProtocol.OpenRequest(bytes, current.Session, current.Key, time);
                            if (opened.Request.RequestId != id) { opened.Dispose(); continue; }
                            result.Add(new(opened, bytes, tick + (long)(Math.Min(120, Math.Max(0, opened.Request.CreatedAt + 120 - time)) * 1000)));
                            if (result.Count == capacity) break;
                        }
                        catch (Exception error) when (error is IOException or CryptographicException or System.Text.Json.JsonException) { }
                    }
                    return result;
                }
                catch { foreach (AgentPending note in result) note.Dispose(); throw; }
            });
            if (!Active(current, captured)) { foreach (AgentPending note in found) note.Dispose(); return; }
            bool notice = false;
            foreach (AgentPending note in found.OrderBy(note => note.Opened.Request.CreatedAt).ThenBy(note => note.Id, StringComparer.Ordinal))
            {
                if (!Active(current, captured) || pending.Any(existing => existing.Id == note.Id) || handled.ContainsKey(note.Id)) { note.Dispose(); continue; }
                if (Sensitive(note.Text)) { await FinishAsync(note, "rejected", current, captured); continue; }
                note.ForcedApproval = capturedPolicy != policy; pending.Add(note);
                notice |= Permission == AgentPermission.AskEveryTime || note.ForcedApproval;
            }
            if (notice) { Update("An agent is asking to save a note. Review pending notes."); ApprovalRequested?.Invoke(); }
            foreach (AgentPending note in pending.ToArray())
                if (Active(current, captured) && Permission != AgentPermission.AskEveryTime && capturedPolicy == policy && !note.ForcedApproval) await SavePendingAsync(note.Id, note.Opened.RequestDigest, capturedPolicy);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ObjectDisposedException) { if (ReferenceEquals(connection, current)) { Disconnect(); Update("The agent connection closed because its folder became unavailable."); } }
        finally { polling = false; }
    }
    internal Task ApproveAsync(string id, string expectedDigest) => SavePendingAsync(id, expectedDigest, null);
    internal async Task RejectAsync(string id, string expectedDigest)
    {
        if (working || connection is not Connection current) return;
        AgentPending? note = pending.FirstOrDefault(note => note.Id == id && note.Opened.RequestDigest == expectedDigest);
        if (note is not null) await FinishAsync(note, "rejected", current, generation);
    }
    private async Task SavePendingAsync(string id, string expectedDigest, long? automaticPolicy)
    {
        if (working || connection is not Connection current) return;
        AgentPending? note = pending.FirstOrDefault(note => note.Id == id && note.Opened.RequestDigest == expectedDigest);
        if (note is null) return;
        long captured = generation;
        if (!Active(current, captured) || !Unexpired(note, current)) { await FinishAsync(note, "expired", current, captured); return; }
        if (automaticPolicy is long selected && (selected != policy || Permission == AgentPermission.AskEveryTime || note.ForcedApproval)) return;
        Guid operation = Guid.NewGuid(); busy = operation; working = true; Changed?.Invoke();
        try
        {
            bool valid = await Task.Run(() =>
            {
                byte[]? bytes = current.Directory.Read(id.ToLowerInvariant() + ".request", 65536);
                return bytes is not null && bytes.AsSpan().SequenceEqual(note.Bytes) && !Sensitive(note.Text);
            });
            if (!Active(current, captured) || !pending.Contains(note)) return;
            if (!Unexpired(note, current)) { await FinishAsync(note, "expired", current, captured); return; }
            if (!valid) { await FinishAsync(note, "rejected", current, captured); return; }
            if (automaticPolicy is long selectedPolicy && (selectedPolicy != policy || Permission == AgentPermission.AskEveryTime)) { note.ForcedApproval = true; ApprovalRequested?.Invoke(); return; }
            bool saved = save(id, note.Text);
            await FinishAsync(note, saved ? "saved" : "unavailable", current, captured);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ObjectDisposedException) { if (Active(current, captured)) Update("The note could not be confirmed. Check your history before sending it again."); }
        finally { if (busy == operation) { busy = Guid.Empty; working = false; Changed?.Invoke(); } }
    }
    private async Task FinishAsync(AgentPending note, string status, Connection current, long captured)
    {
        if (!Active(current, captured)) { pending.Remove(note); note.Dispose(); return; }
        handled[note.Id] = note.Opened.Request.CreatedAt + 120; pending.Remove(note);
        bool confirmed = false;
        try
        {
            confirmed = await Task.Run(() =>
            {
                byte[] reply = AgentWriteProtocol.SealReceipt(status, note.Opened);
                current.Directory.WriteExclusive(note.Id.ToLowerInvariant() + ".reply", reply);
                current.Directory.Remove(note.Id.ToLowerInvariant() + ".request"); return true;
            });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ObjectDisposedException or CryptographicException) { }
        finally { note.Dispose(); }
        if (!ReferenceEquals(connection, current) || generation != captured) return;
        Update(status == "unavailable" ? "The save could not be confirmed. Check your history before sending it again."
            : status == "saved" ? confirmed ? "Saved and pinned." : "Saved locally. The agent confirmation is unavailable."
            : confirmed ? "The request was closed. The agent has been notified." : "The request was closed. Its confirmation is unavailable.");
    }
    internal void Disconnect(bool resetSession = true)
    {
        ++generation; busy = Guid.Empty; working = false;
        Connection? old = connection; connection = null;
        foreach (AgentPending note in pending) note.Dispose(); pending.Clear(); handled.Clear();
        old?.Dispose();
        if (resetSession && Permission == AgentPermission.Session) { Permission = AgentPermission.AskEveryTime; persistPermission(Permission); }
        Update("Agent connection is closed.");
    }
    public void Dispose() { if (disposed) return; Disconnect(); disposed = true; }
}
