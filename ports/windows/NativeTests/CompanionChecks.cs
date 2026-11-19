using Cliphoard.Windows;
using System.Diagnostics;
using System.Text.Json;
internal static class CompanionChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Companion check {checks} failed"); }
        string executable = Path.Combine(AppContext.BaseDirectory, "Companion", "Cliphoard.Companion.exe");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        using var child = Process.Start(start)!; using var job = new OwnedProcessJob(child);
        Task<string> errors = child.StandardError.ReadToEndAsync();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        int sequence = 0;
        async Task<JsonElement> Send(string method, object parameters)
        {
            int id = ++sequence;
            await child.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, method, @params = parameters }));
            string line = await child.StandardOutput.ReadLineAsync(deadline.Token) ?? throw new IOException("Companion exited.");
            using var json = JsonDocument.Parse(line); Check(json.RootElement.GetProperty("id").GetInt32() == id); return json.RootElement.Clone();
        }
        var initialize = await Send("initialize", new { protocolVersion = "2024-11-05", capabilities = new { }, clientInfo = new { name = "synthetic fixture", version = "1" } });
        Check(initialize.GetProperty("result").GetProperty("serverInfo").GetProperty("name").GetString() == "cliphoard");
        var list = await Send("tools/list", new { });
        Check(list.GetProperty("result").GetProperty("tools").EnumerateArray().Select(tool => tool.GetProperty("name").GetString()).SequenceEqual(new[] { "connect", "connect_writer", "disconnect", "save_clip", "check_save", "search", "get_clip" }));
        var search = await Send("tools/call", new { name = "search", arguments = new { query = "synthetic" } });
        Check(search.GetProperty("result").GetProperty("content")[0].GetProperty("text").GetString() == "[]");
        Check((await Send("tools/call", new { name = "save_clip", arguments = new { text = "synthetic disconnected note" } })).TryGetProperty("error", out _));
        Check((await Send("tools/call", new { name = "search", arguments = new { query = "synthetic", limit = 26 } })).TryGetProperty("error", out _));
        Check((await Send("tools/call", new { name = "search", arguments = new { query = "synthetic", path = "C:\\synthetic" } })).TryGetProperty("error", out _));
        Check((await Send("tools/call", new { name = "get_clip", arguments = new { id = Guid.NewGuid().ToString("D") } })).TryGetProperty("error", out _));
        var disconnected = await Send("tools/call", new { name = "disconnect", arguments = new { } });
        Check(disconnected.GetProperty("result").GetProperty("content")[0].GetProperty("text").GetString()!.Contains("disconnected"));
        child.StandardInput.Close(); await child.WaitForExitAsync(deadline.Token);
        Check(child.ExitCode == 0 && (await errors).Length == 0);
        Console.WriteLine(JsonSerializer.Serialize(new { companion_checks = checks, status = "passed", synthetic_only = true }));
    }
}
