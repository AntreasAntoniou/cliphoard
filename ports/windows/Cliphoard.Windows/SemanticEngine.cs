using System.Globalization;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace Cliphoard.Windows;

/// Verified, local CPU inference. Only the explicit preparation action accesses the network.
internal sealed class SemanticEngine : IDisposable
{
    internal const string Revision = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41";
    internal const string Signature = "all-MiniLM-L6-v2-" + Revision + "-mean-384";
    private const string Origin = "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/" + Revision + "/";
    private readonly EmbeddingCache? durable;
    internal SemanticEngine(EmbeddingCache? durable = null) { this.durable = durable; }
    private string CacheSignature => Model + ":" + Dimension + ":" + (Model switch
    {
        "all-MiniLM-L6-v2" => Signature,
        "embeddinggemma-2-740m" => GemmaAssets.Model.Sha256 + GemmaAssets.Runtime.Sha256,
        "open-ogma-micro" or "open-ogma-small" => OgmaModel.Weights(Model).Sha256,
        _ => "hashing-256"
    }) + ":document-v1";
    private readonly SemaphoreSlim gate = new(1);
    private readonly Dictionary<string, float[]> vectors = new();
    private readonly Dictionary<string, float[]> tagVectors = new();
    private InferenceSession? session;
    private WordPiece? tokenizer;
    private bool disposed;
    private OgmaModel? ogma;
    private GemmaWorkerClient? gemma;
    internal string Model { get; private set; } = "all-MiniLM-L6-v2";
    internal int Dimension { get; private set; } = 384;
    internal bool Ready => !disposed && (Model switch
    {
        "hashing-256" => true,
        "embeddinggemma-2-740m" => gemma?.Ready == true,
        "open-ogma-micro" or "open-ogma-small" => ogma is not null,
        _ => session is not null
    });
    internal static string CacheDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cliphoard", "models", Revision);

