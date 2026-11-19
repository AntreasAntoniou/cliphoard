using Cliphoard.Windows;
using Microsoft.Data.Sqlite;
using System.Text.Json;
internal static class StorageParityChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Storage parity check {checks} failed"); }
        string root = Path.Combine(Path.GetTempPath(), "CliphoardStorageFixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            string legacy = Path.Combine(root, "legacy"); Directory.CreateDirectory(legacy);
            var original = new HistoryState { Items = new() { new HistoryItem { Text = "synthetic legacy migration", Pinned = true } } };
            byte[] clear = JsonSerializer.SerializeToUtf8Bytes(original);
            byte[] sealedLegacy = HistoryStore.Protect(clear, true); Array.Clear(clear);
            File.WriteAllBytes(Path.Combine(legacy, "history.dpapi"), sealedLegacy);
            var migrated = new HistoryStore(legacy);
            Check(migrated.Writable && migrated.State.Items.Single().Text == "synthetic legacy migration");
            Check(File.Exists(Path.Combine(legacy, "history.sqlite")) && File.ReadAllBytes(Path.Combine(legacy, "history.dpapi")).SequenceEqual(sealedLegacy));
            migrated.Add(new() { Text = "synthetic after migration" });
            Check(new HistoryStore(legacy).State.Items.Count == 2);
            string corruptLegacy = Path.Combine(root, "corrupt-legacy"); Directory.CreateDirectory(corruptLegacy);
            File.WriteAllBytes(Path.Combine(corruptLegacy, "history.dpapi"), new byte[] { 1, 2, 3 });
            Check(!new HistoryStore(corruptLegacy).Writable && !File.Exists(Path.Combine(corruptLegacy, "history.sqlite")));
            string unlimited = Path.Combine(root, "unlimited");
            var history = new HistoryStore(unlimited); history.State.Limit = 0;
            history.State.Items = Enumerable.Range(0, 5001).Select(index => new HistoryItem { Text = "synthetic unlimited " + index, Pinned = index < 30 }).ToList();
            history.Save(); Check(history.Writable);
            var loaded = new HistoryStore(unlimited); Check(loaded.Writable && loaded.State.Items.Count == 5001 && loaded.State.Items.Count(item => item.Pinned) == 30);
            loaded.State.Limit = 100; loaded.Trim(); loaded.Save();
            Check(loaded.Writable && loaded.State.Items.Count == 130 && new HistoryStore(unlimited).State.Items.Count == 130);
            string rollback = Path.Combine(root, "rollback"); var before = new HistoryStore(rollback); before.Add(new() { Text = "synthetic preserved row" });
            string rejected = Guid.NewGuid().ToString("N");
            using (var db = new SqliteConnection($"Data Source={Path.Combine(rollback, "history.sqlite")};Pooling=False"))
            {
                db.Open(); using var command = db.CreateCommand();
                command.CommandText = $"CREATE TRIGGER synthetic_failure BEFORE INSERT ON clips WHEN NEW.id='{rejected}' BEGIN SELECT RAISE(ABORT,'synthetic storage failure'); END"; command.ExecuteNonQuery();
            }
            int notices = 0; before.PersistenceFailed += _ => ++notices;
            before.State.Items.Add(new() { Text = "synthetic partial row" }); before.State.Items.Add(new() { Id = rejected, Text = "synthetic rejected row" }); before.Save();
            Check(!before.Writable && before.UnsavedChanges && notices == 1 && before.State.Items.Count == 3);
            var after = new HistoryStore(rollback); Check(after.Writable && after.State.Items.Single().Text == "synthetic preserved row");
            string concurrent = Path.Combine(root, "concurrent"); var seed = new HistoryStore(concurrent); seed.Add(new() { Text = "synthetic shared seed" });
            var left = new HistoryStore(concurrent); var right = new HistoryStore(concurrent);
            Task.WaitAll(Task.Run(() => left.Add(new() { Text = "synthetic left writer" })), Task.Run(() => right.Add(new() { Text = "synthetic right writer" })));
            Check(left.Writable && right.Writable && new HistoryStore(concurrent).State.Items.Count == 3);
            var diagnostics = new HistoryStore(Path.Combine(root, "diagnostics"));
            diagnostics.RecordDiagnostic(DiagnosticKind.PanelShown);
            Check(diagnostics.State.Diagnostics.Count == 0);
            diagnostics.State.DebugLogging = true;
            for (int index = 0; index < 260; index++) diagnostics.RecordDiagnostic(DiagnosticKind.PanelShown);
            Check(diagnostics.State.Diagnostics.Count == 256 && diagnostics.Writable);
            var savedDiagnostics = new HistoryStore(diagnostics.DirectoryPath);
            Check(savedDiagnostics.State.DebugLogging && savedDiagnostics.State.Diagnostics.Count == 256);
            savedDiagnostics.State.DebugLogging = false;
            savedDiagnostics.RecordDiagnostic(DiagnosticKind.PasteSubmitted);
            Check(savedDiagnostics.State.Diagnostics.All(entry => entry.Event == DiagnosticKind.PanelShown));
        }
        finally { Directory.Delete(root, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { storage_parity_checks = checks, status = "passed", generated_data_only = true }));
    }
}
