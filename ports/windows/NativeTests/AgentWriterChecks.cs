using Cliphoard.Windows;
using System.Text;
using System.Text.Json;
internal static class AgentWriterChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Agent writer check {checks} failed"); }
        async Task Refuses(Func<Task> action)
        {
            bool refused = false;
            try { await action(); } catch (Exception error) when (error is IOException or ArgumentException or InvalidOperationException) { refused = true; }
            Check(refused);
        }
        string parent = Path.Combine(Path.GetTempPath(), "CliphoardAgentWriterFixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(parent);
        try
        {
            double now = 2000000000; long ticks = 0; var history = new HistoryStore(Path.Combine(parent, "history"));
            using var controller = new AgentWriteController(history.SaveAgentNote, () => true, _ => { }, now: () => now, ticks: () => ticks);
            await controller.EnableAsync(parent);
            using var writer = new AgentWriterConnection(controller.Folder!, () => now, () => ticks);
            Guid first = Guid.NewGuid();
            Check(writer.Write(first, "synthetic writer end to end")["status"] == "pending");
            Check(writer.Check(first)["status"] == "pending");
            await controller.PollAsync(); Check(controller.Pending.Count == 1);
            await controller.ApproveAsync(controller.Pending[0].Id, controller.Pending[0].Opened.RequestDigest);
            var receipt = writer.Check(first); Check(receipt["status"] == "saved" && receipt["clip_id"] == first.ToString("D"));
            Check(writer.Check(first)["status"] == "saved" && history.State.Items.Count == 1);
            await Refuses(() => { writer.Write(first, "synthetic duplicate"); return Task.CompletedTask; });
            Guid late = Guid.NewGuid(); writer.Write(late, "synthetic late receipt");
            await controller.PollAsync(); await controller.ApproveAsync(controller.Pending[0].Id, controller.Pending[0].Opened.RequestDigest);
            now += 121; ticks += 121000; Check(writer.Check(late)["status"] == "saved");
            for (int i = 0; i < 32; ++i) writer.Write(Guid.NewGuid(), "synthetic bounded pending note");
            await Refuses(() => { writer.Write(Guid.NewGuid(), "synthetic excess pending"); return Task.CompletedTask; });
            controller.Disconnect(); await Refuses(() => { writer.Validate(); return Task.CompletedTask; });
            var safe = new HistoryItem { Id = Guid.NewGuid().ToString("D"), Kind = "Text", Text = "synthetic shared reference", Source = "synthetic", Tags = new() { "agent-share" } };
            var state = new HistoryState(); state.Items.Add(safe);
            Check(SharedAgentClips.Select(state).Length == 1);
            safe.Flags = 1; Check(SharedAgentClips.Select(state).Length == 0); safe.Flags = 0;
            safe.Tags.Clear(); Check(SharedAgentClips.Select(state).Length == 0); safe.Tags.Add("agent-share");
            safe.Text = "person@example.com"; Check(SharedAgentClips.Select(state).Length == 0);
            safe.Text = "synthetic shared reference"; safe.DocumentText = "enc1:synthetic"; Check(SharedAgentClips.Select(state).Length == 0);
            using var input = new MemoryStream(Encoding.UTF8.GetBytes("one\r\ntwø\n"));
            await using var lines = new BoundedCommandLines(input);
            Check(Encoding.UTF8.GetString((await lines.NextAsync(() => { }, default))!) == "one");
            Check(Encoding.UTF8.GetString((await lines.NextAsync(() => { }, default))!) == "twø");
            Check(await lines.NextAsync(() => { }, default) is null);
            await Refuses(async () => { await using var bad = new BoundedCommandLines(new MemoryStream("overlong\n"u8.ToArray())); await bad.NextAsync(() => { }, default, 3); });
            await Refuses(async () => { await using var bad = new BoundedCommandLines(new MemoryStream("partial"u8.ToArray())); await bad.NextAsync(() => { }, default); });
            await Refuses(async () => { await using var bad = new BoundedCommandLines(new MemoryStream(new byte[] { 0xFF, 10 })); await bad.NextAsync(() => { }, default); });
        }
        finally { Directory.Delete(parent, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { agent_writer_checks = checks, status = "passed", synthetic_only = true }));
    }
}
