using System.Text.Json;

namespace Cliphoard.Windows;

internal sealed record TagDimension(string Name, string[] Tags);
internal sealed record TagBasket(string Id, string Name, TagDimension[] Dimensions, string[] Topical, string[] FlatTags, bool IsFlat)
{
    internal string[] Names => IsFlat ? FlatTags : Dimensions.SelectMany(dimension => dimension.Tags).Concat(Topical).ToArray();
}
internal sealed record AutomaticTag(string Axis, string Name)
{
    internal string Key => Axis + "\0" + Name;
    public override string ToString() => Axis.Length == 0 ? Name : Axis + ": " + Name;
}
internal static class TagCatalog
{
    internal static readonly TagBasket[] BuiltIn = Load();
    private static TagBasket[] Load()
    {
        using var resource = typeof(TagCatalog).Assembly.GetManifestResourceStream("Cliphoard.Windows.TagBaskets.json") ?? throw new IOException("Tag catalog is missing.");
        return JsonSerializer.Deserialize<TagBasket[]>(resource, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new IOException("Invalid tag catalog.");
    }
    internal static TagBasket Compose(HistoryState state)
    {
        if (state.CustomBasket) return new("custom", "Custom", Array.Empty<TagDimension>(), Array.Empty<string>(), state.CustomTagNames.ToArray(), true);
        var dimensions = new List<TagDimension>();
        var topical = new List<string>();
        foreach (string id in state.TagOverlays)
        {
            TagBasket? basket = BuiltIn.FirstOrDefault(basket => basket.Id == id);
            if (basket is null) continue;
            foreach (TagDimension dimension in basket.Dimensions)
            {
                string name = dimensions.Any(existing => existing.Name == dimension.Name) ? dimension.Name + " (" + basket.Name + ")" : dimension.Name;
                dimensions.Add(new(name, dimension.Tags));
            }
            topical.AddRange(basket.Topical);
        }
        return new("composed", "General", dimensions.ToArray(), topical.Distinct(StringComparer.Ordinal).ToArray(), Array.Empty<string>(), false);
    }
    internal static AutomaticTag[] Labels(TagBasket basket) => basket.IsFlat
        ? basket.FlatTags.Select(name => new AutomaticTag("", name)).ToArray()
        : basket.Dimensions.SelectMany(dimension => dimension.Tags.Select(name => new AutomaticTag(dimension.Name, name)))
            .Concat(basket.Topical.Select(name => new AutomaticTag("", name))).ToArray();
    internal static AutomaticTag[] Classify(float[] vector, TagBasket basket, IReadOnlyDictionary<string, float[]> vocabulary, double threshold)
    {
        var result = new List<AutomaticTag>();
        foreach (TagDimension dimension in basket.Dimensions)
        {
            var best = dimension.Tags.Select(name => (Name: name, Score: SemanticEngine.Dot(vector, vocabulary[name]))).OrderByDescending(pair => pair.Score).FirstOrDefault();
            if (best.Name is not null && best.Score >= threshold) result.Add(new(dimension.Name, best.Name));
        }
        string[] pool = basket.IsFlat ? basket.FlatTags : basket.Topical;
        result.AddRange(pool.Select(name => (Name: name, Score: SemanticEngine.Dot(vector, vocabulary[name])))
            .Where(pair => pair.Score >= threshold).OrderByDescending(pair => pair.Score).Take(basket.IsFlat ? 5 : 3).Select(pair => new AutomaticTag("", pair.Name)));
        return result.ToArray();
    }
    internal static Dictionary<string, float[]> Centroids(IReadOnlyList<SemanticDocument> documents, IReadOnlyDictionary<string, float[]> vectors)
    {
        var result = new Dictionary<string, float[]>(StringComparer.Ordinal);
        foreach (var group in documents.SelectMany(member => member.UserTags.Select(tag => (Tag: tag, Document: member))).GroupBy(pair => pair.Tag, StringComparer.Ordinal))
        {
            if (group.Count() < 4) continue;
            float[][] members = group.Where(pair => vectors.ContainsKey(pair.Document.Id)).Select(pair => vectors[pair.Document.Id]).ToArray();
            if (members.Length < 4) continue;
            float[] mean = Enumerable.Range(0, members[0].Length).Select(index => members.Average(member => member[index])).ToArray();
            double norm = Math.Sqrt(mean.Sum(value => (double)value * value));
            if (norm < 1e-12) continue;
            for (int index = 0; index < mean.Length; ++index) mean[index] = (float)(mean[index] / norm);
            result[group.Key] = mean;
        }
        return result;
    }
    internal static string[] Suggestions(SemanticDocument document, float[] vector, IReadOnlyDictionary<string, float[]> centroids, double relevanceFloor)
    {
        var candidates = centroids.Where(pair => !document.UserTags.Contains(pair.Key) && pair.Value.Length == vector.Length)
            .Select(pair => (Tag: pair.Key, Score: SemanticEngine.Dot(vector, pair.Value))).ToList();
        candidates = candidates.OrderByDescending(pair => pair.Score).ThenBy(pair => pair.Tag, StringComparer.Ordinal).ToList();
        var accepted = new List<string>();
        double floor = relevanceFloor + .30 * (1 - relevanceFloor);
        for (int index = 0; index < candidates.Count; ++index)
        {
            var candidate = candidates[index];
            if (index + 1 < candidates.Count && candidate.Score - candidates[index + 1].Score < .05 || candidate.Score < floor) break;
            if (!document.Dismissed.Contains(candidate.Tag)) accepted.Add(candidate.Tag);
            if (accepted.Count == 3) break;
        }
        return accepted.ToArray();
    }
}
internal sealed record SemanticDocument(string Id, string Text, string[] UserTags, string[] Dismissed);
internal sealed record SemanticSearchResult(Dictionary<string, double> Scores, Dictionary<string, AutomaticTag[]> Tags, Dictionary<string, string[]> Suggestions, HashSet<string> Matches);
