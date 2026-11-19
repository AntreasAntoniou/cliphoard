using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace Cliphoard.Windows;

internal sealed class OgmaModel : IDisposable
{
    internal static ModelAsset Weights(string model)
    {
        bool micro = model == "open-ogma-micro";
        if (!micro && model != "open-ogma-small") throw new ArgumentException("Unknown Ogma model.");
        string revision = micro ? "acb318a6f4411a42085838e674ebc2aed1219310" : "3f4cd68f43719ca494772fcc80005c115d8d91ff";
        return new(model + "-" + revision, "model.safetensors", $"https://huggingface.co/axiotic/{model}/resolve/{revision}/model.safetensors",
            micro ? 10024312 : 35845456, micro ? "0adf9dff70a6bbb3e792aa6ecca308f565af901f0188e4e51d7ff1c48483972d" : "c58c84e117a0e687b57dc1b50d8c9842398b4c7e7e9c1c806ad9a5eb98573b4b");
    }
    private readonly VerifiedGraph graph;
    private readonly OgmaTokenizer tokenizer = new();
    internal OgmaModel(string model) => graph = new VerifiedGraph(model, Weights(model));
    internal float[] Embed(string text, int task, int dimension, CancellationToken cancellation)
    {
        if (task is < 4 or > 6 || dimension is not (384 or 1024)) throw new ArgumentException("Invalid Ogma head or task.");
        long[] ids = tokenizer.Encode(text);
        var shape = new[] { 1, ids.Length };
        return graph.Run(new[]
        {
            NamedOnnxValue.CreateFromTensor("input_ids", new DenseTensor<long>(ids, shape)),
            NamedOnnxValue.CreateFromTensor("attention_mask", new DenseTensor<long>(Enumerable.Repeat(1L, ids.Length).ToArray(), shape)),
            NamedOnnxValue.CreateFromTensor("task_token_ids", new DenseTensor<long>(new[] { (long)task }, new[] { 1 }))
        }, dimension == 384 ? "embedding" : "embedding_large", dimension, cancellation);
    }
    public void Dispose() => graph.Dispose();
}

/// Libre SentencePiece vocabulary, NFKC normalization, Viterbi segmentation and UTF-8 byte fallback.
internal sealed class OgmaTokenizer
{
    private readonly Dictionary<string, (int Id, float Score)> vocabulary = new(StringComparer.Ordinal);
    private readonly int maximumPiece;
    internal OgmaTokenizer()
    {
        using var resource = VerifiedGraph.Resource("OgmaTokenizer");
        using var json = JsonDocument.Parse(resource);
        int id = 0;
        foreach (var entry in json.RootElement.EnumerateArray())
        {
            string piece = entry[0].GetString()!;
            vocabulary.Add(piece, (id++, entry[1].GetSingle()));
            maximumPiece = Math.Max(maximumPiece, piece.Length);
        }
    }
    internal long[] Encode(string text)
    {
        string normalized = text.Normalize(NormalizationForm.FormKC);
        int[] starts = StringInfo.ParseCombiningCharacters(normalized);
        if (starts.Length > 4096) normalized = normalized[..starts[4096]];
        var body = new List<long>();
        foreach (string word in normalized.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            body.AddRange(Unigram("▁" + word).Select(id => (long)id + 7));
            if (body.Count >= 254) break;
        }
        return new[] { 2L }.Concat(body.Take(254)).Append(3L).ToArray();
    }
    private IEnumerable<int> Unigram(string word)
    {
        int[] starts = StringInfo.ParseCombiningCharacters(word).Append(word.Length).ToArray();
        int length = starts.Length - 1;
        var best = Enumerable.Repeat(float.NegativeInfinity, length + 1).ToArray();
        var previous = new int[length + 1];
        var tokens = new int[length + 1][];
        best[0] = 0;
        for (int end = 1; end <= length; ++end)
        {
            for (int start = Math.Max(0, end - maximumPiece); start < end; ++start)
            {
                if (!vocabulary.TryGetValue(word[starts[start]..starts[end]], out var entry)) continue;
                float score = best[start] + entry.Score;
                if (score <= best[end]) continue;
                best[end] = score; previous[end] = start; tokens[end] = new[] { entry.Id };
            }
            if (!float.IsNegativeInfinity(best[end])) continue;
            best[end] = best[end - 1] - 25;
            previous[end] = end - 1;
            tokens[end] = Encoding.UTF8.GetBytes(word[starts[end - 1]..starts[end]]).Select(value => vocabulary[$"<0x{value:X2}>"].Id).ToArray();
        }
        var pieces = new List<int[]>();
        for (int end = length; end > 0; end = previous[end]) pieces.Add(tokens[end]);
        pieces.Reverse();
        return pieces.SelectMany(piece => piece);
    }
}
