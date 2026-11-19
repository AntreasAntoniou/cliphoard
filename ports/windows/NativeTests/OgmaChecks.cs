using System.Reflection;
using System.Text.Json;
using Cliphoard.Windows;

internal static class OgmaChecks
{
    internal static async Task RunAsync()
    {
        using var inventoryResource = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.MacModels.json") ?? throw new IOException("Mac model inventory missing.");
        using var inventory = JsonDocument.Parse(inventoryResource);
        if (!inventory.RootElement.GetProperty("models").EnumerateArray().Select(value => value.GetString()!).ToHashSet(StringComparer.Ordinal).SetEquals(ModelCatalog.MacModels)) throw new Exception("Windows omits a supported Mac model.");
        int checks = 1;
        double minimum = 1;
        var tokenizer = new OgmaTokenizer();
        foreach (string name in new[] { "open-ogma-micro", "open-ogma-small" })
        {
            await VerifiedModelAssets.EnsureAsync(OgmaModel.Weights(name), false, CancellationToken.None, null);
            using var model = new OgmaModel(name);
            using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures." + name + ".json") ?? throw new IOException("Ogma references missing.");
            using var golden = JsonDocument.Parse(resource);
            foreach (var sample in golden.RootElement.GetProperty("samples").EnumerateArray())
            {
                string text = sample.GetProperty("text").GetString()!;
                if (!tokenizer.Encode(text).SequenceEqual(sample.GetProperty("tokens").EnumerateArray().Select(value => value.GetInt64()))) throw new Exception("Ogma tokenizer parity failed.");
                ++checks;
                foreach (int dimension in new[] { 384, 1024 })
                {
                    float[] actual = model.Embed(text, sample.GetProperty("task").GetInt32(), dimension, CancellationToken.None);
                    float[] expected = sample.GetProperty(dimension == 384 ? "small" : "large").EnumerateArray().Select(value => value.GetSingle()).ToArray();
                    double cosine = SemanticEngine.Dot(actual, expected) / Math.Sqrt(SemanticEngine.Dot(actual, actual) * SemanticEngine.Dot(expected, expected));
                    minimum = Math.Min(minimum, cosine);
                    if (cosine < .99999) throw new Exception("Ogma embedding parity failed.");
                    ++checks;
                }
            }
        }
        Console.WriteLine(JsonSerializer.Serialize(new { ogma_checks = checks, minimum_cosine = minimum, status = "passed", both_heads = true, tasks = "query/document/symmetric" }));
    }
}
