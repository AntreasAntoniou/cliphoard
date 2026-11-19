using Cliphoard.Windows;
using System.Reflection;
using System.Text.Json;
internal static class MediaIndexChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Media index check {checks} failed"); }
        string folder = Path.Combine(Path.GetTempPath(), "CliphoardMediaIndexFixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
        try
        {
            string path = Path.Combine(folder, "synthetic-speech.wav");
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.SyntheticSpeech.wav")!)
            using (var file = File.Create(path)) await resource.CopyToAsync(file);
            using var engine = new SemanticEngine();
            MediaIndex index = await MediaIndexer.BuildAsync(path, "lightweight", "off", "small", false, false, engine, () => true, default);
            Check(index.Audio && !index.Video && index.Moments.Length == 1 && index.Moments[0].Modality == "audio");
            Check(index.FileUnchanged());
            float[] vector = MediaIndex.Unpack(index.Moments[0].Vector); Check(Math.Abs(vector.Sum(value => (double)value * value) - 1) < .00001); Array.Clear(vector);
            index = await MediaIndexer.BuildAsync(path, "balanced", "full", "small", false, false, engine, () => true, default);
            Check(index.Coverage == 1 && index.Moments.Any(moment => moment.Modality == "speech" && moment.Text!.Contains("restaurant", StringComparison.OrdinalIgnoreCase)));
            Check(index.Moments.Where(moment => moment.Modality == "speech").All(moment => moment.Start >= 0 && moment.End > moment.Start && moment.End <= index.Duration));
            Check(index.Moments.Where(moment => moment.Modality == "speech").Any(moment => moment.End < index.Duration));
            var history = new HistoryStore(Path.Combine(folder, "history"));
            history.Add(new() { Text = "synthetic indexed audio", MediaIndex = index });
            HistoryItem restored = new HistoryStore(Path.Combine(folder, "history")).State.Items.Single(); Check(restored.MediaIndex!.ContentHash == index.ContentHash && restored.MediaText.Contains("restaurant", StringComparison.OrdinalIgnoreCase));
            string before = SensitiveRevealState.Fingerprint(restored); restored.MediaIndex = index with { Speech = "sampled" }; Check(before != SensitiveRevealState.Fingerprint(restored));
            var flagged = new HistoryItem { Text = "synthetic", Flags = 128 }; Check(flagged.AnalysisVetoed); flagged.AnalysisNsfwAllowed = true; Check(!flagged.AnalysisVetoed); flagged.Flags |= 1; Check(flagged.AnalysisVetoed);
            var labelled = new HistoryItem { Text = "synthetic nsfw note" }; Check(labelled.AnalysisVetoed); labelled.AnalysisNsfwAllowed = true; Check(!labelled.AnalysisVetoed);
            bool refused = false; try { await MediaIndexer.BuildAsync(path, "balanced", "off", "small", false, false, engine, () => false, default); } catch (OperationCanceledException) { refused = true; } Check(refused);
            File.SetLastWriteTimeUtc(path, File.GetLastWriteTimeUtc(path).AddSeconds(1)); Check(!index.FileUnchanged());
            string a = Guid.NewGuid().ToString("D"), b = Guid.NewGuid().ToString("D"), c = Guid.NewGuid().ToString("D");
            var scores = RankFusion.Scores(new[] { new[] { a, b }, new[] { b, c } }); Check(scores[b] > scores[a] && scores[a] > scores[c]);
            Check(Math.Abs(RankFusion.Scores(new[] { new[] { a, a, b } })[a] - 1.0 / 61) < 1e-12);
        }
        finally { Directory.Delete(folder, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { media_index_checks = checks, status = "passed", generated_speech_only = true }));
    }
}
