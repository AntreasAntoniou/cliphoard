using Cliphoard.Windows;
using System.Text;
using System.Text.Json;
internal static class ArchiveChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool condition) { ++checks; if (!condition) throw new Exception($"Archive check {checks} failed"); }
        void Refuses(Action action) { bool refused = false; try { action(); } catch (Exception e) when (e is System.Security.Cryptography.CryptographicException or IOException or ArgumentException or JsonException) { refused = true; } Check(refused); }
        const string phrase = "Synthetic café passphrase 2026";
        var state = new HistoryState { Items = new() { new() { Text = "[CLIPHOARD_SYNTHETIC_V1] archive note", Tags = new() { "reference" }, Pinned = true } } };
        byte[] first = PortableHistory.Seal(state, phrase), second = PortableHistory.Seal(state, phrase); Check(!first.SequenceEqual(second));
        Check(!Encoding.UTF8.GetString(first).Contains("archive note"));
        var opened = PortableHistory.Open(first, phrase.Normalize(NormalizationForm.FormD)); Check(opened.Items[0].Text == state.Items[0].Text && opened.Items[0].Tags.SequenceEqual(new[] { "reference" }) && opened.Items[0].Pinned);
        Refuses(() => PortableHistory.Open(first, phrase + "wrong"));
        Refuses(() => PortableHistory.Seal(state, "short"));
        Refuses(() => PortableHistory.Open(first[..39], phrase));
        Refuses(() => PortableHistory.Open(first[..^1], phrase));
        Refuses(() => PortableHistory.Open(first.Concat(new byte[] { 0 }).ToArray(), phrase));
        foreach (int offset in new[] { 0, 8, 12, 28, 40, first.Length - 1 }) { byte[] tampered = first.ToArray(); tampered[offset] ^= 1; Refuses(() => PortableHistory.Open(tampered, phrase)); }
        string directory = Path.Combine(Path.GetTempPath(), "Cliphoard-archive-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string file = Path.Combine(directory, "synthetic.cliphoard-win"); PortableHistory.WriteAtomic(file, first); Check(File.ReadAllBytes(file).SequenceEqual(first)); PortableHistory.WriteAtomic(file, second); Check(File.ReadAllBytes(file).SequenceEqual(second)); Check(Directory.GetFiles(directory, "*.tmp").Length == 0);
            var store = new HistoryStore(Path.Combine(directory, "store")); store.State.Limit = 50; store.Add(new() { Text = "[CLIPHOARD_SYNTHETIC_V1] existing" });
            Check(store.Import(opened.Items, false) == 1 && store.State.Items.Count == 2); Check(store.Import(PortableHistory.Open(first, phrase).Items, false) == 0);
            var many = Enumerable.Range(0, 50).Select(i => new HistoryItem { Text = "[CLIPHOARD_SYNTHETIC_V1] extra " + i }).ToList(); byte[] before = File.ReadAllBytes(Path.Combine(directory, "store", "history.sqlite"));
            Refuses(() => store.Import(many, false)); Check(store.State.Items.Count == 2 && File.ReadAllBytes(Path.Combine(directory, "store", "history.sqlite")).SequenceEqual(before));
            Check(store.Import(many, true) == 50 && store.State.Items.Count == 52 && store.State.Limit == 500);
            var restored = new HistoryStore(Path.Combine(directory, "store")); Check(restored.Writable && restored.State.Items.Count == 52);
            Check(store.Import(Enumerable.Range(0, 20).Select(i => new HistoryItem { Text = "[CLIPHOARD_SYNTHETIC_V1] excessive pin " + i, Pinned = true }), false) == 20); Check(store.State.Items.Count == 72);
        }
        finally { Directory.Delete(directory, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { archive_checks = checks, status = "passed", data = "generated synthetic only" }));
    }
}
