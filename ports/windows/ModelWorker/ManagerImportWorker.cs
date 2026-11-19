using Cliphoard.Windows;
using Microsoft.Data.Sqlite;
using System.Globalization;
using System.Text;
using System.Text.Json;

internal static class ManagerImportWorker
{
    internal static async Task<int> RunAsync()
    {
        using Stream input = Console.OpenStandardInput(), output = Console.OpenStandardOutput();
        try
        {
            ManagerImportRequest request = await ModelWorkerProtocol.ReadAsync<ManagerImportRequest>(input, default);
            if (request.Source is not ("paste" or "maccy" or "alfred" or "flycut" or "probe")) throw new IOException();
            using var lease = LocalFileLease.Open(request.Path, 256 * 1024 * 1024);
            var items = new List<ManagerImportItem>(); int skipped = 0; long bytes = 0;
            void Add(string kind, string text, string source, double created, byte[]? image = null)
            {
                if (string.IsNullOrWhiteSpace(text) || text.Length > 65536 || source.Length > 1024 || image?.Length > 8 * 1024 * 1024) { ++skipped; return; }
                bytes += Encoding.UTF8.GetByteCount(text) + (image?.Length ?? 0);
                if (items.Count >= 10000 || bytes > 12 * 1024 * 1024) throw new IOException("Import preview exceeds its bound.");
                items.Add(new(kind, text, source, double.IsFinite(created) && created >= 0 && created < 253402300799 ? created : 0, image));
            }
            static string Text(object? value) => value as string ?? "";
            static double Number(object? value) => value is double real ? real : value is long integer ? integer : double.TryParse(value?.ToString(), CultureInfo.InvariantCulture, out double parsed) ? parsed : 0;
            if (request.Source == "flycut")
            {
                if (lease.Length > 16 * 1024 * 1024) throw new IOException();
                byte[] data = new byte[(int)lease.Length]; await lease.ReadExactlyAsync(data);
                try
                {
                    if (PropertyList.Read(data) is not Dictionary<string, object?> plist || plist.GetValueOrDefault("store") is not Dictionary<string, object?> store || store.GetValueOrDefault("jcList") is not object?[] entries) throw new IOException("Unrecognized Flycut schema.");
                    foreach (object? entry in entries)
                    {
                        if (entry is not Dictionary<string, object?> values) { ++skipped; continue; }
                        Add("text", Text(values.GetValueOrDefault("Contents")), Text(values.GetValueOrDefault("AppLocalizedName")), Number(values.GetValueOrDefault("Timestamp")));
                    }
                }
                finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(data); }
            }
            else
            {
                // Copy a stable main/WAL pair. SQLite can create its own SHM beside this private snapshot.
                using FileStream? wal = File.Exists(request.Path + "-wal") ? LocalFileLease.Open(request.Path + "-wal", 256 * 1024 * 1024) : null;
                string temporary = PrivateDirectory.Create("CliphoardImport");
                try
                {
                    string snapshot = Path.Combine(temporary, "source.sqlite");
                    await using (var file = new FileStream(snapshot, FileMode.CreateNew, FileAccess.Write, FileShare.None)) await lease.CopyToAsync(file);
                    if (wal is not null) { await using var file = new FileStream(snapshot + "-wal", FileMode.CreateNew, FileAccess.Write, FileShare.None); await wal.CopyToAsync(file); }
                    using var database = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = snapshot, Mode = SqliteOpenMode.ReadOnly, Cache = SqliteCacheMode.Private, Pooling = false, DefaultTimeout = 2 }.ToString()); database.Open();
                    using (var policy = database.CreateCommand()) { policy.CommandText = "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;"; policy.ExecuteNonQuery(); }
                    using var command = database.CreateCommand(); command.CommandTimeout = 10;
                    command.CommandText = request.Source switch
                    {
                        "maccy" => "SELECT i.ZFIRSTCOPIEDAT, i.ZAPPLICATION, c.ZTYPE, c.ZVALUE FROM ZHISTORYITEMCONTENT c JOIN ZHISTORYITEM i ON i.Z_PK=c.ZITEM ORDER BY i.ZFIRSTCOPIEDAT ASC LIMIT 10001",
                        "alfred" => "SELECT ts, app, item FROM clipboard ORDER BY ts ASC LIMIT 10001",
                        "paste" => "SELECT i.ZCREATEDAT, a.ZNAME, i.ZRAWPREVIEW FROM ZITEMENTITY i LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK=i.ZSOURCEAPPLICATION WHERE i.ZRAWPREVIEW IS NOT NULL ORDER BY i.ZCREATEDAT ASC LIMIT 10001",
                        _ => "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name LIMIT 101"
                    };
                    using var rows = command.ExecuteReader(); int scanned = 0; var tables = new List<string>();
                    while (rows.Read())
                    {
                        if (++scanned > (request.Source == "probe" ? 100 : 10000)) throw new IOException("Import row bound reached.");
                        if (request.Source == "probe") { string table = rows.GetString(0); if (table.Length > 256) throw new IOException(); tables.Add(table); continue; }
                        string source = rows.IsDBNull(1) ? "" : rows.GetString(1);
                        double created = Number(rows.GetValue(0));
                        if (request.Source == "alfred")
                        {
                            if (created == 0 && DateTimeOffset.TryParse(rows.GetValue(0).ToString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date)) created = date.ToUnixTimeMilliseconds() / 1000.0;
                            if (!rows.IsDBNull(2)) Add("text", rows.GetString(2), source, created); else ++skipped;
                        }
                        else if (request.Source == "maccy")
                        {
                            if (rows.IsDBNull(3) || rows.GetBytes(3, 0, null, 0, 0) > 8 * 1024 * 1024) { ++skipped; continue; }
                            byte[] data = (byte[])rows.GetValue(3); string type = rows.GetString(2);
                            if (type is "public.utf8-plain-text" or "public.plain-text" or "NSStringPboardType") Add("text", new UTF8Encoding(false, true).GetString(data), source, created + 978307200);
                            else if (type is "public.png" or "public.tiff" or "public.jpeg") Add("image", "Image", source, created + 978307200, data);
                            else if (type == "public.file-url") Add("file", new UTF8Encoding(false, true).GetString(data), source, created + 978307200);
                            else ++skipped;
                        }
                        else
                        {
                            if (rows.GetBytes(2, 0, null, 0, 0) > 8 * 1024 * 1024) { ++skipped; continue; }
                            byte[] data = (byte[])rows.GetValue(2);
                            Dictionary<string, object?> values;
                            if (data.AsSpan().StartsWith("bplist00"u8) || data.AsSpan().StartsWith("<?xml"u8)) values = PropertyList.Read(data) as Dictionary<string, object?> ?? throw new IOException();
                            else
                            {
                                using var document = JsonDocument.Parse(data); values = document.RootElement.EnumerateObject().ToDictionary(property => property.Name, property => JsonValue(property.Value), StringComparer.Ordinal);
                            }
                            string type = Text(values.GetValueOrDefault("type"));
                            if (type == "text") Add("text", Text(values.GetValueOrDefault("text")), source, created + 978307200);
                            else if (type == "link") Add("link", Text(values.GetValueOrDefault("url")), source, created + 978307200);
                            else if (type == "color") Add("color", "#" + ((long)Number(values.GetValueOrDefault("colorCode")) & 0xFFFFFF).ToString("X6"), source, created + 978307200);
                            else if (type == "files" && values.GetValueOrDefault("filePaths") is object?[] paths && paths.FirstOrDefault() is string path) Add("file", path, source, created + 978307200);
                            else if (values.GetValueOrDefault("imageData") is byte[] image) Add("image", "Image", source, created + 978307200, image);
                            else if (values.GetValueOrDefault("imageData") is string encoded) Add("image", "Image", source, created + 978307200, Convert.FromBase64String(encoded));
                            else ++skipped;
                        }
                    }
                    if (request.Source == "probe") { await ModelWorkerProtocol.WriteAsync(output, new ManagerImportResponse(true, Array.Empty<ManagerImportItem>(), 0, tables.ToArray()), default, 24 * 1024 * 1024); return 0; }
                }
                finally { Directory.Delete(temporary, true); }
            }
            await ModelWorkerProtocol.WriteAsync(output, new ManagerImportResponse(true, items.ToArray(), skipped), default, 24 * 1024 * 1024); return 0;
        }
        catch { await ModelWorkerProtocol.WriteAsync(output, new ManagerImportResponse(false, Array.Empty<ManagerImportItem>(), 0), default); return 1; }
    }
    private static object? JsonValue(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => value.GetString(), JsonValueKind.Number => value.GetDouble(),
        JsonValueKind.Array => value.EnumerateArray().Select(JsonValue).ToArray(),
        JsonValueKind.Null => null, _ => throw new IOException("Unsupported preview value.")
    };
}
