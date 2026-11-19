using System.Text;
using System.Text.Json;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Cliphoard.Windows;

internal sealed class OpenVisionModel : IDisposable
{
    private const string Revision = "a25ea3a2427415c197fedd2b52af390bbb3ead81";
    private const string Origin = "https://huggingface.co/UCSC-VLAA/openvision-vit-tiny-patch8-224/resolve/" + Revision + "/";
    internal static readonly ModelAsset Weights = new("openvision-" + Revision, "open_clip_pytorch_model.bin", Origin + "open_clip_pytorch_model.bin", 68493210, "96ddc70bf53cece1fac63b18dd0723a67f24226785bf5e705d35ba0d5bc0bf3f");
    internal static readonly ModelAsset Vocabulary = new("openvision-" + Revision, "vocab.txt", Origin + "vocab.txt", 231508, "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3");
    private readonly VerifiedGraph image, text;
    private readonly WordPiece tokenizer;
    internal static readonly float[] TextMean = LoadMean();
    internal const double RelevanceFloor = .08;
    private static float[] LoadMean() { using var resource = VerifiedGraph.Resource("OpenVisionMean"); return JsonSerializer.Deserialize<float[]>(resource) ?? throw new IOException("Image calibration is missing."); }

    internal OpenVisionModel()
    {
        using var stream = VerifiedModelAssets.OpenVerified(Vocabulary);
        using var reader = new StreamReader(stream, new UTF8Encoding(false, true));
        var words = new List<string>();
        string? line;
        while ((line = reader.ReadLine()) is not null) words.Add(line);
        tokenizer = new WordPiece(words.ToArray());
        image = new VerifiedGraph("openvision-image", Weights);
        try { text = new VerifiedGraph("openvision-text", Weights); }
        catch { image.Dispose(); throw; }
    }
    internal static async Task EnsureAsync(bool download, CancellationToken cancellation, IProgress<string>? progress)
    {
        await VerifiedModelAssets.EnsureAsync(Weights, download, cancellation, progress);
        await VerifiedModelAssets.EnsureAsync(Vocabulary, download, cancellation, progress);
    }
    internal long[] Tokens(string value) => tokenizer.Encode(value.Trim(), 80).Concat(Enumerable.Repeat(0L, 80)).Take(80).ToArray();
    internal float[] EmbedText(string value, CancellationToken cancellation) => text.Run(new[] { NamedOnnxValue.CreateFromTensor("input_ids", new DenseTensor<long>(Tokens(value), new[] { 1, 80 })) }, "embedding", 192, cancellation);
    internal Dictionary<string, double> RankText(string query, IReadOnlyDictionary<string, float[]> vectors, CancellationToken cancellation)
    {
        if (vectors.Count < 2) return new();
        float[] raw = EmbedText(query, cancellation);
        float[] question = Center(raw, TextMean);
        float[] mean = Enumerable.Range(0, 192).Select(index => vectors.Values.Average(vector => vector[index])).ToArray();
        try
        {
            var scores = new Dictionary<string, double>();
            foreach (var pair in vectors)
            {
                cancellation.ThrowIfCancellationRequested();
                float[] centered = Center(pair.Value, mean);
                try { scores[pair.Key] = SemanticEngine.Dot(question, centered); }
                finally { Array.Clear(centered); }
            }
            return scores;
        }
        finally { Array.Clear(raw); Array.Clear(question); Array.Clear(mean); }
    }
    internal float[] EmbedPixels(float[] pixels, CancellationToken cancellation)
    {
        if (pixels.Length != 3 * 224 * 224 || pixels.Any(value => !float.IsFinite(value) || value is < 0 or > 1)) throw new IOException("Invalid image pixels.");
        return image.Run(new[] { NamedOnnxValue.CreateFromTensor("pixels", new DenseTensor<float>(pixels, new[] { 1, 3, 224, 224 })) }, "embedding", 192, cancellation);
    }
    internal static async Task<float[]> PixelsAsync(HistoryItem item, CancellationToken cancellation)
    {
        if (item.Kind != "Image" || item.AnalysisVetoed) throw new IOException("This clip is excluded from image analysis.");
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(ImageAnalysis.EncodedImage(item));
            await writer.StoreAsync().AsTask(cancellation);
        }
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(cancellation);
        if (decoder.PixelWidth > 8192 || decoder.PixelHeight > 8192 || (long)decoder.PixelWidth * decoder.PixelHeight > 16777216) throw new IOException("Image dimensions exceed analysis limits.");
        var transform = new BitmapTransform { ScaledWidth = 224, ScaledHeight = 224, InterpolationMode = BitmapInterpolationMode.Linear };
        var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb).AsTask(cancellation);
        byte[] bgra = data.DetachPixelData();
        if (bgra.Length != 4 * 224 * 224) throw new IOException("Unexpected image pixel layout.");
        var pixels = new float[3 * 224 * 224];
        for (int index = 0; index < 224 * 224; ++index)
        {
            pixels[index] = bgra[index * 4 + 2] / 255f;
            pixels[224 * 224 + index] = bgra[index * 4 + 1] / 255f;
            pixels[2 * 224 * 224 + index] = bgra[index * 4] / 255f;
        }
        return pixels;
    }
    internal static float[] Center(float[] vector, float[] mean)
    {
        float[] result = vector.Zip(mean, (value, average) => value - average).ToArray();
        double norm = Math.Sqrt(result.Sum(value => (double)value * value));
        if (!double.IsFinite(norm) || norm < 1e-8) return Array.Empty<float>();
        return result.Select(value => (float)(value / norm)).ToArray();
    }
    public void Dispose() { image.Dispose(); text.Dispose(); }
}
