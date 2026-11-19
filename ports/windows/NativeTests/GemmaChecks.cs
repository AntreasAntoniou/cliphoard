using System.Reflection;
using System.Text.Json;
using Cliphoard.Windows;

internal static class GemmaChecks
{
    internal static async Task RunAsync()
    {
        using var model = new GemmaWorkerClient();
        await model.PrepareAsync(false, CancellationToken.None, null);
        using var fixture = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.Gemma.json") ?? throw new IOException("Gemma references missing.");
        using var json = JsonDocument.Parse(fixture);
        int checks = 0;
        double minimum = 1;
        var vectors = new List<float[]>();
        byte[]? Media(JsonElement sample, string field)
        {
            if (sample.GetProperty(field).ValueKind == JsonValueKind.Null) return null;
            using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures." + sample.GetProperty(field).GetString()) ?? throw new IOException("Synthetic media is missing.");
            using var output = new MemoryStream(); source.CopyTo(output); return output.ToArray();
        }
        foreach (var sample in json.RootElement.GetProperty("samples").EnumerateArray())
        {
            float[] actual = await model.EmbedAsync(sample.GetProperty("text").GetString()!, sample.GetProperty("query").GetBoolean(), CancellationToken.None, image: Media(sample, "image"), audio: Media(sample, "audio"));
            vectors.Add(actual);
            float[] expected = sample.GetProperty("vector").EnumerateArray().Select(value => value.GetSingle()).ToArray();
            double cosine = SemanticEngine.Dot(actual, expected) / Math.Sqrt(SemanticEngine.Dot(actual, actual) * SemanticEngine.Dot(expected, expected));
            minimum = Math.Min(minimum, cosine);
            Console.WriteLine(JsonSerializer.Serialize(new { gemma_case = checks, cosine, actual_norm = SemanticEngine.Dot(actual, actual), reference_norm = SemanticEngine.Dot(expected, expected) }));
            bool multimodal = sample.GetProperty("image").ValueKind != JsonValueKind.Null || sample.GetProperty("audio").ValueKind != JsonValueKind.Null;
            // Quantized CPU kernels have measured cross-platform drift. Keep the tighter text gate.
            if (cosine < (multimodal ? .995 : .999)) throw new Exception("Gemma cross-platform vector parity failed.");
            ++checks;
        }
        if (SemanticEngine.Dot(vectors[0], vectors[1]) <= SemanticEngine.Dot(vectors[0], vectors[2])) throw new Exception("Gemma meaning retrieval ordering failed.");
        ++checks;
        using (var queryCancellation = new CancellationTokenSource())
        {
            Task<float[]> pending = model.EmbedAsync("Synthetic cancelled query", true, queryCancellation.Token);
            queryCancellation.Cancel();
            try { await pending; throw new Exception("Superseded Gemma query returned a result."); }
            catch (OperationCanceledException) { ++checks; }
            if (!model.Ready || (await model.EmbedAsync("Synthetic next query", true, CancellationToken.None)).Length != 768) throw new Exception("Typing cancellation killed the Gemma worker.");
            ++checks;
        }
        model.Dispose();
        using (var lifetime = new CancellationTokenSource())
        using (var revoked = new GemmaWorkerClient())
        {
            await revoked.PrepareAsync(false, lifetime.Token, null);
            Task<float[]> pending = revoked.EmbedAsync("Synthetic revoked session", true, CancellationToken.None);
            lifetime.Cancel();
            try { await pending; throw new Exception("Revoked Gemma worker returned a result."); }
            catch (Exception error) when (error is OperationCanceledException or IOException or ObjectDisposedException) { ++checks; }
            if (revoked.Ready) throw new Exception("Session cancellation retained Gemma readiness.");
            ++checks;
        }
        model.Dispose();
        if (model.Ready) throw new Exception("Gemma worker disposal did not revoke readiness.");
        ++checks;
        Console.WriteLine(JsonSerializer.Serialize(new { gemma_checks = checks, minimum_cosine = minimum, status = "passed", reference = "official macOS CPU runtime" }));
    }
}
