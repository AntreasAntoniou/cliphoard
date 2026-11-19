using System.Security.Cryptography;
namespace Cliphoard.Windows;
internal sealed class MediaContentRefused : IOException
{
    internal long Flags { get; }
    internal MediaContentRefused(long flags) : base("Recognized media content requires protection.") { Flags = flags; }
}
internal static class MediaIndexer
{
    internal static async Task<MediaIndex> BuildAsync(string path, string preset, string coverage, string speechModel, bool screenVideo, bool screenAudio, SemanticEngine engine, Func<bool> admitted, CancellationToken cancellation, IProgress<string>? progress = null)
    {
        if (coverage is not ("off" or "sampled" or "full")) throw new IOException("Unknown speech coverage.");
        void Check() { cancellation.ThrowIfCancellationRequested(); if (!admitted()) throw new OperationCanceledException(); }
        Check();
        using var lease = LocalFileLease.Open(path, 2L * 1024 * 1024 * 1024);
        long length = lease.Length, modified = File.GetLastWriteTimeUtc(lease.SafeFileHandle).Ticks;
        using var decoder = await MediaDecoderSession.OpenAsync(path, coverage == "full", cancellation);
        MediaMetadata metadata = decoder.Metadata;
        await engine.PrepareMediaAsync(false, cancellation, progress);
        if (coverage != "off") await SpeechModel.EnsureAsync(speechModel, false, cancellation, progress);
        var moments = new List<MediaMoment>(); var speechWaves = new List<byte[]>(); var speechTimes = new List<MediaSampleWindow>();
        var positives = new List<float[]>(); var negatives = new List<float[]>();
        async Task Screen(float[] vector, bool enabled)
        {
            if (!enabled) return;
            if (positives.Count == 0)
            {
                foreach (string prompt in NsfwPolicy.Positive) { Check(); positives.Add(await engine.EmbedMediaAsync(prompt, false, cancellation)); }
                foreach (string prompt in NsfwPolicy.Negative) { Check(); negatives.Add(await engine.EmbedMediaAsync(prompt, false, cancellation)); }
            }
            if (NsfwPolicy.PossibleMatch(vector, positives, negatives)) throw new MediaContentRefused(128);
        }
        long speechBytes = 0;
        try
        {
            if (metadata.Video)
            {
                var plan = MediaSamplingPlan.Make(metadata.Duration, preset, true);
                foreach (MediaSampleWindow window in plan.Segments)
                foreach (double time in window.Frames)
                {
                    Check(); progress?.Report($"Indexing video locally · {TimeSpan.FromSeconds(time):mm\\:ss}");
                    byte[] frame = await decoder.DecodeAsync(true, time, time, cancellation);
                    try
                    {
                        Check(); float[] vector = await engine.EmbedMediaAsync("", false, cancellation, image: frame);
                        try { await Screen(vector, screenVideo); moments.Add(new(time, time, "video", MediaIndex.Pack(vector))); }
                        finally { Array.Clear(vector); }
                    }
                    finally { CryptographicOperations.ZeroMemory(frame); }
                }
            }
            var soundPlan = MediaSamplingPlan.Make(metadata.Duration, preset, false);
            if (metadata.Audio)
            foreach (MediaSampleWindow window in soundPlan.Segments)
            {
                Check(); progress?.Report($"Indexing sound locally · {TimeSpan.FromSeconds(window.Start):mm\\:ss}");
                byte[] wave = await decoder.DecodeAsync(false, window.Start, window.End, cancellation);
                try
                {
                    Check(); float[] vector = await engine.EmbedMediaAsync("", false, cancellation, audio: wave);
                    try { await Screen(vector, screenAudio); moments.Add(new(window.Start, window.End, "audio", MediaIndex.Pack(vector))); }
                    finally { Array.Clear(vector); }
                    if (coverage == "sampled") { speechBytes += wave.Length; speechWaves.Add(wave.ToArray()); speechTimes.Add(window); }
                }
                finally { CryptographicOperations.ZeroMemory(wave); }
            }
            if (metadata.Audio && coverage == "full")
            foreach (MediaSampleWindow window in MediaSamplingPlan.Make(metadata.Duration, "detailed", false).Segments)
            {
                Check(); byte[] wave = await decoder.DecodeAsync(false, window.Start, window.End, cancellation, speech: true); speechBytes += wave.Length;
                if (speechBytes > 128L * 1024 * 1024) { CryptographicOperations.ZeroMemory(wave); throw new IOException("Speech buffers exceed their bound."); }
                speechWaves.Add(wave); speechTimes.Add(window);
            }
            if (speechWaves.Count != 0)
            {
                // The largest Whisper model and Gemma take turns owning native model memory.
                Check(); await engine.ClearAsync(); progress?.Report("Recognizing speech locally…");
                SpeechPassage[][] transcripts = await SpeechModel.TranscribePassagesAsync(speechModel, speechWaves, cancellation);
                long flags = 0; foreach (SpeechPassage passage in transcripts.SelectMany(window => window)) flags |= ContentSafety.Flags(passage.Text);
                if ((flags & ~8L) != 0) throw new MediaContentRefused(flags);
                Check(); await engine.PrepareMediaAsync(false, cancellation, progress);
                for (int index = 0; index < transcripts.Length; ++index)
                foreach (SpeechPassage passage in transcripts[index])
                {
                    string text = passage.Text;
                    Check(); float[] vector = await engine.EmbedMediaAsync(text, false, cancellation);
                    double start = Math.Min(speechTimes[index].End, speechTimes[index].Start + passage.Start);
                    double end = Math.Clamp(speechTimes[index].Start + passage.End, start, speechTimes[index].End);
                    try { await Screen(vector, screenAudio); moments.Add(new(start, end, "speech", MediaIndex.Pack(vector), text)); }
                    finally { Array.Clear(vector); }
                }
            }
            Check();
            var result = new MediaIndex(path, length, modified, metadata.Hash, MediaIndex.Signature, preset, coverage, speechModel, metadata.Duration, metadata.Video, metadata.Audio, soundPlan.Coverage, moments.ToArray()) { FileIdentity = LocalFileLease.Identity(lease) }; result.Validate();
            if (File.GetLastWriteTimeUtc(path).Ticks != modified || lease.Length != length) throw new IOException("The selected media file changed.");
            return result;
        }
        finally
        {
            foreach (byte[] wave in speechWaves) CryptographicOperations.ZeroMemory(wave);
            foreach (float[] vector in positives.Concat(negatives)) Array.Clear(vector);
        }
    }
}
