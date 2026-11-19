using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
namespace Cliphoard.Windows;

/// Per-row DPAPI keeps payloads outside the resident history projection.
internal sealed class HistoryDatabase
{
    private const int MaximumMetadataBytes = 40 * 1024 * 1024;
    private readonly string path;
    private readonly Dictionary<string, string> saved = new(StringComparer.Ordinal);
    internal static readonly JsonSerializerOptions MetadataOptions = CreateOptions();
    internal sealed record Record(HistoryItem Item, int PayloadLength, string? PayloadDigest);
    internal HistoryDatabase(string directory) { path = Path.Combine(directory, "history.sqlite"); }
    internal bool Exists => File.Exists(path);
    private static JsonSerializerOptions CreateOptions()
    {
        var resolver = new DefaultJsonTypeInfoResolver();
        resolver.Modifiers.Add(info =>
        {
            if (info.Type == typeof(HistoryItem)) info.Properties.Remove(info.Properties.Single(property => property.Name == "Payload"));
            if (info.Type == typeof(HistoryState)) info.Properties.Remove(info.Properties.Single(property => property.Name == "Items"));
        });
        return new() { TypeInfoResolver = resolver, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    }
    private SqliteConnection Open(bool writing)
    {
        VerifiedModelAssets.CheckPath(path);
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = writing ? SqliteOpenMode.ReadWriteCreate : SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 5 }.ToString());
        try
        {
            connection.Open();
            if (writing)
            {
                using var schema = connection.CreateCommand();
                schema.CommandText = "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA journal_size_limit=2097152; CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY CHECK(id=1), body BLOB NOT NULL); CREATE TABLE IF NOT EXISTS clips (id TEXT PRIMARY KEY NOT NULL, metadata BLOB NOT NULL, payload BLOB);";
                schema.ExecuteNonQuery();
            }
            return connection;
        }
        catch { connection.Dispose(); throw; }
    }
    internal HistoryState Load()
    {
        using var connection = Open(false);
        using var settings = connection.CreateCommand();
        settings.CommandText = "SELECT length(body), body FROM settings WHERE id=1";
        byte[] cipher;
        using (var row = settings.ExecuteReader())
        {
            if (!row.Read() || row.GetInt64(0) is < 1 or > 1114112) throw new IOException("History settings are unavailable.");
            cipher = row.GetFieldValue<byte[]>(1);
        }
        byte[] clear = Unseal(cipher, 1024 * 1024);
        HistoryState state;
        try { state = JsonSerializer.Deserialize<HistoryState>(clear, MetadataOptions) ?? throw new IOException("Invalid history settings."); }
        finally { CryptographicOperations.ZeroMemory(clear); }
        using var command = connection.CreateCommand(); command.CommandText = "SELECT id, length(metadata), metadata FROM clips";
        using var rows = command.ExecuteReader();
        while (rows.Read())
        {
            string id = rows.GetString(0);
            if (rows.GetInt64(1) < 1 || rows.GetInt64(1) > MaximumMetadataBytes + 65536L) throw new IOException("History metadata exceeds its bound.");
            clear = Unseal(rows.GetFieldValue<byte[]>(2), MaximumMetadataBytes);
            try
            {
                Record record = JsonSerializer.Deserialize<Record>(clear, MetadataOptions) ?? throw new IOException("Invalid history record.");
                if (!Guid.TryParse(id, out _) || record.Item is null || record.Item.Id != id || record.PayloadLength is < 0 or > 8 * 1024 * 1024 || record.PayloadLength > 0 && (record.PayloadDigest is null || record.PayloadDigest.Length != 64 || !record.PayloadDigest.All(Uri.IsHexDigit))) throw new IOException("History identity is invalid.");
                int length = record.PayloadLength; string? payloadDigest = record.PayloadDigest;
                record.Item.AttachPayload(() => ReadPayload(id, length, payloadDigest), length, payloadDigest);
                state.Items.Add(record.Item); saved[id] = Convert.ToHexString(SHA256.HashData(clear));
            }
            finally { CryptographicOperations.ZeroMemory(clear); }
        }
        return state;
    }
    private byte[]? ReadPayload(string id, int expectedLength, string? digest)
    {
        if (expectedLength == 0) return null;
        using var connection = Open(false);
        using var command = connection.CreateCommand(); command.CommandText = "SELECT length(payload), payload FROM clips WHERE id=$id"; command.Parameters.AddWithValue("$id", id);
        using var row = command.ExecuteReader();
        if (!row.Read() || row.IsDBNull(0) || row.GetInt64(0) is < 1 or > 8454144) throw new IOException("History payload is unavailable.");
        byte[] cipher = row.GetFieldValue<byte[]>(1);
        byte[] clear = Unseal(cipher, 8 * 1024 * 1024);
        if (clear.Length == expectedLength && Convert.ToHexString(SHA256.HashData(clear)) == digest) return clear;
        CryptographicOperations.ZeroMemory(clear); throw new IOException("History payload authentication failed.");
    }
    private static byte[] Unseal(byte[] cipher, int bound)
    {
        if (cipher.Length > bound + 65536) throw new IOException("Encrypted history record exceeds its bound.");
        byte[] clear = HistoryStore.Protect(cipher, false);
        if (clear.Length <= bound) return clear;
        CryptographicOperations.ZeroMemory(clear); throw new IOException("History record exceeds its bound.");
    }
    internal void Compact()
    {
        using var connection = Open(true);
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA wal_checkpoint(TRUNCATE); VACUUM; PRAGMA wal_checkpoint(TRUNCATE);";
        command.ExecuteNonQuery();
    }
    internal void Save(HistoryState state)
    {
        using var connection = Open(true);
        using var transaction = connection.BeginTransaction();
        var next = new Dictionary<string, string>(StringComparer.Ordinal);
        var attached = new List<HistoryItem>();
        byte[] settings = JsonSerializer.SerializeToUtf8Bytes(state, MetadataOptions);
        try
        {
            using var command = connection.CreateCommand(); command.Transaction = transaction;
            command.CommandText = "INSERT INTO settings(id,body) VALUES(1,$body) ON CONFLICT(id) DO UPDATE SET body=excluded.body";
            command.Parameters.AddWithValue("$body", HistoryStore.Protect(settings, true)); command.ExecuteNonQuery();
        }
        finally { CryptographicOperations.ZeroMemory(settings); }
        foreach (HistoryItem item in state.Items)
        {
            if (HistoryStore.Size(item) > 24 * 1024 * 1024) throw new IOException("Clip exceeds its storage bound.");
            byte[] metadata = JsonSerializer.SerializeToUtf8Bytes(new Record(item, item.PayloadLength, item.PayloadDigest), MetadataOptions);
            try
            {
                if (metadata.Length > MaximumMetadataBytes) throw new IOException("History metadata exceeds its bound.");
                string digest = Convert.ToHexString(SHA256.HashData(metadata)); next[item.Id] = digest;
                if (saved.GetValueOrDefault(item.Id) == digest && !item.PayloadChanged) continue;
                using var command = connection.CreateCommand(); command.Transaction = transaction;
                bool payloadChanged = item.PayloadChanged || !saved.ContainsKey(item.Id);
                command.CommandText = payloadChanged
                    ? "INSERT INTO clips(id,metadata,payload) VALUES($id,$metadata,$payload) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata,payload=excluded.payload"
                    : "UPDATE clips SET metadata=$metadata WHERE id=$id";
                command.Parameters.AddWithValue("$id", item.Id); command.Parameters.AddWithValue("$metadata", HistoryStore.Protect(metadata, true));
                if (payloadChanged)
                {
                    byte[]? payload = item.Payload;
                    command.Parameters.AddWithValue("$payload", payload is null ? DBNull.Value : HistoryStore.Protect(payload, true));
                    attached.Add(item);
                }
                command.ExecuteNonQuery();
            }
            finally { CryptographicOperations.ZeroMemory(metadata); }
        }
        foreach (string id in saved.Keys.Where(id => !next.ContainsKey(id)))
        {
            using var command = connection.CreateCommand(); command.Transaction = transaction; command.CommandText = "DELETE FROM clips WHERE id=$id"; command.Parameters.AddWithValue("$id", id); command.ExecuteNonQuery();
        }
        transaction.Commit();
        saved.Clear(); foreach (var pair in next) saved.Add(pair.Key, pair.Value);
        foreach (HistoryItem item in attached)
        {
            string id = item.Id; int length = item.PayloadLength; string? digest = item.PayloadDigest;
            item.AttachPayload(() => ReadPayload(id, length, digest), length, digest);
        }
    }
}
