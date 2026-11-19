using System.Diagnostics;
namespace Cliphoard.Windows;

internal static class PrivateWorkerCall
{
    internal static async Task<TResponse> SendAsync<TRequest, TResponse>(string role, TRequest request, int maximumFrame, int seconds, nuint memory, CancellationToken cancellation)
    {
        if (role is not ("--document-worker" or "--manager-import-worker" or "--media-worker")) throw new ArgumentException("Unknown private role.");
        cancellation.ThrowIfCancellationRequested();
        string executable = Path.Combine(AppContext.BaseDirectory, "ModelWorker", "Cliphoard.ModelWorker.exe"); VerifiedModelAssets.CheckPath(executable);
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Path.GetDirectoryName(executable)! }; start.ArgumentList.Add(role);
        using Process process = Process.Start(start) ?? throw new IOException("Private worker is unavailable."); _ = process.Handle;
        try
        {
            using var job = new OwnedProcessJob(process, memory);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(TimeSpan.FromSeconds(seconds));
            using var revoke = deadline.Token.Register(() => Stop(process));
            Task errors = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
            await ModelWorkerProtocol.WriteAsync(process.StandardInput.BaseStream, request, deadline.Token, maximumFrame); process.StandardInput.Close();
            TResponse response = await ModelWorkerProtocol.ReadAsync<TResponse>(process.StandardOutput.BaseStream, deadline.Token, maximumFrame);
            await process.WaitForExitAsync(deadline.Token); await errors; deadline.Token.ThrowIfCancellationRequested();
            if (process.ExitCode != 0) throw new IOException("Private worker refused this operation."); return response;
        }
        finally { Stop(process); }
    }
    private static void Stop(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }
}
