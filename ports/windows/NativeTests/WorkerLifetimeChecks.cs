using System.Diagnostics;
using System.Text.Json;
using Cliphoard.Windows;

internal static class WorkerLifetimeChecks
{
    internal static async Task ParentFixtureAsync()
    {
        using var client = new GemmaWorkerClient();
        await client.PrepareAsync(false, CancellationToken.None, null);
        var identity = client.ProcessIdentity ?? throw new IOException("Worker identity unavailable.");
        Console.WriteLine(JsonSerializer.Serialize(new { pid = identity.Id, started = identity.Started }));
        Console.Out.Flush();
        await Task.Delay(Timeout.InfiniteTimeSpan);
    }
    internal static async Task RunAsync()
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        var info = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        info.ArgumentList.Add("--worker-parent-fixture");
        using var parent = Process.Start(info) ?? throw new IOException("Could not start the owned parent fixture.");
        using var lifetime = new OwnedProcessJob(parent);
        string? line = await parent.StandardOutput.ReadLineAsync(deadline.Token);
        using var identity = JsonDocument.Parse(line ?? throw new IOException("Worker parent fixture failed to prepare."));
        using var child = Process.GetProcessById(identity.RootElement.GetProperty("pid").GetInt32());
        _ = child.Handle;
        string expected = Path.Combine(AppContext.BaseDirectory, "ModelWorker", "Cliphoard.ModelWorker.exe");
        if (child.StartTime.ToUniversalTime().Ticks != identity.RootElement.GetProperty("started").GetInt64() || !string.Equals(child.MainModule?.FileName, expected, StringComparison.OrdinalIgnoreCase)) throw new Exception("Owned worker identity changed before the lifetime test.");
        parent.Kill(entireProcessTree: false);
        await parent.WaitForExitAsync(deadline.Token);
        try { await child.WaitForExitAsync(deadline.Token); }
        finally { if (!child.HasExited) child.Kill(entireProcessTree: true); }
        Console.WriteLine(JsonSerializer.Serialize(new { worker_parent_death_check = "passed", helper_exited = child.HasExited }));
    }
}
