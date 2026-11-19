namespace Cliphoard.Windows;

internal sealed record TextModelInfo(string Id, string Title, int Dimension, bool OgmaHeads = false);
internal static class ModelCatalog
{
    internal static readonly TextModelInfo[] Text =
    {
        new("hashing-256", "Basic matching · Built in", 256),
        new("open-ogma-micro", "Low · Ogma Micro", 1024, true),
        new("open-ogma-small", "Normal · Ogma Small", 1024, true),
        new("all-MiniLM-L6-v2", "High · MiniLM", 384),
        new("embeddinggemma-2-740m", "EmbeddingGemma 2 · 768 dimensions", 768)
    };
    internal static readonly string[] Images = { "openvision-tiny-p8", "embeddinggemma-2-740m" };
    internal static readonly Dictionary<string, string> Speech = new()
    {
        ["small"] = "openai_whisper-small",
        ["largeV3"] = "openai_whisper-large-v3",
        ["turbo"] = "openai_whisper-large-v3-v20240930_turbo"
    };
    internal static int Dimension(string model, int ogmaDimension)
    {
        var entry = Text.FirstOrDefault(entry => entry.Id == model) ?? throw new ArgumentException("Unknown semantic model.");
        if (ogmaDimension is not (384 or 1024)) throw new ArgumentException("Unknown Ogma projection head.");
        return entry.OgmaHeads ? ogmaDimension : entry.Dimension;
    }
    internal static bool Supports(string model, int dimension)
    {
        var entry = Text.FirstOrDefault(entry => entry.Id == model);
        return entry is not null && (entry.OgmaHeads ? dimension is 384 or 1024 : dimension == entry.Dimension);
    }
    internal static IEnumerable<string> MacModels => Text.Select(model => model.Id).Concat(Images).Concat(Speech.Values).Distinct(StringComparer.Ordinal);
}
