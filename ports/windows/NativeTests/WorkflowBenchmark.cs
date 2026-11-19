using Cliphoard.Windows;
using System.Diagnostics;
using System.Text.Json;

internal static class WorkflowBenchmark
{
    internal static void Run()
    {
        string directory = Path.Combine(Path.GetTempPath(), "CliphoardWorkflowBenchmark-" + Guid.NewGuid().ToString("N"));
        int checks = 0;
        void Check(bool condition, string scenario)
        {
            ++checks;
            if (!condition) throw new Exception("Workflow benchmark failed in " + scenario);
        }
        var timer = Stopwatch.StartNew();
        const string marker = "[CLIPHOARD_SYNTHETIC_V1] ";
        string[] values = { "", " ", "\t", "line one\r\nline two", "line one\nline two", "café", "cafe\u0301", "猫", "مرحبا", "שלום", "👩🏽‍💻🐈", "\u202Esynthetic", new string('x', 65536 - marker.Length) };
        try
        {
            var store = new HistoryStore(directory);
            store.State.Limit = 0;
            foreach (string value in values)
            {
                string text = marker + value;
                store.Add(new HistoryItem { Text = text, Pinned = true, Tags = new() { "synthetic" } });
                HistoryItem original = store.State.Items.Single(item => item.Text == text);
                string id = original.Id;
                store.MarkUsed(original);
                int uses = original.UseCount;
                store.Add(new HistoryItem { Text = text });
                HistoryItem duplicate = store.State.Items.Single(item => item.Text == text);
                Check(duplicate.Id == id && duplicate.Pinned && duplicate.UseCount == uses, "dedup metadata");
                Check(duplicate.Tags.SequenceEqual(new[] { "synthetic" }), "dedup tags");
                var restored = new HistoryStore(directory);
                Check(restored.Writable && restored.State.Items.Single(item => item.Id == id).Text == text, "Unicode persistence");
            }
            for (int index = 0; index < 160; index++)
                store.Add(new HistoryItem { Text = "[CLIPHOARD_SYNTHETIC_V1] unique row " + index });
            Check(store.State.Items.Count == values.Length + 160, "unlimited history");
            foreach (int limit in new[] { 100, 50 })
            {
                store.State.Limit = limit;
                store.Trim();
                store.Save();
                Check(store.State.Items.Count == values.Length + limit, "history trim");
                Check(store.State.Items.Count(item => item.Pinned) == values.Length, "pinned retention");
                Check(new HistoryStore(directory).State.Items.Count == values.Length + limit, "trim persistence");
            }
            string[] before = store.State.Items.Select(item => item.Id).Order().ToArray();
            bool refused = false;
            try { store.Import(new[] { new HistoryItem { Text = "[CLIPHOARD_SYNTHETIC_V1] exceeds limit" } }, false); }
            catch (IOException) { refused = true; }
            Check(refused && store.State.Items.Select(item => item.Id).Order().SequenceEqual(before), "over-limit import atomicity");
            Check(new HistoryStore(directory).State.Items.Select(item => item.Id).Order().SequenceEqual(before), "rejected import persistence");
            Check(HistoryStore.NewContentCount(store.State.Items, store.State.Items) == 0, "repeat import idempotence");
            Check(store.Writable && !store.UnsavedChanges, "durable completion");
            foreach (string invalid in new[] { "invalid\0text", new string('x', 65537) })
            {
                string rejectedDirectory = Path.Combine(directory, "rejected-" + Guid.NewGuid().ToString("N"));
                var guarded = new HistoryStore(rejectedDirectory);
                guarded.Add(new HistoryItem { Text = marker + "preserved" });
                guarded.Add(new HistoryItem { Text = invalid });
                Check(!guarded.Writable && guarded.UnsavedChanges, "invalid write refusal");
                var recovered = new HistoryStore(rejectedDirectory);
                Check(recovered.Writable && recovered.State.Items.Single().Text == marker + "preserved", "invalid write preserves durable state");
            }
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
        Console.WriteLine(JsonSerializer.Serialize(new { workflow_checks = checks, status = "passed", milliseconds = timer.Elapsed.TotalMilliseconds, unicode_cases = values.Length, synthetic_only = true }));
    }
}
