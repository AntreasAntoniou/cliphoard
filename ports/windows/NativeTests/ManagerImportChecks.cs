using Cliphoard.Windows;
using Microsoft.Data.Sqlite;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
internal static class ManagerImportChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Manager import check {checks} failed"); }
        string folder = Path.Combine(Path.GetTempPath(), "CliphoardManagerFixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
        try
        {
            using var fixture = JsonDocument.Parse(Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.ManagerImports.json")!);
            foreach (string format in new[] { "flycutBinary", "flycutXml" })
            {
                string path = Path.Combine(folder, format + ".plist"); await File.WriteAllBytesAsync(path, Convert.FromBase64String(fixture.RootElement.GetProperty(format).GetString()!));
                byte[] before = SHA256.HashData(await File.ReadAllBytesAsync(path));
                ManagerPreview preview = await ManagerImportClient.PreviewAsync("flycut", path, default);
                Check(preview.Items.Single().Text == "synthetic Flycut café 🌩"); Check(preview.Items[0].Captured.ToUnixTimeSeconds() == 1700000000 && preview.Items[0].Source == "Synthetic editor");
                byte[] after = SHA256.HashData(await File.ReadAllBytesAsync(path)); Check(before.SequenceEqual(after));
            }
            string database = Path.Combine(folder, "synthetic.sqlite");
            using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = database, Pooling = false }.ToString()))
            {
                connection.Open(); using var command = connection.CreateCommand();
                command.CommandText = "CREATE TABLE clipboard(item TEXT, ts TEXT, app TEXT); INSERT INTO clipboard VALUES ('synthetic Alfred note','1700000000','Synthetic editor'); CREATE TABLE ZHISTORYITEM(Z_PK INTEGER, ZFIRSTCOPIEDAT REAL, ZAPPLICATION TEXT); CREATE TABLE ZHISTORYITEMCONTENT(ZITEM INTEGER, ZTYPE TEXT, ZVALUE BLOB); INSERT INTO ZHISTORYITEM VALUES(1,721692800,'Synthetic editor'); INSERT INTO ZHISTORYITEMCONTENT VALUES(1,'public.utf8-plain-text',X'73796E746865746963204D61636379'); CREATE TABLE ZAPPLICATIONENTITY(Z_PK INTEGER, ZNAME TEXT); INSERT INTO ZAPPLICATIONENTITY VALUES(1,'Synthetic editor'); CREATE TABLE ZITEMENTITY(ZCREATEDAT REAL, ZRAWPREVIEW BLOB, ZSOURCEAPPLICATION INTEGER);"; command.ExecuteNonQuery();
                command.CommandText = "INSERT INTO ZITEMENTITY VALUES(721692800,$preview,1)"; command.Parameters.AddWithValue("$preview", Convert.FromBase64String(fixture.RootElement.GetProperty("pasteBinary").GetString()!)); command.ExecuteNonQuery(); command.Parameters.Clear();
                command.CommandText = "INSERT INTO ZITEMENTITY VALUES(721692800,$preview,1)"; command.Parameters.AddWithValue("$preview", Encoding.UTF8.GetBytes("{\"type\":\"text\",\"text\":\"synthetic Paste JSON\"}")); command.ExecuteNonQuery();
            }
            byte[] hash = SHA256.HashData(await File.ReadAllBytesAsync(database));
            Check((await ManagerImportClient.PreviewAsync("alfred", database, default)).Items.Single().Text == "synthetic Alfred note");
            var maccy = (await ManagerImportClient.PreviewAsync("maccy", database, default)).Items.Single(); Check(maccy.Text == "synthetic Maccy" && maccy.Captured.ToUnixTimeSeconds() == 1700000000);
            var paste = await ManagerImportClient.PreviewAsync("paste", database, default); Check(paste.Items.Length == 2 && paste.Items.Any(item => item.Text == "synthetic Paste binary 🌩"));
            Check((await ManagerImportClient.PreviewAsync("probe", database, default)).Tables.Contains("clipboard"));
            byte[] afterDatabase = SHA256.HashData(await File.ReadAllBytesAsync(database)); Check(hash.SequenceEqual(afterDatabase) && !File.Exists(database + "-shm") && !File.Exists(database + "-wal"));
            var history = new HistoryStore(Path.Combine(folder, "history")); history.State.Limit = 0;
            Check(history.Import(paste.Items, false) == 2 && history.Import(paste.Items, false) == 0 && new HistoryStore(Path.Combine(folder, "history")).State.Items.Count == 2);
            Check(ContentClassifier.Classify("github.com") == "Link" && ContentClassifier.Classify("person@example.com") == "Link");
            Check(ContentClassifier.Classify("a note mentioning github.com") == "Text" && ContentClassifier.Classify("https://") == "Text");
            Check(ContentClassifier.Classify("FF0000") == "Color" && ContentClassifier.Classify("deadbeef") == "Text" && ContentClassifier.Classify("#abc") == "Color");
            bool refused = false; try { PropertyList.Read("<?xml version='1.0'?><plist><dict><key>a</key><string>one</string><key>a</key><string>two</string></dict></plist>"u8.ToArray()); } catch (IOException) { refused = true; } Check(refused);
            refused = false; try { await ManagerImportClient.PreviewAsync("maccy", Path.Combine(folder, "flycutBinary.plist"), default); } catch (IOException) { refused = true; } Check(refused);
        }
        finally { Directory.Delete(folder, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { manager_import_checks = checks, status = "passed", synthetic_stores_only = true }));
    }
}
