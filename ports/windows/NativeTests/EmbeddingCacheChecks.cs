using Cliphoard.Windows;
using System.Text.Json;
internal static class EmbeddingCacheChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Index cache check {checks} failed"); }
        string folder = Path.Combine(Path.GetTempPath(), "CliphoardIndexFixture-" + Guid.NewGuid().ToString("N"));
        string id = Guid.NewGuid().ToString("N"), other = Guid.NewGuid().ToString("N");
        var cache = new EmbeddingCache(folder);
        try
        {
            Check(cache.Read(id, "model1", "synthetic", 2) is null);
            cache.Write(id, "model1", "synthetic", new[] { .6f, .8f }, default);
            float[]? first = new EmbeddingCache(folder).Read(id, "model1", "synthetic", 2);
            Check(first is not null && Math.Abs(first[0] - .6) < .001);
            Check(first is not null && Math.Abs(SemanticEngine.Dot(first, first) - 1) < .00001);
            Check(cache.Read(id, "model1", "replacement", 2) is null);
            Check(cache.Read(id, "model1", "synthetic", 3) is null);
            cache.Write(id, "model2", "synthetic", new[] { 1f, 0f }, default);
            Check(Directory.GetFiles(folder).Length == 2);
            cache.Write(other, "model1", "different", new[] { 0f, 1f }, default);
            cache.Retain(new HashSet<string> { id }); Check(Directory.GetFiles(folder).Length == 2);
            string path = Directory.GetFiles(folder).First();
            byte[] corrupt = File.ReadAllBytes(path); corrupt[^1] ^= 1; File.WriteAllBytes(path, corrupt);
            Check(cache.Read(id, "model1", "synthetic", 2) is null || cache.Read(id, "model2", "synthetic", 2) is null);
            cache.Forget(); Check(Directory.GetFiles(folder).Length == 0);
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            try { cache.Write(id, "model1", "synthetic", new[] { 1f }, cancelled.Token); Check(false); } catch (OperationCanceledException) { Check(Directory.GetFiles(folder).Length == 0); }
            var documents = new[] { new SemanticDocument(id, "synthetic local document", Array.Empty<string>(), Array.Empty<string>()) };
            using (var engine = new SemanticEngine(cache)) { await engine.PrepareAsync(false, default, model: "hashing-256", dimension: 256); await engine.SearchAsync("local", documents, TagCatalog.BuiltIn[0], .28, "smart", .2, default); }
            Check(Directory.GetFiles(folder).Length == 1);
            using (var engine = new SemanticEngine(new EmbeddingCache(folder))) { await engine.PrepareAsync(false, default, model: "hashing-256", dimension: 256); var result = await engine.SearchAsync("local", documents, TagCatalog.BuiltIn[0], .28, "smart", .2, default); Check(result.Matches.Contains(id)); }
            float[] picture = new float[192]; picture[3] = 1;
            cache.Write(id, "image:openvision-tiny-p8:v1", "synthetic-pixel-fingerprint", picture, default);
            float[]? restored = new EmbeddingCache(folder).Read(id, "image:openvision-tiny-p8:v1", "synthetic-pixel-fingerprint", 192);
            Check(restored is not null && restored[3] == 1);
            Check(cache.Read(id, "image:openvision-tiny-p8:v1", "changed-pixels", 192) is null);
            Check(cache.Read(id, "image:embeddinggemma-2-740m:v1", "synthetic-pixel-fingerprint", 768) is null);
            Check(cache.Read(id, "image:openvision-tiny-p8:v1", "synthetic-pixel-fingerprint", 768) is null);
            cache.Forget(); Check(Directory.GetFiles(folder).Length == 0);
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { embedding_cache_checks = checks, status = "passed" }));
    }
}
