using Cliphoard.Windows;
using System.Text.Json;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Storage;
internal static class MediaDecodeChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Media decode check {checks} failed"); }
        foreach (string preset in new[] { "lightweight", "balanced", "detailed" })
        foreach (bool video in new[] { true, false })
        foreach (double duration in new[] { 0, .01, 1, 31, 3600, 21600 })
        {
            MediaSamplingPlan plan = MediaSamplingPlan.Make(duration, preset, video);
            Check(plan.Segments.Length <= 120 && plan.Coverage >= 0 && plan.Coverage <= 1);
            Check(plan.Segments.All(segment => segment.Start >= 0 && segment.End <= duration && segment.End > segment.Start && segment.Frames.All(frame => frame >= segment.Start && frame < segment.End)));
        }
        bool refused = false; try { MediaSamplingPlan.Make(double.NaN, "balanced", true); } catch (IOException) { refused = true; } Check(refused);
        var capped = MediaSamplingPlan.Make(21600, "detailed", true); Check(capped.Segments.Length == 120 && capped.Segments[^1].Start > 21000);
        var full = MediaSamplingPlan.Make(3600, "detailed", false); Check(full.Coverage == 1 && full.SampledDuration == 3600);
        string folder = Path.Combine(Path.GetTempPath(), "CliphoardMediaFixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
        try
        {
            string audio = Path.Combine(folder, "synthetic-stereo.wav"); int sampleRate = 44100, samples = sampleRate * 4;
            byte[] bytes = new byte[44 + samples * 4]; "RIFF"u8.CopyTo(bytes); BitConverter.GetBytes(bytes.Length - 8).CopyTo(bytes, 4); "WAVEfmt "u8.CopyTo(bytes.AsSpan(8)); BitConverter.GetBytes(16).CopyTo(bytes, 16); BitConverter.GetBytes((short)1).CopyTo(bytes, 20); BitConverter.GetBytes((short)2).CopyTo(bytes, 22); BitConverter.GetBytes(sampleRate).CopyTo(bytes, 24); BitConverter.GetBytes(sampleRate * 4).CopyTo(bytes, 28); BitConverter.GetBytes((short)4).CopyTo(bytes, 32); BitConverter.GetBytes((short)16).CopyTo(bytes, 34); "data"u8.CopyTo(bytes.AsSpan(36)); BitConverter.GetBytes(samples * 4).CopyTo(bytes, 40);
            for (int index = 0; index < samples; ++index) { short value = (short)(Math.Sin(index * 2 * Math.PI * 440 / sampleRate) * 4000); BitConverter.GetBytes(value).CopyTo(bytes, 44 + index * 4); BitConverter.GetBytes(value).CopyTo(bytes, 46 + index * 4); }
            await File.WriteAllBytesAsync(audio, bytes);
            using (var decoder = await MediaDecoderSession.OpenAsync(audio, false, default))
            {
                Check(decoder.Metadata.Audio && !decoder.Metadata.Video && Math.Abs(decoder.Metadata.Duration - 4) < .01);
                byte[] wave = await decoder.DecodeAsync(false, .5, 2.5, default); float[] pcm = WavePcm.Read(wave);
                Check(pcm.Length >= 31000 && pcm.Length <= 33000 && pcm.Any(value => Math.Abs(value) > .01)); Array.Clear(pcm); Array.Clear(wave);
            }
            string video = Path.Combine(folder, "synthetic-red.mp4");
            var composition = new MediaComposition(); composition.Clips.Add(MediaClip.CreateFromColor(Windows.UI.Color.FromArgb(255, 255, 0, 0), TimeSpan.FromSeconds(3)));
            StorageFile output = await (await StorageFolder.GetFolderFromPathAsync(folder)).CreateFileAsync("synthetic-red.mp4", CreationCollisionOption.FailIfExists);
            var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.Wvga); profile.Video.Width = 160; profile.Video.Height = 120;
            var failure = await composition.RenderToFileAsync(output, MediaTrimmingPreference.Precise, profile); Check(failure == Windows.Media.Transcoding.TranscodeFailureReason.None);
            using (var decoder = await MediaDecoderSession.OpenAsync(video, false, default))
            {
                Check(decoder.Metadata.Video && decoder.Metadata.Width == 160 && decoder.Metadata.Height == 120);
                byte[] frame = await decoder.DecodeAsync(true, 1, 1, default);
                byte[] png = await ImageAnalysis.NormalizeReferenceAsync(frame, default); Check(ClipboardContent.IsPng(png));
            }
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            refused = false; try { using var decoder = await MediaDecoderSession.OpenAsync(audio, false, cancelled.Token); } catch (OperationCanceledException) { refused = true; } Check(refused);
        }
        finally { Directory.Delete(folder, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { media_decode_checks = checks, status = "passed", generated_media_only = true }));
    }
}
