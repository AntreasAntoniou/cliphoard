using System.Diagnostics;
using System.Text;
namespace Cliphoard.Windows;

internal sealed class GemmaWorkerClient : IDisposable
{
    private Process? worker;
    private OwnedProcessJob? lifetime;
    internal (int Id, long Started)? ProcessIdentity => worker is Process process ? (process.Id, process.StartTime.ToUniversalTime().Ticks) : null;
    private CancellationToken workerLifetime;
    private CancellationTokenRegistration revocation;
    private volatile bool prepared;
    internal bool Ready
    {
        get
        {
            Process? process = worker;
            try { return prepared && !workerLifetime.IsCancellationRequested && process is not null && !process.HasExited; }
            catch (InvalidOperationException) { return false; }
        }
    }
    internal async Task PrepareAsync(bool download, CancellationToken cancellation, IProgress<string>? progress)
    {
        await GemmaAssets.EnsureAsync(download, cancellation, progress);
        cancellation.ThrowIfCancellationRequested();
        string path = Path.Combine(AppContext.BaseDirectory, "ModelWorker", "Cliphoard.ModelWorker.exe");
        VerifiedModelAssets.CheckPath(path);
        if (!File.Exists(path)) throw new IOException("The packaged model worker is missing.");
        var info = new ProcessStartInfo(path) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Path.GetDirectoryName(path)! };
        info.ArgumentList.Add("--private-worker");
        worker = Process.Start(info) ?? throw new IOException("Could not start the private model worker.");
        try { lifetime = new OwnedProcessJob(worker); }
        catch { Dispose(); throw; }
        workerLifetime = cancellation;
        Process process = worker;
        revocation = cancellation.Register(() => Stop(process));
        _ = worker.Handle;
        _ = DrainAsync(worker.StandardError.BaseStream);
        try { prepared = (await RequestAsync(new("prepare"), cancellation)).Ready; if (!Ready) throw new IOException("Local Gemma preparation failed."); }
        catch { Dispose(); throw; }
    }
    private static async Task DrainAsync(Stream stream) { try { await stream.CopyToAsync(Stream.Null); } catch (IOException) { } catch (ObjectDisposedException) { } }
    internal async Task<float[]> EmbedAsync(string text, bool query, CancellationToken cancellation, byte[]? image = null, byte[]? audio = null)
    {
        if (!Ready) throw new IOException("Gemma is not prepared.");
        var bounded = new StringBuilder();
        int bytes = 0;
        foreach (Rune rune in text.EnumerateRunes())
        {
            if (bytes + rune.Utf8SequenceLength > 1024) break;
            bytes += rune.Utf8SequenceLength; bounded.Append(rune.ToString());
        }
        string operation = image is not null ? "image" : audio is not null ? "audio" : query ? "query" : "document";
        ModelResponse response = await RequestAsync(new(operation, bounded.ToString(), image, audio), cancellation);
        if (!response.Ready || response.Vector is not { Length: 768 } vector || vector.Any(value => !float.IsFinite(value))) throw new IOException("Gemma returned an invalid result.");
        return vector;
    }
    private async Task<ModelResponse> RequestAsync(ModelRequest request, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        Process process = worker ?? throw new IOException("Private model worker is unavailable.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(workerLifetime);
        deadline.CancelAfter(TimeSpan.FromMinutes(3));
        using var revoke = deadline.Token.Register(() => Stop(process));
        ModelResponse response;
        try
        {
            await ModelWorkerProtocol.WriteAsync(process.StandardInput.BaseStream, request, deadline.Token);
            response = await ModelWorkerProtocol.ReadAsync<ModelResponse>(process.StandardOutput.BaseStream, deadline.Token);
            deadline.Token.ThrowIfCancellationRequested();
        }
        catch { prepared = false; Dispose(); throw; }
        // A superseded query discards its response after the complete frame. Session revocation
        // and deadlines terminate the worker through their independent lifetime registration.
        cancellation.ThrowIfCancellationRequested();
        return response;
    }
    private static void Stop(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }
    public void Dispose()
    {
        prepared = false;
        revocation.Dispose();
        Interlocked.Exchange(ref lifetime, null)?.Dispose();
        Process? process = Interlocked.Exchange(ref worker, null);
        if (process is null) return;
        try { Stop(process); }
        finally { process.Dispose(); }
    }
}
