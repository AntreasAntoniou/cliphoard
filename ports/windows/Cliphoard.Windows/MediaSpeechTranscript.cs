using System.Security.Cryptography;
namespace Cliphoard.Windows;
internal static class MediaSpeechTranscript
{
    internal static async Task<string> ReadAsync(string path, string model, CancellationToken cancellation, IProgress<int>? progress = null)
    {
        await SpeechModel.EnsureAsync(model, false, cancellation, null);
        using var decoder = await MediaDecoderSession.OpenAsync(path, true, cancellation);
        if (!decoder.Metadata.Audio) throw new IOException("The selected file has no audio track.");
        var waves = new List<byte[]>(); long bytes = 0;
        try
        {
            foreach (MediaSampleWindow window in MediaSamplingPlan.Make(decoder.Metadata.Duration, "detailed", false).Segments)
            {
                byte[] wave = await decoder.DecodeAsync(false, window.Start, window.End, cancellation, speech: true); bytes += wave.Length;
                if (bytes > 128L * 1024 * 1024) { CryptographicOperations.ZeroMemory(wave); throw new IOException("Speech buffers exceed their bound."); }
                waves.Add(wave);
            }
            string[] texts = await SpeechModel.TranscribeWavesAsync(model, waves, cancellation, progress);
            if (texts.Sum(text => text.Length + 1) > 200000) throw new IOException("Transcript exceeds its text bound.");
            return string.Join('\n', texts.Where(text => !string.IsNullOrWhiteSpace(text)));
        }
        finally { foreach (byte[] wave in waves) CryptographicOperations.ZeroMemory(wave); }
    }
}
