using System.Buffers.Binary;
using System.Text;
using Whisper.net;
namespace Cliphoard.Windows;

internal sealed record SpeechPassage(double Start, double End, string Text);
internal static class SpeechModel
{
    private const string Revision = "5359861c739e955e79d9a303bcbc70fb988958b1";
    internal static ModelAsset Asset(string model)
    {
        (string name, long size, string hash) = model switch
        {
            "small" => ("ggml-small.bin", 487601967L, "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
            "largeV3" => ("ggml-large-v3.bin", 3095033483L, "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"),
            "turbo" => ("ggml-large-v3-turbo.bin", 1624555275L, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
            _ => throw new ArgumentException("Unknown Whisper model.")
        };
        return new("whisper-" + Revision, name, $"https://huggingface.co/ggerganov/whisper.cpp/resolve/{Revision}/{name}", size, hash);
    }
    internal static Task EnsureAsync(string model, bool download, CancellationToken cancellation, IProgress<string>? progress) => VerifiedModelAssets.EnsureAsync(Asset(model), download, cancellation, progress);
    private static readonly SemaphoreSlim lane = new(1);
    internal static async Task<string> TranscribeAsync(string model, float[] samples, CancellationToken cancellation)
    {
        if (samples.Length is < 1600 or > 16000 * 600 || samples.Any(value => !float.IsFinite(value) || value is < -1 or > 1)) throw new IOException("Speech input exceeds the local ten-minute contract.");
        await lane.WaitAsync(cancellation);
        try
        {
            using var verified = VerifiedModelAssets.OpenVerified(Asset(model));
            cancellation.ThrowIfCancellationRequested();
            using var factory = WhisperFactory.FromPath(VerifiedModelAssets.PathFor(Asset(model)), new WhisperFactoryOptions { UseGpu = false });
            using var processor = factory.CreateBuilder().WithThreads(2).WithLanguage("auto").Build();
            return await CollectAsync(processor, samples, cancellation);
        }
        finally { lane.Release(); }
    }
    internal static async Task<string[]> TranscribeWavesAsync(string model, IReadOnlyList<byte[]> waves, CancellationToken cancellation, IProgress<int>? progress = null)
    {
        SpeechPassage[][] passages = await TranscribePassagesAsync(model, waves, cancellation, progress);
        return passages.Select(window => string.Join('\n', window.Select(passage => passage.Text))).ToArray();
    }
    internal static async Task<SpeechPassage[][]> TranscribePassagesAsync(string model, IReadOnlyList<byte[]> waves, CancellationToken cancellation, IProgress<int>? progress = null)
    {
        if (waves.Count > 120) throw new IOException("Speech window bound exceeded.");
        await lane.WaitAsync(cancellation);
        try
        {
            using var verified = VerifiedModelAssets.OpenVerified(Asset(model));
            using var factory = WhisperFactory.FromPath(VerifiedModelAssets.PathFor(Asset(model)), new WhisperFactoryOptions { UseGpu = false });
            using var processor = factory.CreateBuilder().WithThreads(2).WithLanguage("auto").Build();
            var results = new List<SpeechPassage[]>();
            int characters = 0, count = 0;
            foreach (byte[] wave in waves)
            {
                float[] samples = ReadWave(wave);
                try
                {
                    var passages = new List<SpeechPassage>();
                    double duration = samples.Length / 16000.0;
                    await foreach (var segment in processor.ProcessAsync(samples, cancellation))
                    {
                        cancellation.ThrowIfCancellationRequested();
                        string text = segment.Text.Trim();
                        if (text.Length == 0) continue;
                        characters += text.Length;
                        if (characters > 200000) throw new IOException("Speech passages exceed their bound.");
                        double start = Math.Clamp(segment.Start.TotalSeconds, 0, duration);
                        double end = Math.Clamp(segment.End.TotalSeconds, start, duration);
                        foreach (string chunk in PassageChunks(text))
                        {
                            if (++count > 1000) throw new IOException("Speech passages exceed their bound.");
                            passages.Add(new(start, end, chunk));
                        }
                    }
                    results.Add(passages.ToArray()); progress?.Report(results.Count);
                }
                finally { Array.Clear(samples); }
            }
            return results.ToArray();
        }
        finally { lane.Release(); }
    }
    internal static IEnumerable<string> PassageChunks(string text)
    {
        var elements = System.Globalization.StringInfo.GetTextElementEnumerator(text);
        var chunk = new StringBuilder(); int bytes = 0;
        while (elements.MoveNext())
        {
            string element = elements.GetTextElement(); int size = Encoding.UTF8.GetByteCount(element);
            if (bytes + size > 1000 && chunk.Length > 0) { yield return chunk.ToString(); chunk.Clear(); bytes = 0; }
            if (size > 1000) continue;
            chunk.Append(element); bytes += size;
        }
        if (chunk.Length > 0) yield return chunk.ToString();
    }
    private static async Task<string> CollectAsync(WhisperProcessor processor, float[] samples, CancellationToken cancellation)
    {
        var text = new StringBuilder();
        await foreach (var segment in processor.ProcessAsync(samples, cancellation))
        {
            cancellation.ThrowIfCancellationRequested();
            if (text.Length + segment.Text.Length + 1 > 65536) throw new IOException("Transcript exceeds the text limit.");
            if (text.Length > 0) text.AppendLine();
            text.Append(segment.Text.Trim());
        }
        cancellation.ThrowIfCancellationRequested();
        return text.ToString();
    }
    internal static float[] ReadWave(byte[] bytes) => WavePcm.Read(bytes);
}
