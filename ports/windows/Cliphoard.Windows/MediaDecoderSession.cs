using System.Diagnostics;
namespace Cliphoard.Windows;
internal sealed class MediaDecoderSession : IDisposable
{
    private readonly FileStream lease;
    private readonly string path;
    private readonly Process process;
    private readonly OwnedProcessJob job;
    private readonly CancellationTokenRegistration revocation;
    private readonly Task errors;
    private readonly SemaphoreSlim lane = new(1);
    private bool closed;
    internal MediaMetadata Metadata { get; private set; } = null!;
    private MediaDecoderSession(string path, CancellationToken cancellation)
    {
        this.path = path;
        lease = LocalFileLease.Open(path, 2L * 1024 * 1024 * 1024);
        try
        {
            string executable = Path.Combine(AppContext.BaseDirectory, "ModelWorker", "Cliphoard.ModelWorker.exe"); VerifiedModelAssets.CheckPath(executable);
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Path.GetDirectoryName(executable)! }; start.ArgumentList.Add("--media-worker");
            process = Process.Start(start) ?? throw new IOException("Media decoder is unavailable.");
            try { job = new OwnedProcessJob(process, 768u * 1024 * 1024); }
            catch { Stop(); process.Dispose(); throw; }
            errors = process.StandardError.BaseStream.CopyToAsync(Stream.Null); revocation = cancellation.Register(Stop);
        }
        catch { lease.Dispose(); throw; }
    }
    internal static async Task<MediaDecoderSession> OpenAsync(string path, bool fullSpeech, CancellationToken cancellation)
    {
        var session = new MediaDecoderSession(path, cancellation);
        try
        {
            MediaDecodeResponse response = await session.SendAsync(new("open", path, FullSpeech: fullSpeech), cancellation);
            MediaMetadata metadata = response.Metadata ?? throw new IOException("Media metadata is unavailable.");
            if (metadata.Identity != LocalFileLease.Identity(session.lease)) throw new IOException("Media identity changed.");
            if (!double.IsFinite(metadata.Duration) || metadata.Duration <= 0 || metadata.Duration > 21600 || !metadata.Video && !metadata.Audio || metadata.Video && ((long)metadata.Width * metadata.Height > 3840 * 2160 || metadata.Width == 0 || metadata.Height == 0) || metadata.Hash.Length != 64 || !metadata.Hash.All(Uri.IsHexDigit) || fullSpeech && metadata.Duration > 3600) throw new IOException("Media metadata exceeds its bound.");
            session.Metadata = metadata; return session;
        }
        catch { session.Dispose(); throw; }
    }
    internal async Task<byte[]> DecodeAsync(bool video, double start, double end, CancellationToken cancellation, bool speech = false)
    {
        if (!double.IsFinite(start) || !double.IsFinite(end) || start < 0 || start >= Metadata.Duration || end < start || end > Metadata.Duration || !video && (end <= start || end - start > 30)) throw new IOException("Invalid media window.");
        MediaDecodeResponse response = await SendAsync(new(video ? "frame" : speech ? "speech" : "audio", Start: start, End: end), cancellation);
        if (response.Bytes is not byte[] bytes || response.Start != start || response.End != end || bytes.Length == 0 || bytes.Length > (video ? 8 * 1024 * 1024 : 1024 * 1024)) throw new IOException("Invalid decoded media window.");
        return bytes;
    }
    private async Task<MediaDecodeResponse> SendAsync(MediaDecodeRequest request, CancellationToken cancellation)
    {
        await lane.WaitAsync(cancellation);
        try
        {
            if (closed) throw new IOException("Media decoder has ended.");
            using var current = LocalFileLease.Open(path, 2L * 1024 * 1024 * 1024);
            if (LocalFileLease.Identity(current) != LocalFileLease.Identity(lease)) throw new IOException("Media identity changed.");
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(TimeSpan.FromSeconds(120)); using var revoke = deadline.Token.Register(Stop);
            await ModelWorkerProtocol.WriteAsync(process.StandardInput.BaseStream, request, deadline.Token);
            MediaDecodeResponse response = await ModelWorkerProtocol.ReadAsync<MediaDecodeResponse>(process.StandardOutput.BaseStream, deadline.Token);
            using var after = LocalFileLease.Open(path, 2L * 1024 * 1024 * 1024);
            if (LocalFileLease.Identity(after) != LocalFileLease.Identity(lease)) throw new IOException("Media identity changed.");
            deadline.Token.ThrowIfCancellationRequested(); if (!response.Success) throw new IOException("The local decoder refused this media file."); return response;
        }
        catch { Stop(); throw; }
        finally { lane.Release(); }
    }
    private void Stop()
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }
    public void Dispose()
    {
        if (closed) return; closed = true; revocation.Dispose(); Stop(); job.Dispose(); process.Dispose(); lease.Dispose();
        _ = errors.ContinueWith(task => { _ = task.Exception; }, TaskScheduler.Default);
    }
}
