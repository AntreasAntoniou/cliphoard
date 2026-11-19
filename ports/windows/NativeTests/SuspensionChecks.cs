using Cliphoard.Windows;
using Microsoft.Data.Sqlite;
using System.Reflection;
using System.Text.Json;
internal static class SuspensionChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Session recovery check {checks} failed"); }
        string folder = Path.Combine(Path.GetTempPath(), "CliphoardSuspensionFixture-" + Guid.NewGuid().ToString("N"));
        try
        {
            var history = new HistoryStore(folder); history.Add(new() { Text = "synthetic durable note" });
            using var image = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.SyntheticRed.png")!;
            using var buffer = new MemoryStream(); image.CopyTo(buffer);
            history.Add(new() { Kind = "Image", Format = 0, Payload = buffer.ToArray(), Text = "synthetic durable image" });
            history.Suspend(); Check(history.State.Items.Count == 0); history.Load(); Check(history.State.Items.Count == 2 && history.Writable);
            string rejected = Guid.NewGuid().ToString("N");
            using (var connection = new SqliteConnection($"Data Source={Path.Combine(folder, "history.sqlite")};Pooling=False"))
            {
                connection.Open(); using var command = connection.CreateCommand();
                command.CommandText = $"CREATE TRIGGER synthetic_failure BEFORE INSERT ON clips WHEN NEW.id='{rejected}' BEGIN SELECT RAISE(ABORT,'synthetic'); END"; command.ExecuteNonQuery();
            }
            history.Add(new() { Id = rejected, Text = "synthetic unsaved note", Pinned = true });
            Check(!history.Writable && history.UnsavedChanges && history.State.Items.Count == 3);
            history.Add(new() { Kind = "Image", Format = 0, Payload = buffer.ToArray(), Text = "synthetic unsaved image" });
            // Dedup keeps the earlier image's stable identity and still exercises its lazy payload.
            history.State.Theme = "dracula";
            history.Suspend(); Check(history.State.Items.Count == 0);
            history.Suspend(); Check(history.State.Items.Count == 0);
            history.Load(); Check(history.State.Items.Count == 3 && history.State.Items.Any(item => item.Id == rejected));
            Check(!history.Writable && history.UnsavedChanges && history.State.Theme == "dracula");
            Check(history.State.Items.Single(item => item.Kind == "Image").Payload!.SequenceEqual(buffer.ToArray()));
            Check(new HistoryStore(folder).State.Items.Count == 2);
            // A new, different image remains recoverable without a durable payload row.
            byte[] blue;
            using (var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.SyntheticBlue.png")!) { using var output = new MemoryStream(); source.CopyTo(output); blue = output.ToArray(); }
            history.Add(new() { Kind = "Image", Format = 0, Payload = blue, Text = "synthetic unsaved blue image" });
            history.Suspend(); history.Load(); Check(history.State.Items.Count == 4 && history.State.Items.Any(item => item.PayloadDigest == Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(blue)) && item.Payload!.SequenceEqual(blue)));
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { session_recovery_checks = checks, status = "passed", generated_data_only = true }));
    }
}
