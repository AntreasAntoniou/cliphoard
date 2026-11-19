using System.Buffers.Binary;
using System.Diagnostics;
using System.Text.Json;
namespace Cliphoard.Windows;

/// Explicit fixture child only. No production named-pipe/TCP fallback or caller-supplied paths.
internal sealed class FixtureEngine : IAsyncDisposable
{
    internal const string Prefix = "[CLIPHOARD_SYNTHETIC_V1] ";
    private const int MaxFrame = 256 * 1024;
    private readonly Process process;
    private readonly SemaphoreSlim flight = new(1, 1);
    private uint requestId;
    private bool failed;
    internal FixtureEngine()
    {
        string executable = Path.Combine(AppContext.BaseDirectory, "cliphoard-engine.exe");
        process = Process.Start(new ProcessStartInfo(executable, "--synthetic-stdio") {
            UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true,
            RedirectStandardError = true, CreateNoWindow = true, WorkingDirectory = AppContext.BaseDirectory
        }) ?? throw new InvalidOperationException("Fixture engine unavailable");
        // Drain fixed engine diagnostic codes without logging payloads or allowing stderr to block.
        _ = DrainDiagnosticsAsync();
    }
    private async Task DrainDiagnosticsAsync()
    {
        char[] buffer = new char[256];
        try { while (await process.StandardError.ReadAsync(buffer) != 0) { } } catch (IOException) { }
    }
    internal async Task<JsonElement> CallAsync(object command)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        await flight.WaitAsync(timeout.Token);
        try
        {
            if (failed || process.HasExited) throw new IOException("Fixture engine unavailable");
            uint id = checked(++requestId);
            byte[] request = JsonSerializer.SerializeToUtf8Bytes(new { version = 1, id, command });
            if (request.Length == 0 || request.Length > MaxFrame) throw new IOException("Bounded request refused");
            byte[] header = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(header, (uint)request.Length);
            Stream input = process.StandardInput.BaseStream, output = process.StandardOutput.BaseStream;
            await input.WriteAsync(header, timeout.Token); await input.WriteAsync(request, timeout.Token);
            await input.FlushAsync(timeout.Token);
            await output.ReadExactlyAsync(header, timeout.Token);
            uint count = BinaryPrimitives.ReadUInt32LittleEndian(header);
            if (count == 0 || count > MaxFrame) throw new IOException("Bounded response refused");
            byte[] response = new byte[(int)count]; await output.ReadExactlyAsync(response, timeout.Token);
            using var parsed = JsonDocument.Parse(response, new JsonDocumentOptions { MaxDepth = 16 });
            JsonElement root = parsed.RootElement;
            if (root.GetProperty("version").GetInt32() != 1 || root.GetProperty("id").GetUInt32() != id || !root.GetProperty("ok").GetBoolean())
                throw new IOException("Fixture request refused");
            return root.GetProperty("result").Clone();
        }
        catch
        {
            // Cancelled framing cannot be resumed safely: dispose the owned synthetic child.
            failed = true;
            if (!process.HasExited) process.Kill();
            throw;
        }
        finally { flight.Release(); }
    }
    public async ValueTask DisposeAsync()
    {
        failed = true;
        if (!process.HasExited) { process.StandardInput.Close(); if (!process.WaitForExit(500)) process.Kill(); }
        await process.WaitForExitAsync(); process.Dispose(); flight.Dispose();
    }
}
