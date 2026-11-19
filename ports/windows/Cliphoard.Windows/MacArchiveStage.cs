using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
namespace Cliphoard.Windows;

/// A private, encrypted staging database keeps large archive payloads outside the UI heap.
internal sealed class MacArchiveStage : IDisposable
{
    private readonly string directory, path;
    private readonly SqliteConnection database;
    private bool disposed;
    internal HistoryState State { get; } = new() { Limit = 0 };
    internal MacArchiveStage()
    {
        directory = PrivateDirectory.Create("CliphoardArchive"); path = Path.Combine(directory, "stage.sqlite");
        database = Connect(path, create: true);
        try
        {
            database.Open(); using var command = database.CreateCommand();
            command.CommandText = "PRAGMA journal_mode=DELETE; PRAGMA temp_store=MEMORY; PRAGMA trusted_schema=OFF; CREATE TABLE clips(name TEXT PRIMARY KEY COLLATE NOCASE,body BLOB NOT NULL); CREATE TABLE payloads(name TEXT PRIMARY KEY,body BLOB NOT NULL,size INTEGER NOT NULL); CREATE TABLE extras(seq INTEGER PRIMARY KEY,type INTEGER NOT NULL,name TEXT NOT NULL COLLATE NOCASE,body BLOB NOT NULL); CREATE INDEX extras_name ON extras(name);"; command.ExecuteNonQuery();
        }
        catch { database.Dispose(); Directory.Delete(directory, true); throw; }
    }
    private static SqliteConnection Connect(string path, bool create = false) => new(new SqliteConnectionStringBuilder { DataSource = path, Mode = create ? SqliteOpenMode.ReadWriteCreate : SqliteOpenMode.ReadOnly, Pooling = false, Cache = SqliteCacheMode.Private }.ToString());
    internal void Add(byte type, string name, byte[] bytes)
    {
        if (new DriveInfo(Path.GetPathRoot(directory)!).AvailableFreeSpace < 64L * 1024 * 1024 + bytes.LongLength * 3) throw new IOException("Insufficient space for encrypted archive staging.");
        using var command = database.CreateCommand();
        command.CommandText = type switch { 2 => "INSERT INTO clips(name,body) VALUES($name,$body)", 5 => "INSERT INTO payloads(name,body,size) VALUES($name,$body,$size)", _ => "INSERT INTO extras(type,name,body) VALUES($type,$name,$body)" };
        command.Parameters.AddWithValue("$name", name); command.Parameters.AddWithValue("$body", HistoryStore.Protect(bytes, true));
        if (type == 5) command.Parameters.AddWithValue("$size", bytes.Length);
        else if (type is 3 or 4) command.Parameters.AddWithValue("$type", type);
        command.ExecuteNonQuery();
    }
    internal IEnumerable<(string Name, byte[] Body)> Clips()
    {
        using var command = database.CreateCommand(); command.CommandText = "SELECT name,body FROM clips ORDER BY rowid"; using var rows = command.ExecuteReader();
        while (rows.Read())
        {
            byte[] bytes = HistoryStore.Protect(rows.GetFieldValue<byte[]>(1), false);
            yield return (rows.GetString(0), bytes);
        }
    }
    internal MacArchiveRecord[] Extras(string id)
    {
        using var command = database.CreateCommand(); command.CommandText = "SELECT type,body,length(body) FROM extras WHERE name=$id ORDER BY seq"; command.Parameters.AddWithValue("$id", id); using var rows = command.ExecuteReader();
        var records = new List<MacArchiveRecord>(); long total = 0;
        while (rows.Read())
        {
            total += rows.GetInt64(2); if (records.Count >= 2001 || total > 16 * 1024 * 1024) throw new IOException("Supplementary archive records exceed their per-clip bound.");
            byte[] bytes = HistoryStore.Protect(rows.GetFieldValue<byte[]>(1), false); records.Add(new() { Type = (byte)rows.GetInt32(0), Name = id, Body = bytes });
        }
        return records.ToArray();
    }
    internal byte[] Payload(string name) => ReadPayload(path, name);
    private static byte[] ReadPayload(string path, string name)
    {
        using var connection = Connect(path); connection.Open(); using var command = connection.CreateCommand(); command.CommandText = "SELECT body,size FROM payloads WHERE name=$name"; command.Parameters.AddWithValue("$name", name); using var row = command.ExecuteReader();
        if (!row.Read() || row.GetInt64(1) is < 1 or > 8 * 1024 * 1024) throw new IOException("Archive payload is unavailable.");
        byte[] clear = HistoryStore.Protect(row.GetFieldValue<byte[]>(0), false);
        if (clear.Length != row.GetInt64(1) || Convert.ToHexString(SHA256.HashData(clear)).ToLowerInvariant() + ".png" != name) { CryptographicOperations.ZeroMemory(clear); throw new IOException("Archive payload identity changed."); }
        return clear;
    }
    internal void Attach(HistoryItem item, string name)
    {
        byte[]? clear = item.Payload;
        int size = item.PayloadLength; string? digest = item.PayloadDigest; string stagePath = path;
        item.AttachPayload(() => ReadPayload(stagePath, name), size, digest, retainCached: false);
        item.ArchiveFingerprint = name[..^4].ToUpperInvariant();
        if (clear is not null) CryptographicOperations.ZeroMemory(clear);
    }
    internal bool HasOrphanExtras()
    {
        using var command = database.CreateCommand(); command.CommandText = "SELECT EXISTS(SELECT 1 FROM extras LEFT JOIN clips ON clips.name=extras.name WHERE clips.name IS NULL)"; return Convert.ToInt64(command.ExecuteScalar()) != 0;
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true; State.Items.Clear(); database.Dispose(); Directory.Delete(directory, true);
    }
}