    internal async Task PrepareAsync(bool download, CancellationToken cancellation, IProgress<string>? progress = null, string model = "all-MiniLM-L6-v2", int dimension = 384)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!ModelCatalog.Supports(model, dimension))
                throw new ArgumentException("Unknown semantic model or projection head.");
            if (Model != model || Dimension != dimension)
            {
                session?.Dispose(); session = null; ogma?.Dispose(); ogma = null;
                if (gemma is not null && !gemma.Ready) { gemma.Dispose(); gemma = null; }
                foreach (var vector in vectors.Values.Concat(tagVectors.Values)) Array.Clear(vector);
                vectors.Clear(); tagVectors.Clear(); Model = model; Dimension = dimension;
            }
            if (Ready) return;
            if (model == "embeddinggemma-2-740m")
            {
                gemma?.Dispose(); gemma = null;
                var next = new GemmaWorkerClient();
                try { await next.PrepareAsync(download, cancellation, progress); gemma = next; }
                catch { next.Dispose(); throw; }
                return;
            }
            if (model.StartsWith("open-ogma-", StringComparison.Ordinal))
            {
                await VerifiedModelAssets.EnsureAsync(OgmaModel.Weights(model), download, cancellation, progress);
                cancellation.ThrowIfCancellationRequested();
                var next = new OgmaModel(model);
                if (cancellation.IsCancellationRequested) { next.Dispose(); cancellation.ThrowIfCancellationRequested(); }
                ogma = next;
                return;
            }
            string directory = CacheDirectory;
            Directory.CreateDirectory(directory);
            for (DirectoryInfo? parent = new(directory); parent is not null; parent = parent.Parent)
                if ((parent.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Model cache contains a link.");
            foreach (var asset in new[]
            {
                (Remote: "onnx/model.onnx", Local: "model.onnx", Size: 90405214L, Hash: "6fd5d72fe4589f189f8ebc006442dbb529bb7ce38f8082112682524616046452"),
                (Remote: "vocab.txt", Local: "vocab.txt", Size: 231508L, Hash: "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3")
            })
            {
                string path = Path.Combine(directory, asset.Local);
                if (!File.Exists(path))
                {
                    if (!download) throw new FileNotFoundException("Prepare the semantic model in Search settings.");
                    string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    try
                    {
                        using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
                        using var response = await client.GetAsync(Origin + asset.Remote, HttpCompletionOption.ResponseHeadersRead, cancellation);
                        response.EnsureSuccessStatusCode();
                        if (response.Content.Headers.ContentLength is long declared && declared != asset.Size) throw new IOException("Unexpected model size.");
                        await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                        await using (var input = await response.Content.ReadAsStreamAsync(cancellation))
                        {
                            byte[] buffer = new byte[65536];
                            long total = 0;
                            int count;
                            while ((count = await input.ReadAsync(buffer, cancellation)) != 0)
                            {
                                total += count;
                                if (total > asset.Size) throw new IOException("Model exceeds its pinned size.");
                                await output.WriteAsync(buffer.AsMemory(0, count), cancellation);
                                progress?.Report($"Downloading semantic model · {total * 100 / asset.Size}%");
                            }
                            output.Flush(true);
                        }
                        Verify(temporary, asset.Size, asset.Hash);
                        cancellation.ThrowIfCancellationRequested();
                        File.Move(temporary, path);
                    }
                    finally { if (File.Exists(temporary)) File.Delete(temporary); }
                }
                Verify(path, asset.Size, asset.Hash);
            }
            cancellation.ThrowIfCancellationRequested();
            progress?.Report("Loading local semantic model…");
            byte[] modelBytes = ReadVerified(Path.Combine(directory, "model.onnx"), 90405214, "6fd5d72fe4589f189f8ebc006442dbb529bb7ce38f8082112682524616046452");
            byte[] vocabularyBytes = ReadVerified(Path.Combine(directory, "vocab.txt"), 231508, "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3");
            try
            {
                var words = new List<string>();
                using (var reader = new StringReader(new UTF8Encoding(false, true).GetString(vocabularyBytes)))
                {
                    string? line;
                    while ((line = reader.ReadLine()) is not null) words.Add(line);
                }
                var nextTokenizer = new WordPiece(words.ToArray());
                using var options = new SessionOptions { IntraOpNumThreads = 2, InterOpNumThreads = 1 };
                var nextSession = new InferenceSession(modelBytes, options);
                if (cancellation.IsCancellationRequested) { nextSession.Dispose(); cancellation.ThrowIfCancellationRequested(); }
                tokenizer = nextTokenizer;
                session = nextSession;
            }
            finally { CryptographicOperations.ZeroMemory(modelBytes); CryptographicOperations.ZeroMemory(vocabularyBytes); }
        }
        finally { gate.Release(); }
    }
    private static void Verify(string path, long size, string expected)
    {
        byte[] bytes = ReadVerified(path, checked((int)size), expected);
        CryptographicOperations.ZeroMemory(bytes);
    }
    internal static byte[] ReadVerified(string path, int size, string expected)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Model cache contains a link.");
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (input.Length != size || size is < 1 or > 100000000) throw new IOException("Unexpected model size.");
        byte[] bytes = new byte[size];
        try
        {
            input.ReadExactly(bytes);
            if (input.ReadByte() != -1 || !Convert.ToHexString(SHA256.HashData(bytes)).Equals(expected, StringComparison.OrdinalIgnoreCase)) throw new IOException("Model verification failed.");
            return bytes;
        }
        catch { CryptographicOperations.ZeroMemory(bytes); throw; }
    }
    internal async Task<float[]> EmbedAsync(string text, CancellationToken cancellation = default)
    {
        await gate.WaitAsync(cancellation);
        try { return Embed(text, cancellation); }
        finally { gate.Release(); }
    }
    private float[] Embed(string text, CancellationToken cancellation, bool query = false)
    {
        cancellation.ThrowIfCancellationRequested();
        if (Model == "hashing-256") return HashingModel.Embed(text);
        if (Model == "embeddinggemma-2-740m" && gemma is not null) return gemma.EmbedAsync(text, query, cancellation).GetAwaiter().GetResult();
        if (ogma is not null) return ogma.Embed(text, query ? 4 : 5, Dimension, cancellation);
        if (!Ready || tokenizer is null) throw new InvalidOperationException("Semantic model is unavailable.");
        long[] tokens = tokenizer.Encode(text);
        int length = tokens.Length;
        var shape = new[] { 1, length };
        var inputs = new[]
        {
            NamedOnnxValue.CreateFromTensor("input_ids", new DenseTensor<long>(tokens, shape)),
            NamedOnnxValue.CreateFromTensor("attention_mask", new DenseTensor<long>(Enumerable.Repeat(1L, length).ToArray(), shape)),
            NamedOnnxValue.CreateFromTensor("token_type_ids", new DenseTensor<long>(new long[length], shape))
        };
        using var output = session!.Run(inputs);
        var hidden = output.First().AsTensor<float>();
        if (hidden.Rank != 3 || hidden.Dimensions[0] != 1 || hidden.Dimensions[1] != length || hidden.Dimensions[2] != 384) throw new IOException("Unexpected embedding model output.");
        var vector = new float[384];
        for (int token = 0; token < length; ++token)
            for (int dimension = 0; dimension < vector.Length; ++dimension)
                vector[dimension] += hidden[0, token, dimension] / length;
        double norm = Math.Sqrt(vector.Sum(value => (double)value * value));
        if (!double.IsFinite(norm) || norm < 1e-12) throw new IOException("Invalid model vector.");
        for (int i = 0; i < vector.Length; ++i) vector[i] = (float)(vector[i] / norm);
        cancellation.ThrowIfCancellationRequested();
        return vector;
    }
    internal async Task<Dictionary<string, double>> RankAsync(string query, IReadOnlyList<(string Id, string Text)> documents, CancellationToken cancellation)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            var result = new Dictionary<string, double>();
            float[] question = Embed(query, cancellation, query: true);
            var keep = new HashSet<string>();
            foreach (var document in documents)
            {
                cancellation.ThrowIfCancellationRequested();
                string key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(document.Text)));
                keep.Add(key);
                if (!vectors.TryGetValue(key, out float[]? vector)) vectors[key] = vector = Embed(document.Text, cancellation);
                result[document.Id] = Dot(question, vector);
            }
            foreach (string key in vectors.Keys.Where(key => !keep.Contains(key)).ToArray()) vectors.Remove(key);
            return result;
        }
        finally { gate.Release(); }
    }
    internal async Task<SemanticSearchResult> SearchAsync(string query, IReadOnlyList<SemanticDocument> documents, TagBasket basket, double threshold, string mode, double relevanceFloor, CancellationToken cancellation, IProgress<(int Done, int Total)>? progress = null)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            var vocabulary = new Dictionary<string, float[]>();
            foreach (string name in basket.Names.Distinct(StringComparer.Ordinal))
            {
                cancellation.ThrowIfCancellationRequested();
                string identity = Model + ":" + Dimension + ":" + name;
                if (!tagVectors.TryGetValue(identity, out float[]? vector)) tagVectors[identity] = vector = Embed(name, cancellation);
                vocabulary[name] = vector;
            }
            var documentVectors = new Dictionary<string, float[]>();
            var labels = new Dictionary<string, AutomaticTag[]>();
            var keep = new HashSet<string>();
            int done = 0;
            foreach (SemanticDocument document in documents)
            {
                cancellation.ThrowIfCancellationRequested();
                string identity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(document.Text)));
                keep.Add(identity);
                if (!vectors.TryGetValue(identity, out float[]? vector))
                {
                    vector = durable?.Read(document.Id, CacheSignature, document.Text, Dimension);
                    if (vector is null) { vector = Embed(document.Text, cancellation); durable?.Write(document.Id, CacheSignature, document.Text, vector, cancellation); }
                    vectors[identity] = vector;
                }
                documentVectors[document.Id] = vector;
                labels[document.Id] = TagCatalog.Classify(vector, basket, vocabulary, threshold);
                progress?.Report((++done, documents.Count));
            }
            foreach (string identity in vectors.Keys.Where(identity => !keep.Contains(identity)).ToArray()) vectors.Remove(identity);
            var centroids = TagCatalog.Centroids(documents, documentVectors);
            var suggestions = documents.ToDictionary(document => document.Id, document => TagCatalog.Suggestions(document, documentVectors[document.Id], centroids, relevanceFloor));
            var scores = new Dictionary<string, double>();
            var matches = new HashSet<string>();
            if (string.IsNullOrWhiteSpace(query)) return new(scores, labels, suggestions, matches);
            float[] question = Embed(query, cancellation, query: true);
            AutomaticTag[] queryLabels = TagCatalog.Labels(basket).Select(label => (Label: label, Score: Dot(question, vocabulary[label.Name])))
                .Where(pair => pair.Score >= threshold).OrderByDescending(pair => pair.Score).Take(3).Select(pair => pair.Label).ToArray();
            var queryKeys = queryLabels.Select(label => label.Key).ToHashSet(StringComparer.Ordinal);
            string normalized = query.Trim().TrimStart('#').ToLowerInvariant();
            bool manualTag = documents.Any(document => document.UserTags.Contains(normalized, StringComparer.OrdinalIgnoreCase));
            foreach (SemanticDocument document in documents)
            {
                bool exact = document.Text.Contains(query.Trim(), StringComparison.OrdinalIgnoreCase);
                double confidence = exact ? 1 : Math.Min(1, new StringInfo(document.Text).LengthInTextElements / 12.0);
                double similarity = Dot(question, documentVectors[document.Id]) * confidence;
                double score = similarity;
                if (mode == "smart")
                {
                    int shared = labels[document.Id].Count(label => queryKeys.Contains(label.Key));
                    bool tagMatch = document.UserTags.Any(tag => tag.Equals(normalized, StringComparison.OrdinalIgnoreCase) || queryLabels.Any(label => label.Name.Equals(tag, StringComparison.OrdinalIgnoreCase)));
                    score += Math.Min(shared, 2) * .10 * confidence + (tagMatch ? 3 : 0) + (exact ? 10 : 0);
                    if (exact || score >= relevanceFloor - .02) matches.Add(document.Id);
                }
                else if (mode == "tag")
                {
                    bool hit = manualTag ? document.UserTags.Contains(normalized, StringComparer.OrdinalIgnoreCase)
                        : queryLabels.Length > 0 && labels[document.Id].Any(label => label.Key == queryLabels[0].Key);
                    score = hit ? 1 : 0;
                    if (hit) matches.Add(document.Id);
                }
                else if (similarity >= relevanceFloor) matches.Add(document.Id);
                scores[document.Id] = score;
            }
            cancellation.ThrowIfCancellationRequested();
            return new(scores, labels, suggestions, matches);
        }
        finally { gate.Release(); }
    }
    internal bool MediaReady => gemma?.Ready == true;
    internal async Task PrepareMediaAsync(bool download, CancellationToken cancellation, IProgress<string>? progress)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (gemma?.Ready == true) return;
            gemma?.Dispose();
            var next = new GemmaWorkerClient();
            try { await next.PrepareAsync(download, cancellation, progress); gemma = next; }
            catch { next.Dispose(); throw; }
        }
        finally { gate.Release(); }
    }
    internal async Task<float[]> EmbedMediaAsync(string text, bool query, CancellationToken cancellation, byte[]? image = null, byte[]? audio = null)
    {
        await gate.WaitAsync(cancellation);
        try { return await (gemma ?? throw new IOException("Prepare Gemma in Search settings.")).EmbedAsync(text, query, cancellation, image, audio); }
        finally { gate.Release(); }
    }
    internal static double Dot(float[] first, float[] second) => first.Zip(second, (a, b) => (double)a * b).Sum();
    internal async Task ClearAsync()
    {
        await gate.WaitAsync();
        try { foreach (var vector in vectors.Values.Concat(tagVectors.Values)) Array.Clear(vector); vectors.Clear(); tagVectors.Clear(); gemma?.Dispose(); gemma = null; }
        finally { gate.Release(); }
    }
    public void Dispose()
    {
        gate.Wait();
        try { disposed = true; session?.Dispose(); session = null; ogma?.Dispose(); ogma = null; gemma?.Dispose(); gemma = null; foreach (var vector in vectors.Values.Concat(tagVectors.Values)) Array.Clear(vector); vectors.Clear(); tagVectors.Clear(); }
        finally { gate.Release(); }
    }
}

