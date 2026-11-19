using Cliphoard.Windows;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
internal static class AgentProtocolChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Agent protocol check {checks} failed"); }
        void Refuses(Action action)
        {
            try { action(); } catch (Exception error) when (error is IOException or CryptographicException or JsonException or ArgumentException) { Check(true); return; }
            Check(false);
        }
        using var fixture = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.AgentProtocol.json")!;
        using var json = JsonDocument.Parse(fixture); JsonElement golden = json.RootElement;
        double now = golden.GetProperty("now").GetDouble();
        byte[] privateKey = golden.GetProperty("privateKey").GetBytesFromBase64();
        byte[] sessionBytes = golden.GetProperty("session").GetBytesFromBase64();
        AgentSession session = AgentWriteProtocol.DecodeSession(sessionBytes, now);
        Check(AgentWriteProtocol.EncodeSession(session, now).SequenceEqual(sessionBytes));
        AgentHost host = AgentHostIdentity.Current();
        Check(AgentHostIdentity.IsAlive(host));
        Check(!AgentHostIdentity.IsAlive(host with { StartMicroseconds = (host.StartMicroseconds + 1) % 1000000 }));
        Check(!AgentHostIdentity.IsAlive(host with { BootSession = Guid.NewGuid().ToString("D") }));
        Check(!AgentHostIdentity.IsAlive(host with { ProcessId = 0 }));
        var outbound = new List<object>();
        try
        {
            foreach (JsonElement sample in golden.GetProperty("samples").EnumerateArray())
            {
                string id = sample.GetProperty("requestID").GetString()!, text = sample.GetProperty("text").GetString()!;
                byte[] envelope = sample.GetProperty("envelope").GetBytesFromBase64();
                using AgentOpened opened = AgentWriteProtocol.OpenRequest(envelope, session, privateKey, now);
                Check(opened.Request.Text == text && opened.Request.RequestId == id);
                Check(opened.ResponseKey.SequenceEqual(sample.GetProperty("responseKey").GetBytesFromBase64()));
                using var prepared = new AgentPrepared(envelope, opened.ResponseKey.ToArray(), opened.RequestDigest, session.SessionId, id);
                AgentReceipt receipt = AgentWriteProtocol.OpenReceipt(sample.GetProperty("receipt").GetBytesFromBase64(), prepared, session.SessionId, id);
                Check(receipt.Status == "saved" && receipt.ClipId == id);
                Check(AgentWriteProtocol.OpenReceipt(AgentWriteProtocol.SealReceipt("rejected", opened), prepared, session.SessionId, id).Status == "rejected");
                using AgentPrepared windows = AgentWriteProtocol.Prepare(opened.Request, session, now);
                using AgentOpened roundtrip = AgentWriteProtocol.OpenRequest(windows.Data, session, privateKey, now);
                Check(roundtrip.Request == opened.Request);
                outbound.Add(new { envelope = Convert.ToBase64String(windows.Data), text, requestID = id, receipt = Convert.ToBase64String(AgentWriteProtocol.SealReceipt("saved", opened)), responseKey = Convert.ToBase64String(windows.ResponseKey) });
                Refuses(() => AgentWriteProtocol.OpenRequest(envelope, session, privateKey, now + 120));
                Refuses(() => AgentWriteProtocol.OpenReceipt(sample.GetProperty("receipt").GetBytesFromBase64(), prepared, session.SessionId, Guid.NewGuid().ToString("D").ToUpperInvariant()));
                Refuses(() => AgentWriteProtocol.OpenRequest(Encoding.UTF8.GetBytes(" " + Encoding.UTF8.GetString(envelope)), session, privateKey, now));
            }
            Refuses(() => AgentWriteProtocol.DecodeSession(sessionBytes, now + 900));
            Refuses(() => AgentWriteProtocol.DecodeSession(sessionBytes, now - 6));
            Refuses(() => AgentWriteProtocol.Prepare(new(1, session.SessionId, Guid.NewGuid().ToString("D").ToUpperInvariant(), now + 6, "synthetic future"), session, now));
            Refuses(() => AgentWriteProtocol.Prepare(new(1, session.SessionId, Guid.NewGuid().ToString("D").ToUpperInvariant(), now, "synthetic\0note"), session, now));
            Refuses(() => AgentWriteProtocol.Prepare(new(1, session.SessionId, Guid.NewGuid().ToString("D").ToUpperInvariant(), now, new string('x', 32769)), session, now));
            Refuses(() => AgentWriteProtocol.Prepare(new(1, session.SessionId, Guid.NewGuid().ToString("D").ToUpperInvariant(), now, "synthetic"), session with { PublicKey = new byte[32] }, now));
            Directory.CreateDirectory(@"C:\CliphoardDev\evidence");
            File.WriteAllBytes(@"C:\CliphoardDev\evidence\windows-agent-wire.json", JsonSerializer.SerializeToUtf8Bytes(outbound));
        }
        finally { CryptographicOperations.ZeroMemory(privateKey); }
        Console.WriteLine(JsonSerializer.Serialize(new { agent_protocol_checks = checks, status = "passed", synthetic_keys_and_notes_only = true }));
    }
}
