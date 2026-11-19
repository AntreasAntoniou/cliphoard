using System.Security.Cryptography;
using System.Text.Json;
namespace Cliphoard.Windows;

/// Retains unsaved changes as per-record ciphertext while the Windows session is unavailable.
internal sealed class SuspendedHistory : IDisposable
{
    private readonly List<Entry> entries = new();
    private byte[] settings = Array.Empty<byte>();
    private sealed record Entry(byte[] Metadata, byte[]? Payload, Func<byte[]?>? Loader);
    internal SuspendedHistory(HistoryState state)
    {
        try
        {
            settings = Seal(JsonSerializer.SerializeToUtf8Bytes(state, HistoryDatabase.MetadataOptions));
            foreach (HistoryItem item in state.Items)
            {
                byte[] metadata = Seal(JsonSerializer.SerializeToUtf8Bytes(new HistoryDatabase.Record(item, item.PayloadLength, item.PayloadDigest), HistoryDatabase.MetadataOptions));
                byte[]? payload = item.PayloadChanged && item.PayloadLength > 0 ? HistoryStore.Protect(item.Payload ?? throw new IOException("Unsaved payload is unavailable."), true) : null;
                entries.Add(new(metadata, payload, item.PayloadLoader));
            }
        }
        catch { Dispose(); throw; }
    }
    private static byte[] Seal(byte[] clear)
    {
        try { return HistoryStore.Protect(clear, true); }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }
    internal HistoryState Restore()
    {
        byte[] clear = HistoryStore.Protect(settings, false);
        HistoryState state;
        try { state = JsonSerializer.Deserialize<HistoryState>(clear, HistoryDatabase.MetadataOptions) ?? throw new IOException("Session recovery settings are unavailable."); }
        finally { CryptographicOperations.ZeroMemory(clear); }
        foreach (Entry entry in entries)
        {
            clear = HistoryStore.Protect(entry.Metadata, false);
            HistoryDatabase.Record record;
            try { record = JsonSerializer.Deserialize<HistoryDatabase.Record>(clear, HistoryDatabase.MetadataOptions) ?? throw new IOException("Session recovery record is unavailable."); }
            finally { CryptographicOperations.ZeroMemory(clear); }
            if (entry.Payload is not null)
            {
                byte[] payload = HistoryStore.Protect(entry.Payload, false);
                if (payload.Length != record.PayloadLength || Convert.ToHexString(SHA256.HashData(payload)) != record.PayloadDigest) { CryptographicOperations.ZeroMemory(payload); throw new IOException("Session recovery payload changed."); }
                record.Item.Payload = payload;
            }
            else record.Item.AttachPayload(entry.Loader ?? (() => null), record.PayloadLength, record.PayloadDigest);
            state.Items.Add(record.Item);
        }
        return state;
    }
    public void Dispose()
    {
        CryptographicOperations.ZeroMemory(settings); settings = Array.Empty<byte>();
        foreach (Entry entry in entries) { CryptographicOperations.ZeroMemory(entry.Metadata); if (entry.Payload is not null) CryptographicOperations.ZeroMemory(entry.Payload); }
        entries.Clear();
    }
}