/// BERT uncased basic tokenizer and greedy WordPiece, bounded to the model's 256-token contract.
internal sealed class WordPiece
{
    private readonly Dictionary<string, long> vocabulary;
    internal WordPiece(string[] words) => vocabulary = words.Select((word, index) => (word, index)).ToDictionary(pair => pair.word, pair => (long)pair.index, StringComparer.Ordinal);
    internal long[] Encode(string text, int maximumLength = 256)
    {
        var ids = new List<long> { 101 };
        foreach (string word in WithSpecialTokens(text))
        {
            if (ids.Count >= maximumLength - 1) break;
            if (word is "[UNK]" or "[SEP]" or "[PAD]" or "[CLS]" or "[MASK]") { ids.Add(vocabulary[word]); continue; }
            var pieces = new List<long>();
            int start = 0;
            if (word.EnumerateRunes().Count() > 100) { ids.Add(100); continue; }
            while (start < word.Length)
            {
                int end = word.Length;
                long found = -1;
                while (end > start)
                {
                    if (vocabulary.TryGetValue((start == 0 ? "" : "##") + word[start..end], out found)) break;
                    found = -1;
                    --end;
                    if (end > start && char.IsLowSurrogate(word[end])) --end;
                }
                if (found < 0) { pieces.Clear(); pieces.Add(100); break; }
                pieces.Add(found);
                start = end;
            }
            ids.AddRange(pieces.Take(maximumLength - 1 - ids.Count));
        }
        ids.Add(102);
        return ids.ToArray();
    }
    private static IEnumerable<string> WithSpecialTokens(string text)
    {
        int position = 0;
        foreach (System.Text.RegularExpressions.Match match in System.Text.RegularExpressions.Regex.Matches(text, @"\[(?:UNK|SEP|PAD|CLS|MASK)\]", System.Text.RegularExpressions.RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100)))
        {
            foreach (string word in Basic(text[position..match.Index])) yield return word;
            yield return match.Value;
            position = match.Index + match.Length;
        }
        foreach (string word in Basic(text[position..])) yield return word;
    }
    private static IEnumerable<string> Basic(string input)
    {
        var word = new StringBuilder();
        foreach (Rune rune in input.ToLowerInvariant().Normalize(NormalizationForm.FormD).EnumerateRunes())
        {
            int value = rune.Value;
            var category = Rune.GetUnicodeCategory(rune);
            if (category == UnicodeCategory.NonSpacingMark || value is 0 or 0xfffd) continue;
            bool whitespace = Rune.IsWhiteSpace(rune);
            if (!whitespace && category is UnicodeCategory.Control or UnicodeCategory.Format) continue;
            bool separate = value is >= 0x21 and <= 0x2f or >= 0x3a and <= 0x40 or >= 0x5b and <= 0x60 or >= 0x7b and <= 0x7e or >= 0x4e00 and <= 0x9fff or >= 0x3400 and <= 0x4dbf or >= 0x20000 and <= 0x2fa1f or >= 0xf900 and <= 0xfaff || category is UnicodeCategory.ConnectorPunctuation or UnicodeCategory.DashPunctuation or UnicodeCategory.OpenPunctuation or UnicodeCategory.ClosePunctuation or UnicodeCategory.InitialQuotePunctuation or UnicodeCategory.FinalQuotePunctuation or UnicodeCategory.OtherPunctuation;
            if (whitespace || separate)
            {
                if (word.Length > 0) { yield return word.ToString(); word.Clear(); }
                if (separate) yield return rune.ToString();
            }
            else word.Append(rune.ToString());
        }
        if (word.Length > 0) yield return word.ToString();
    }
}
