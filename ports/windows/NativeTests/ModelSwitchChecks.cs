using Cliphoard.Windows;
using System.Text.Json;

internal static class ModelSwitchChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        using var engine = new SemanticEngine();
        var documents = new[] { (Id: "meal", Text: "The restaurant serves delicious meals."), (Id: "compiler", Text: "A compiler reports a syntax error.") };
        foreach (var choice in new[] { ("hashing-256",256), ("open-ogma-micro",384), ("open-ogma-micro",1024), ("open-ogma-small",384), ("open-ogma-small",1024), ("all-MiniLM-L6-v2",384), ("embeddinggemma-2-740m",768) })
        {
            await engine.PrepareAsync(false, CancellationToken.None, model: choice.Item1, dimension: choice.Item2);
            if (!engine.Ready || engine.Model != choice.Item1 || engine.Dimension != choice.Item2) throw new Exception("Model switch did not publish the selected identity.");
            ++checks;
            if ((await engine.EmbedAsync(documents[0].Text)).Length != choice.Item2) throw new Exception("Projection dimensions leaked across a model switch.");
            ++checks;
            var scores = await engine.RankAsync(choice.Item1 == "hashing-256" ? "restaurant meals" : "Where can I get something to eat?", documents, CancellationToken.None);
            if (scores["meal"] <= scores["compiler"]) throw new Exception("Model switch lost meaning retrieval.");
            ++checks;
        }
        await engine.PrepareAsync(false, CancellationToken.None);
        var before = await engine.RankAsync("Where can I get something to eat?", documents, CancellationToken.None);
        await engine.PrepareMediaAsync(false, CancellationToken.None, null);
        var after = await engine.RankAsync("Where can I get something to eat?", documents, CancellationToken.None);
        if (before.Any(pair => Math.Abs(pair.Value - after[pair.Key]) > 1e-7)) throw new Exception("Media preparation replaced the selected text encoder.");
        ++checks;
        await engine.PrepareAsync(false, CancellationToken.None, model: "open-ogma-small", dimension: 1024);
        if (!engine.MediaReady || (await engine.EmbedMediaAsync("Synthetic shared media query", true, CancellationToken.None)).Length != 768) throw new Exception("Text preparation revoked an independently prepared media model.");
        ++checks;
        await engine.ClearAsync();
        if (engine.MediaReady) throw new Exception("Media worker survived explicit revocation.");
        ++checks;
        string directory = Path.Combine(Path.GetTempPath(), "cliphoard-model-state-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new HistoryStore(directory);
            store.State.SemanticModel = "embeddinggemma-2-740m"; store.State.ImageModel = "embeddinggemma-2-740m"; store.State.OgmaDimension = 384; store.State.SpeechModel = "largeV3"; store.State.SearchMode = "image"; store.Save();
            var loaded = new HistoryStore(directory);
            if (loaded.State.SemanticModel != store.State.SemanticModel || loaded.State.ImageModel != store.State.ImageModel || loaded.State.OgmaDimension != 384 || loaded.State.SpeechModel != "largeV3" || loaded.State.SearchMode != "image") throw new Exception("Model preferences did not persist.");
            ++checks;
            var clip = new HistoryItem { Text = "[CLIPHOARD_SYNTHETIC_V1] audio reference", Transcript = "Synthetic local transcript" };
            byte[] archive = await MacHistoryArchive.SealAsync(new HistoryState { Items = new() { clip } }, "synthetic model archive 2026");
            if (MacHistoryArchive.Open(archive, "synthetic model archive 2026").Items.Single().Transcript != clip.Transcript) throw new Exception("Transcript archive roundtrip failed.");
            ++checks;
            loaded.Import(new[] { new HistoryItem { Text = "[CLIPHOARD_SYNTHETIC_V1] protected transcript", Transcript = "-----BEGIN PRIVATE KEY----- SYNTHETIC ONLY -----END PRIVATE KEY-----" } }, false);
            if (!loaded.State.Items.Single().AnalysisVetoed || loaded.State.Items.Single().SearchText.Length != 0) throw new Exception("Imported transcript bypassed analysis vetoes.");
            ++checks;
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { model_switch_checks = checks, status = "passed", projection_profiles = 7 }));
    }
}
