using Cliphoard.Windows;
using Microsoft.Data.Sqlite;
using System.Reflection;
using System.Text;
using System.Text.Json;
internal static class InteractiveFixtures
{
    private const string Profile = @"C:\CliphoardDev\qualification\interactive-profile";
    internal static void PreparePreviewQuality()
    {
        Verify();
        using var image = new Bitmap(1600, 1000);
        using (var graphics = Graphics.FromImage(image))
        using (var font = new Font("Segoe UI", 70, FontStyle.Bold))
        {
            graphics.Clear(Color.White);
            graphics.DrawString("Sharp image preview", font, Brushes.Black, 60, 50);
            graphics.DrawString("1600 x 1000 original", font, Brushes.Black, 60, 180);
            for (int x = 80; x < 1520; x += 16) graphics.FillRectangle(Brushes.Black, x, 400, 8, 450);
            graphics.FillEllipse(Brushes.Red, 150, 540, 180, 180);
            graphics.FillEllipse(Brushes.Blue, 650, 540, 180, 180);
            graphics.FillEllipse(Brushes.Green, 1150, 540, 180, 180);
        }
        using var png = new MemoryStream(); image.Save(png, System.Drawing.Imaging.ImageFormat.Png);
        using var bmp = new MemoryStream(); image.Save(bmp, System.Drawing.Imaging.ImageFormat.Bmp);
        var store = new HistoryStore(Profile);
        store.Add(new() { Kind = "Image", Format = 0, Text = "Preview quality PNG 1600 x 1000", Source = "Synthetic detail PNG", Payload = png.ToArray() });
        store.Add(new() { Kind = "Image", Format = 8, Text = "Preview quality DIB 1600 x 1000", Source = "Synthetic detail DIB", Payload = bmp.ToArray().AsSpan(14).ToArray() });
        store.Save();
        Console.WriteLine(JsonSerializer.Serialize(new { preview_quality_fixtures = 2, width = 1600, height = 1000, synthetic_only = true }));
    }
    internal static async Task PrepareAsync()
    {
        Verify(); string assets = Path.Combine(Profile, "fixtures"); VerifiedModelAssets.CheckPath(assets); Directory.CreateDirectory(assets);
        foreach (string name in new[] { "SyntheticRed.png", "SyntheticBlue.png", "SyntheticSpeech.wav" })
        {
            using Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures." + name)!;
            using var bytes = new MemoryStream(); source.CopyTo(bytes); Write(Path.Combine(assets, name), bytes.ToArray());
        }
        Write(Path.Combine(assets, "synthetic.txt"), Encoding.UTF8.GetBytes("Synthetic document extraction fixture. A restaurant serves delicious meals.\nSecond local line."));
        Write(Path.Combine(assets, "synthetic.rtf"), Encoding.ASCII.GetBytes(@"{\rtf1\ansi\ansicpg65001 Synthetic rich text caf\'c3\'a9\par restaurant menu}"));
        string export = Path.Combine(assets, "synthetic-share.cliphoard");
        if (!File.Exists(export))
        {
            var history = new HistoryState { Limit = 0 };
            history.Items.Add(new() { Text = "Synthetic shared restaurant reference", Tags = new() { "agent-share" }, Source = "Synthetic fixture" });
            history.Items.Add(new() { Text = new string('x', 3999) + "🌩" + "synthetic Unicode page two", Tags = new() { "agent-share" }, Source = "Synthetic fixture" });
            history.Items.Add(new() { Text = "Synthetic unshared note", Source = "Synthetic fixture" });
            history.Items.Add(new() { Text = "synthetic person@example.com", Flags = 8, Tags = new() { "agent-share" }, Source = "Synthetic fixture" });
            byte[] archive = await MacHistoryArchive.SealAsync(history, "synthetic fixture share key"); Write(export, archive);
        }
        string database = Path.Combine(assets, "synthetic-alfred.alfdb");
        if (!File.Exists(database))
        {
            using var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = database, Pooling = false }.ToString()); connection.Open();
            using var command = connection.CreateCommand(); command.CommandText = "CREATE TABLE clipboard(item TEXT, ts TEXT, app TEXT); INSERT INTO clipboard VALUES('Synthetic imported restaurant note','1700000000','Synthetic editor'); INSERT INTO clipboard VALUES('Synthetic imported compiler note','1700000100','Synthetic editor');"; command.ExecuteNonQuery();
        }
        Console.WriteLine(JsonSerializer.Serialize(new { interactive_assets_ready = true, synthetic_only = true }));
    }
    private static void Write(string path, byte[] bytes)
    {
        if (File.Exists(path)) return;
        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None); file.Write(bytes);
    }
    internal static void Fault(bool enabled)
    {
        Verify(); string path = Path.Combine(Profile, "history.sqlite"); VerifiedModelAssets.CheckPath(path);
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadWrite, Pooling = false }.ToString()); connection.Open();
        using var command = connection.CreateCommand();
        foreach (string table in new[] { "clips", "settings" })
        foreach (string action in new[] { "INSERT", "UPDATE", "DELETE" })
        {
            string name = "cliphoard_synthetic_" + table + "_" + action;
            command.CommandText = enabled ? $"CREATE TRIGGER IF NOT EXISTS {name} BEFORE {action} ON {table} BEGIN SELECT RAISE(FAIL,'synthetic fixture write fault'); END" : $"DROP TRIGGER IF EXISTS {name}"; command.ExecuteNonQuery();
        }
        Console.WriteLine(JsonSerializer.Serialize(new { synthetic_write_fault = enabled }));
    }
    internal static void Inspect()
    {
        Verify(); var history = new HistoryStore(Profile);
        Console.WriteLine(JsonSerializer.Serialize(new { synthetic_only = true, writable = history.Writable, count = history.State.Items.Count, completed = history.State.OnboardingCompleted, model = history.State.SemanticModel, limit = history.State.Limit, audio = history.State.SearchAudioEnabled, video = history.State.SearchVideoEnabled }));
    }
    private static void Verify()
    {
        VerifiedModelAssets.CheckPath(Profile);
        if (File.ReadAllText(Path.Combine(Profile, ".synthetic-only")) != "CLIPHOARD_SYNTHETIC_V1") throw new IOException("Synthetic profile marker is unavailable.");
    }
}
