using System.Reflection;
using System.Text.Json;
using Cliphoard.Windows;

internal static class OpenVisionChecks
{
    internal static async Task RunAsync()
    {
        await OpenVisionModel.EnsureAsync(false, CancellationToken.None, null);
        using var model = new OpenVisionModel();
        using var fixture = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.OpenVision.json") ?? throw new IOException("Image references missing.");
        using var json = JsonDocument.Parse(fixture);
        int checks = 0;
        double minimum = 1;
        void Check(float[] actual, JsonElement sample)
        {
            float[] expected = sample.GetProperty("vector").EnumerateArray().Select(value => value.GetSingle()).ToArray();
            double cosine = SemanticEngine.Dot(actual, expected) / Math.Sqrt(SemanticEngine.Dot(actual, actual) * SemanticEngine.Dot(expected, expected));
            minimum = Math.Min(minimum, cosine);
            if (cosine < .99999) throw new Exception("OpenVision vector parity failed.");
            ++checks;
        }
        foreach (var sample in json.RootElement.GetProperty("text").EnumerateArray())
        {
            string text = sample.GetProperty("text").GetString()!;
            if (!model.Tokens(text).SequenceEqual(sample.GetProperty("tokens").EnumerateArray().Select(value => value.GetInt64()))) throw new Exception("OpenVision tokenizer parity failed.");
            ++checks;
            Check(model.EmbedText(text, CancellationToken.None), sample);
        }
        foreach (var sample in json.RootElement.GetProperty("images").EnumerateArray())
        {
            float[] pixels = new float[3 * 224 * 224];
            Array.Fill(pixels, 1f, sample.GetProperty("channel").GetInt32() * 224 * 224, 224 * 224);
            Check(model.EmbedPixels(pixels, CancellationToken.None), sample);
        }
        var decoded = new List<float[]>();
        foreach (string color in new[] { "Red", "Blue" })
        {
            using var png = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.Synthetic" + color + ".png") ?? throw new IOException("Synthetic image missing.");
            using var bytes = new MemoryStream();
            png.CopyTo(bytes);
            var item = new HistoryItem { Kind = "Image", Payload = bytes.ToArray(), Format = 0 };
            float[] vector = model.EmbedPixels(await OpenVisionModel.PixelsAsync(item, CancellationToken.None), CancellationToken.None);
            Check(vector, json.RootElement.GetProperty("images")[color == "Red" ? 0 : 2]);
            decoded.Add(vector);
        }
        float[] mean = Enumerable.Range(0, 192).Select(index => decoded.Average(vector => vector[index])).ToArray();
        for (int index = 0; index < decoded.Count; ++index)
        {
            string query = index == 0 ? "a red picture" : "a blue picture";
            float[] question = OpenVisionModel.Center(model.EmbedText(query, CancellationToken.None), OpenVisionModel.TextMean);
            double[] scores = decoded.Select(vector => SemanticEngine.Dot(question, OpenVisionModel.Center(vector, mean))).ToArray();
            if (scores[index] < .08 || scores[index] <= scores[1 - index]) throw new Exception("Decoded image retrieval failed.");
            ++checks;
            var ranked = model.RankText(query, new Dictionary<string, float[]> { ["red"] = decoded[0], ["blue"] = decoded[1] }, default);
            if (Math.Abs(ranked[index == 0 ? "red" : "blue"] - scores[index]) > 1e-10) throw new Exception("Mac-reference ranking changed.");
            ++checks;
        }
        if (model.RankText("red", new Dictionary<string, float[]> { ["red"] = decoded[0] }, default).Count != 0) throw new Exception("Single-image centering admission changed.");
        ++checks;
        Console.WriteLine(JsonSerializer.Serialize(new { openvision_checks = checks, minimum_cosine = minimum, status = "passed", both_towers = true }));
    }
}
