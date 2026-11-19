using Cliphoard.Windows;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Cliphoard.Companion;

/// Owns exactly one native consent process. All writer exchanges remain serialized.
internal sealed class BrokerProcess : IDisposable
{
    private readonly Process process;
    private readonly OwnedProcessJob job;
    private readonly SemaphoreSlim exchange = new(1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task drain;
    private readonly BoundedCommandLines lines;
    private bool disposed;
    internal BrokerProcess(bool writer)
    {
        string parent = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));
        string executable = Path.Combine(parent, "Cliphoard.Windows.exe");
        if (!File.Exists(executable) || (File.GetAttributes(executable) & FileAttributes.ReparsePoint) != 0 || (File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0) throw new IOException("Native companion is unavailable.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true, WorkingDirectory = parent };
        start.ArgumentList.Add(writer ? "--agent-writer" : "--agent-export-reader");
        process = Process.Start(start) ?? throw new IOException("Native consent is unavailable.");
        try { job = new OwnedProcessJob(process, writer ? 512u * 1024 * 1024 : 1024u * 1024 * 1024); }
        catch { try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } process.Dispose(); throw; }
        lines = new(process.StandardOutput.BaseStream);
        drain = DrainAsync(process.StandardError.BaseStream);
    }
    private static async Task DrainAsync(Stream stream)
    {
        byte[] buffer = new byte[4096];
        try { while (await stream.ReadAsync(buffer) != 0) { } }
        catch (Exception error) when (error is IOException or ObjectDisposedException) { }
    }
    internal async Task<JsonElement> ReceiveAsync(int maximum, CancellationToken cancellation)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token); deadline.CancelAfter(TimeSpan.FromMinutes(3));
        byte[] data = await lines.NextAsync(() => { if (disposed) throw new IOException(); }, deadline.Token, maximum) ?? throw new IOException("Native consent ended.");
        try { using var json = JsonDocument.Parse(data); return json.RootElement.Clone(); }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(data); }
    }
    internal async Task<JsonElement> CommandAsync(object value, CancellationToken cancellation)
    {
        await exchange.WaitAsync(cancellation);
        try
        {
            lifetime.Token.ThrowIfCancellationRequested();
            string command = JsonSerializer.Serialize(value);
            await process.StandardInput.WriteLineAsync(command.AsMemory(), cancellation); await process.StandardInput.FlushAsync(cancellation);
            // Keep ownership through the response. A caller timeout never starts another exchange.
            return await ReceiveAsync(2048, lifetime.Token);
        }
        catch { Dispose(); throw; }
        finally { exchange.Release(); }
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true; lifetime.Cancel(); job.Dispose();
        _ = lines.DisposeAsync();
        process.Dispose();
    }
}
