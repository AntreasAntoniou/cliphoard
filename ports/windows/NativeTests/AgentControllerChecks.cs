using Cliphoard.Windows;
using System.Text.Json;
internal static class AgentControllerChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Agent controller check {checks} failed"); }
        string parent = Path.Combine(Path.GetTempPath(), "CliphoardAgentControllerFixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(parent);
        try
        {
            var history = new HistoryStore(Path.Combine(parent, "history"));
            double now = 2000000000; long tick = 0; bool available = true;
            AgentPermission remembered = AgentPermission.AskEveryTime;
            using var controller = new AgentWriteController((id, text) =>
            {
                uint before = Native.GetClipboardSequenceNumber(); bool saved = history.SaveAgentNote(id, text); Check(Native.GetClipboardSequenceNumber() == before); return saved;
            }, () => available, mode => remembered = mode, now: () => now, ticks: () => tick);
            Check(!controller.Connected && controller.Permission == AgentPermission.AskEveryTime);
            Check(!controller.SetPermission(AgentPermission.Session, true));
            await controller.EnableAsync(parent); Check(controller.Connected && !controller.Working);
            using var transport = new AgentWriteDirectory(controller.Folder!);
            AgentSession session = AgentWriteProtocol.DecodeSession(transport.Read("session.json", 1024)!, now);
            Check(session.Version == 2 && session.Lifetime == "bounded" && session.ExpiresAt == now + 900 && AgentHostIdentity.IsAlive(session.Host!));
            AgentPrepared Queue(string text, string? id = null)
            {
                var request = new AgentRequest(1, session.SessionId, id ?? Guid.NewGuid().ToString("D").ToUpperInvariant(), now, text);
                AgentPrepared prepared = AgentWriteProtocol.Prepare(request, session, now);
                transport.WriteExclusive(request.RequestId.ToLowerInvariant() + ".request", prepared.Data); return prepared;
            }
            AgentReceipt Receipt(AgentPrepared prepared) => AgentWriteProtocol.OpenReceipt(transport.Read(prepared.RequestId.ToLowerInvariant() + ".reply", 2048)!, prepared, prepared.SessionId, prepared.RequestId);
            using var first = Queue("synthetic first agent note"); await controller.PollAsync();
            Check(controller.Pending.Count == 1 && history.State.Items.Count == 0);
            await controller.ApproveAsync(first.RequestId, new string('0', 64)); Check(history.State.Items.Count == 0);
            await controller.ApproveAsync(first.RequestId, first.RequestDigest);
            Check(history.State.Items.Count == 1 && history.State.Items[0].Pinned && history.State.Items[0].Tags.SequenceEqual(new[] { "agent-note", "agent-share" }));
            Check(Receipt(first).Status == "saved");
            transport.WriteExclusive(first.RequestId.ToLowerInvariant() + ".request", first.Data); await controller.PollAsync(); Check(history.State.Items.Count == 1 && controller.Pending.Count == 0);
            using var second = Queue("synthetic first agent note"); await controller.PollAsync(); await controller.ApproveAsync(second.RequestId, second.RequestDigest);
            Check(history.State.Items.Count == 2 && Receipt(second).Status == "saved");
            using var sensitive = Queue("synthetic contact person@example.com"); await controller.PollAsync(); Check(Receipt(sensitive).Status == "rejected" && controller.Pending.Count == 0 && history.State.Items.Count == 2);
            Check(!controller.SetPermission(AgentPermission.Session, false));
            Check(controller.SetPermission(AgentPermission.Session, true) && remembered == AgentPermission.AskEveryTime);
            using var automatic = Queue("synthetic automatic session note"); await controller.PollAsync(); Check(Receipt(automatic).Status == "saved" && history.State.Items.Count == 3);
            Check(controller.SetPermission(AgentPermission.AskEveryTime, false));
            using var expiring = Queue("synthetic expiring note"); await controller.PollAsync(); Check(controller.Pending.Count == 1);
            now += 121; tick += 121000; await controller.PollAsync(); Check(Receipt(expiring).Status == "expired" && history.State.Items.Count == 3);
            using var changed = Queue("synthetic original pending note"); await controller.PollAsync();
            transport.Remove(changed.RequestId.ToLowerInvariant() + ".request");
            using var replacement = Queue("synthetic changed pending note", changed.RequestId); await controller.PollAsync();
            Check(controller.Pending.Count == 0 && history.State.Items.Count == 3);
            Check(controller.SetPermission(AgentPermission.FullAccess, true) && remembered == AgentPermission.FullAccess);
            controller.Disconnect(resetSession: false); Check(transport.Read("session.json", 1024) is null);
            await controller.EnableAsync(parent);
            using var continuous = new AgentWriteDirectory(controller.Folder!);
            AgentSession ongoing = AgentWriteProtocol.DecodeSession(continuous.Read("session.json", 1024)!, now);
            Check(ongoing.Lifetime == "whileAppRuns" && ongoing.ExpiresAt is null);
            now += 3600; tick += 3600000;
            var finalRequest = new AgentRequest(1, ongoing.SessionId, Guid.NewGuid().ToString("D").ToUpperInvariant(), now, "synthetic continuous note");
            using var final = AgentWriteProtocol.Prepare(finalRequest, ongoing, now); continuous.WriteExclusive(final.RequestId.ToLowerInvariant() + ".request", final.Data); await controller.PollAsync();
            Check(history.State.Items.Count == 4 && AgentWriteProtocol.OpenReceipt(continuous.Read(final.RequestId.ToLowerInvariant() + ".reply", 2048)!, final, final.SessionId, final.RequestId).Status == "saved");
            Check(controller.SetPermission(AgentPermission.AskEveryTime, false) && !controller.Connected && continuous.Read("session.json", 1024) is null);
            await controller.EnableAsync(parent); available = false; await controller.PollAsync(); Check(!controller.Connected && controller.Pending.Count == 0);
            Check(new HistoryStore(Path.Combine(parent, "history")).State.Items.Count == 4);
        }
        finally { Directory.Delete(parent, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { agent_controller_checks = checks, status = "passed", synthetic_keys_and_notes_only = true }));
    }
}
