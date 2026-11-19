using Cliphoard.Windows;
using System.Text.Json;

internal static class TagParityChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool condition) { ++checks; if (!condition) throw new Exception($"Synthetic tag parity check {checks} failed."); }
        Check(TagCatalog.BuiltIn.Length == 12);
        var state = new HistoryState();
        Check(TagCatalog.Compose(state).Names.Length == 0);
        state.TagOverlays = new() { "dev", "devops" };
        TagBasket composed = TagCatalog.Compose(state);
        Check(composed.Dimensions.Length == 4);
        Check(composed.Dimensions.Count(dimension => dimension.Name.StartsWith("Artifact", StringComparison.Ordinal)) == 2);
        Check(composed.Topical.Distinct().Count() == composed.Topical.Length);
        state.CustomBasket = true; state.CustomTagNames = new() { "synthetic-a", "synthetic-b" };
        Check(TagCatalog.Compose(state).IsFlat);
        var basket = new TagBasket("synthetic", "Synthetic", new[] { new TagDimension("Axis", new[] { "a", "b" }) }, new[] { "topic" }, Array.Empty<string>(), false);
        var vocabulary = new Dictionary<string, float[]> { ["a"] = new float[] { 1, 0 }, ["b"] = new float[] { 0, 1 }, ["topic"] = new float[] { 1, 0 } };
        AutomaticTag[] labels = TagCatalog.Classify(new float[] { 1, 0 }, basket, vocabulary, .28);
        Check(labels.SequenceEqual(new[] { new AutomaticTag("Axis", "a"), new AutomaticTag("", "topic") }));
        Check(TagCatalog.Classify(new float[] { .1f, .1f }, basket, vocabulary, .28).Length == 0);
        var documents = Enumerable.Range(0, 4).Select(index => new SemanticDocument(index.ToString(), "Synthetic note", new[] { "reference" }, Array.Empty<string>())).ToArray();
        var vectors = documents.ToDictionary(document => document.Id, _ => new float[] { 1, 0 });
        var centroids = TagCatalog.Centroids(documents, vectors);
        var target = new SemanticDocument("target", "Synthetic target", Array.Empty<string>(), Array.Empty<string>());
        Check(TagCatalog.Suggestions(target, new float[] { 1, 0 }, centroids, .4).SequenceEqual(new[] { "reference" }));
        Check(TagCatalog.Centroids(documents.Take(3).ToArray(), vectors).Count == 0);
        centroids["near-twin"] = new float[] { 1, 0 };
        Check(TagCatalog.Suggestions(target, new float[] { 1, 0 }, centroids, .4).Length == 0);
        Check(TagCatalog.Suggestions(target with { Dismissed = new[] { "reference" } }, new float[] { 1, 0 }, centroids, .4).Length == 0);
        using var engine = new SemanticEngine();
        await engine.PrepareAsync(false, CancellationToken.None, model: "hashing-256", dimension: 256);
        var searchable = new[]
        {
            new SemanticDocument("meal", "Synthetic restaurant delicious meal", new[] { "dinner" }, Array.Empty<string>()),
            new SemanticDocument("code", "Synthetic compiler source code", new[] { "development" }, Array.Empty<string>())
        };
        var general = TagCatalog.Compose(new HistoryState());
        SemanticSearchResult ranked = await engine.SearchAsync("restaurant", searchable, general, .28, "smart", .2, CancellationToken.None);
        Check(ranked.Matches.Contains("meal") && ranked.Scores["meal"] >= 10);
        ranked = await engine.SearchAsync("dinner", searchable, general, .28, "tag", .2, CancellationToken.None);
        Check(ranked.Matches.SetEquals(new[] { "meal" }));
        ranked = await engine.SearchAsync("irrelevant", searchable, general, .28, "neural", 1, CancellationToken.None);
        Check(ranked.Matches.Count == 0);
        ranked = await engine.SearchAsync("irrelevant", searchable, general, .28, "essence", 1, CancellationToken.None);
        Check(ranked.Matches.Count == 0);
        var shortDocument = new[] { new SemanticDocument("red", "red", Array.Empty<string>(), Array.Empty<string>()) };
        ranked = await engine.SearchAsync("red", shortDocument, general, .28, "neural", .58, CancellationToken.None);
        Check(ranked.Matches.Contains("red") && ranked.Scores["red"] > .99);
        ranked = await engine.SearchAsync("  RED  ", shortDocument, general, .28, "smart", .58, CancellationToken.None);
        Check(ranked.Matches.Contains("red") && ranked.Scores["red"] >= 10);
        Console.WriteLine(JsonSerializer.Serialize(new { tag_parity_checks = checks, status = "passed", built_in_baskets = 12 }));
    }
}
