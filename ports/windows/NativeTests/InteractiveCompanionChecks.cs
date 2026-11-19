using Cliphoard.Windows;
using System.Diagnostics;
using System.Text.Json;
internal static class InteractiveCompanionChecks
{
    private const string Root = @"C:\CliphoardDev\qualification\interactive-profile";
    internal static async Task RunAsync(bool writer)
    {
        if (File.ReadAllText(Path.Combine(Root, ".synthetic-only")) != "CLIPHOARD_SYNTHETIC_V1") throw new IOException("Synthetic profile is unavailable.");
        string executable = @"C:\CliphoardDev\src\ports\windows\Cliphoard.Windows\bin\ARM64\Debug\net10.0-windows10.0.19041.0\win-arm64\Companion\Cliphoard.Companion.exe";
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        using var process = Process.Start(start)!; using var job = new OwnedProcessJob(process); Task<string> errors = process.StandardError.ReadToEndAsync();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMinutes(8)); int sequence = 0, checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Interactive companion check {checks} failed"); }
        void Phase(string phase) => File.WriteAllText(@"C:\CliphoardDev\evidence\interactive-companion-phase.json", JsonSerializer.Serialize(new { phase, writer, synthetic_only = true }));
        async Task<JsonElement> Rpc(string method, object parameters)
        {
            int id = ++sequence; await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, method, @params = parameters }));
            string line = await process.StandardOutput.ReadLineAsync(cancellation.Token) ?? throw new IOException("Companion exited.");
            using var json = JsonDocument.Parse(line); Check(json.RootElement.GetProperty("id").GetInt32() == id);
            if (json.RootElement.TryGetProperty("error", out _)) throw new IOException("Companion refused the synthetic interactive request.");
            return json.RootElement.GetProperty("result").Clone();
        }
        async Task<JsonElement> Tool(string name, object arguments)
        {
            JsonElement result = await Rpc("tools/call", new { name, arguments });
            using var document = JsonDocument.Parse(result.GetProperty("content")[0].GetProperty("text").GetString()!); return document.RootElement.Clone();
        }
        await Rpc("initialize", new { protocolVersion = "2024-11-05", capabilities = new { }, clientInfo = new { name = "synthetic UI qualification", version = "1" } });
        Phase(writer ? "choose_synthetic_connection_folder" : "choose_and_unlock_synthetic_export");
        JsonElement connected = await Tool(writer ? "connect_writer" : "connect", new { });
        Check(connected.GetProperty("status").GetString() == (writer ? "ready" : "connected"));
        if (writer)
        {
            Phase("approve_synthetic_note_in_settings");
            JsonElement saved = await Tool("save_clip", new { text = "Synthetic approved MCP note about a restaurant" });
            string id = saved.GetProperty("request_id").GetString()!;
            while (saved.GetProperty("status").GetString() is "pending" or "unknown") { await Task.Delay(1000, cancellation.Token); saved = await Tool("check_save", new { request_id = id }); }
            Check(saved.GetProperty("status").GetString() == "saved");
            Check((await Tool("check_save", new { request_id = id })).GetProperty("clip_id").GetString() == id);
            JsonElement found = await Tool("search", new { query = "approved MCP" }); Check(found.GetArrayLength() == 1);
        }
        else
        {
            Check(connected.GetProperty("clips").GetInt32() == 2);
            Check((await Tool("search", new { query = "restaurant" })).GetArrayLength() == 1);
            Check((await Tool("search", new { query = "person@example.com" })).GetArrayLength() == 0);
            JsonElement unicode = await Tool("search", new { query = "Unicode" }); Check(unicode.GetArrayLength() == 1);
            string id = unicode[0].GetProperty("id").GetString()!;
            JsonElement page = await Tool("get_clip", new { id, offset = 3999 }); Check(page.GetProperty("text").GetString()!.StartsWith("🌩synthetic Unicode page two") && page.GetProperty("next_offset").ValueKind == JsonValueKind.Null);
        }
        await Tool("disconnect", new { }); Check((await Tool("search", new { query = "synthetic" })).GetArrayLength() == 0);
        process.StandardInput.Close(); await process.WaitForExitAsync(cancellation.Token); Check(process.ExitCode == 0 && (await errors).Length == 0);
        Phase("passed"); Console.WriteLine(JsonSerializer.Serialize(new { interactive_companion_checks = checks, writer, status = "passed", synthetic_only = true }));
    }
}
