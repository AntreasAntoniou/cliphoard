using Cliphoard.Windows;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Storage.Streams;
using System.Security.Cryptography;

internal static class MediaDecodeWorker
{
    internal static async Task<int> RunAsync()
    {
        using Stream input = Console.OpenStandardInput(), output = Console.OpenStandardOutput();
        try
        {
            using var lifetime = new CancellationTokenSource(TimeSpan.FromMinutes(30)); CancellationToken cancellation = lifetime.Token;
            MediaDecodeRequest open = await ModelWorkerProtocol.ReadAsync<MediaDecodeRequest>(input, cancellation);
            if (open.Operation != "open") throw new IOException();
            using var lease = LocalFileLease.Open(open.Path, 2L * 1024 * 1024 * 1024);
            StorageFile file = await StorageFile.GetFileFromPathAsync(open.Path).AsTask(cancellation);
            var properties = await file.Properties.GetVideoPropertiesAsync().AsTask(cancellation);
            bool video = properties.Width > 0 && properties.Height > 0; bool audio; double duration; MediaComposition? composition = null;
            if (video)
            {
                if ((long)properties.Width * properties.Height > 3840 * 2160) throw new IOException();
                MediaClip clip = await MediaClip.CreateFromFileAsync(file).AsTask(cancellation); duration = clip.OriginalDuration.TotalSeconds; audio = clip.EmbeddedAudioTracks.Count != 0;
                composition = new MediaComposition(); composition.Clips.Add(clip);
            }
            else
            {
                BackgroundAudioTrack track = await BackgroundAudioTrack.CreateFromFileAsync(file).AsTask(cancellation); duration = track.OriginalDuration.TotalSeconds; audio = true;
            }
            if (!double.IsFinite(duration) || duration <= 0 || duration > 6 * 3600 || open.FullSpeech && duration > 3600) throw new IOException();
            string hash = Convert.ToHexString(await SHA256.HashDataAsync(lease, cancellation));
            var metadata = new MediaMetadata(duration, video, audio, properties.Width, properties.Height, hash, LocalFileLease.Identity(lease));
            await ModelWorkerProtocol.WriteAsync(output, new MediaDecodeResponse(true, metadata), cancellation);
            long emitted = 0, speechBytes = 0; int frames = 0, windows = 0, speechWindows = 0;
            for (int command = 0; command < 1000; ++command)
            {
                MediaDecodeRequest request = await ModelWorkerProtocol.ReadAsync<MediaDecodeRequest>(input, cancellation);
                if (request.Operation == "close") return 0;
                if (!double.IsFinite(request.Start) || !double.IsFinite(request.End) || request.Start < 0 || request.Start >= duration || request.End < request.Start || request.End > duration) throw new IOException();
                byte[] bytes;
                if (request.Operation == "frame" && video && composition is not null && ++frames <= 360)
                {
                    double scale = Math.Min(1, 1024.0 / Math.Max(properties.Width, properties.Height));
                    using var frame = await composition.GetThumbnailAsync(TimeSpan.FromSeconds(request.Start), Math.Max(1, (int)(properties.Width * scale)), Math.Max(1, (int)(properties.Height * scale)), VideoFramePrecision.NearestFrame).AsTask(cancellation);
                    bytes = await ReadAsync(frame, 8 * 1024 * 1024, cancellation);
                }
                else if (request.Operation is "audio" or "speech" && audio && request.End > request.Start && request.End - request.Start <= 30 && (request.Operation == "audio" ? ++windows <= 120 : open.FullSpeech && ++speechWindows <= 120))
                {
                    using var source = await file.OpenReadAsync().AsTask(cancellation); using var destination = new InMemoryRandomAccessStream();
                    var profile = MediaEncodingProfile.CreateWav(AudioEncodingQuality.Low); profile.Audio = AudioEncodingProperties.CreatePcm(16000, 1, 16);
                    var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = false, TrimStartTime = TimeSpan.FromSeconds(request.Start), TrimStopTime = TimeSpan.FromSeconds(request.End) };
                    var prepared = await transcoder.PrepareStreamTranscodeAsync(source, destination, profile).AsTask(cancellation);
                    if (!prepared.CanTranscode) throw new IOException();
                    await prepared.TranscodeAsync().AsTask(cancellation);
                    bytes = await ReadAsync(destination, 1024 * 1024, cancellation);
                    float[] samples = WavePcm.Read(bytes, minimumSamples: 1);
                    CryptographicOperations.ZeroMemory(bytes);
                    try
                    {
                        int count = Math.Min(samples.Length, Math.Max(1, (int)Math.Round((request.End - request.Start) * 16000)));
                        if (count >= 1600) bytes = WavePcm.Write(samples.AsSpan(0, count));
                        else { var padded = new float[1600]; samples.AsSpan(0, count).CopyTo(padded); try { bytes = WavePcm.Write(padded); } finally { Array.Clear(padded); } }
                    }
                    finally { Array.Clear(samples); }
                }
                else throw new IOException();
                try
                {
                    if (request.Operation == "speech") { speechBytes += bytes.Length; if (speechBytes > 128L * 1024 * 1024) throw new IOException(); }
                    else { emitted += bytes.Length; if (emitted > 64L * 1024 * 1024) throw new IOException(); }
                    await ModelWorkerProtocol.WriteAsync(output, new MediaDecodeResponse(true, Bytes: bytes, Start: request.Start, End: request.End), cancellation);
                }
                finally { CryptographicOperations.ZeroMemory(bytes); }
            }
            throw new IOException();
        }
        catch (EndOfStreamException) { return 0; }
        catch { try { await ModelWorkerProtocol.WriteAsync(output, new MediaDecodeResponse(false), default); } catch (IOException) { } return 1; }
    }
    private static async Task<byte[]> ReadAsync(IRandomAccessStream stream, uint maximum, CancellationToken cancellation)
    {
        if (stream.Size == 0 || stream.Size > maximum) throw new IOException();
        using var reader = new DataReader(stream.GetInputStreamAt(0)); uint loaded = await reader.LoadAsync((uint)stream.Size).AsTask(cancellation);
        if (loaded != stream.Size) throw new IOException(); byte[] bytes = new byte[(int)loaded]; reader.ReadBytes(bytes); return bytes;
    }
}
