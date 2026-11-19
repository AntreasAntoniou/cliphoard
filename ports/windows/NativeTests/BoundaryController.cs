using Cliphoard.Windows;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

internal static class TokenLevel
{
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int kind, nint data, int size, out int needed);
    [DllImport("advapi32.dll")] private static extern nint GetSidSubAuthorityCount(nint sid);
    [DllImport("advapi32.dll")] private static extern nint GetSidSubAuthority(nint sid, uint index);
    internal static int Current()
    {
        using var identity = WindowsIdentity.GetCurrent();
        nint data = Marshal.AllocHGlobal(1024);
        try
        {
            if (!GetTokenInformation(identity.AccessToken, 25, data, 1024, out _)) throw new Exception("Integrity metadata unavailable");
            nint sid = Marshal.ReadIntPtr(data);
            return Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(Marshal.ReadByte(GetSidSubAuthorityCount(sid)) - 1)));
        }
        finally { Marshal.FreeHGlobal(data); }
    }
}

internal sealed class BoundaryController : Form
{
    private Process? elevated;
    private readonly Label status = new() { Dock = DockStyle.Fill, AutoSize = false };
    private bool probing;
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool LockWorkStation();
    [DllImport("wtsapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WTSDisconnectSession(nint server, uint session, bool wait);
    internal BoundaryController()
    {
        Text = "Cliphoard SYNTHETIC boundary controller (medium only)"; Width = 1050; Height = 400;
        if (TokenLevel.Current() != 0x2000) throw new Exception("Controller must run at medium integrity");
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 175 };
        void Add(string caption, EventHandler handler) { var b = new Button { Text = caption, Width = 235, Height = 70 }; b.Click += handler; buttons.Controls.Add(b); }
        Add("Launch elevated synthetic editor (UAC)", (_, _) =>
        {
            if (elevated is not null && !elevated.HasExited) return;
            elevated = Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "--elevated-editor") { UseShellExecute = true, Verb = "runas" });
            status.Text = "Approve only the owned synthetic editor in Windows UAC. No account/security changes.";
        });
        Add("Probe UIPI delivery (one chord)", async (_, _) => await Probe());
        Add("Lock this guest session (owner unlock)", (_, _) => status.Text = "Lock request initiated=" + LockWorkStation());
        Add("Disconnect this guest session (owner reconnect)", (_, _) => status.Text = "Disconnect request initiated=" + WTSDisconnectSession(0, (uint)Process.GetCurrentProcess().SessionId, false));
        Add("Probe isolated non-input desktop", async (_, _) =>
        {
            if (probing || Native.GetForegroundWindow() != Handle) return;
            probing = true;
            int active = 1;
            EventHandler revoked = (_, _) => Volatile.Write(ref active, 0);
            Deactivate += revoked;
            try
            {
                Clipboard.SetText("[CLIPHOARD_SYNTHETIC_V1] Isolated desktop probe");
                status.Text = await IsolatedDesktopProbe.Run(() => Volatile.Read(ref active) == 1);
            }
            catch (Exception e) { status.Text = "Isolated probe refused: " + e.GetType().Name; }
            finally { Deactivate -= revoked; probing = false; }
        });
        Controls.Add(status); Controls.Add(buttons);
        status.Text = "Synthetic fixtures only. Session actions affect this guest session, never the host. Owner handles UAC and unlock/reconnect.";
    }
    private async Task Probe()
    {
        if (probing) return;
        probing = true;
        try
        {
            await Task.Delay(200);
            if (elevated is null || elevated.HasExited) throw new Exception("Owned elevated editor is not running");
            using var before = JsonDocument.Parse(File.ReadAllText(@"C:\CliphoardDev\evidence\editor-high-receipt.json"));
            var b = before.RootElement;
            nint target = (nint)b.GetProperty("hwnd").GetInt64();
            int targetPid = b.GetProperty("pid").GetInt32();
            int targetIntegrity = b.GetProperty("integrity").GetInt32();
            Native.GetWindowThreadProcessId(target, out uint actualPid);
            if (targetPid != elevated.Id || actualPid != targetPid || targetIntegrity < 0x3000
                || b.GetProperty("session").GetInt32() != Process.GetCurrentProcess().SessionId || !Native.IsWindow(target)) throw new Exception("Elevated fixture identity mismatch");
            if (b.GetProperty("characters").GetInt32() != 0 || b.GetProperty("paste_messages").GetInt32() != 0) throw new Exception("Use a fresh, empty elevated fixture");
            // This is an explicit API probe, not a bypass of the frontend's target guard.
            Clipboard.SetText("[CLIPHOARD_SYNTHETIC_V1] UIPI blocked probe");
            uint sequence = Native.GetClipboardSequenceNumber();
            using var input = new PasteInput();
            if (!Native.SetForegroundWindow(target)) throw new Exception("Elevated foreground admission denied");
            await Task.Delay(100);
            bool Foreground() => !elevated.HasExited && Native.GetForegroundWindow() == target && TokenLevel.Current() == 0x2000;
            if (!Foreground()) throw new Exception("Elevated fixture is not foreground");
            var result = input.Submit(Foreground);
            bool disabled = !input.Available;
            int batches = input.NativeBatches;
            PasteSubmission? second = input.LastNativeCount < input.LastRequestedCount ? input.Submit(Foreground) : null;
            await Task.Delay(200);
            using var after = JsonDocument.Parse(File.ReadAllText(@"C:\CliphoardDev\evidence\editor-high-receipt.json"));
            var a = after.RootElement;
            var receipt = new { sender_integrity = TokenLevel.Current(), target_integrity = targetIntegrity, target_pid = targetPid,
                foreground_matched = Native.GetForegroundWindow() == target, requested = input.LastRequestedCount, returned = input.LastNativeCount,
                win32_error = input.LastNativeError, result = result.ToString(), disabled, native_batches = batches,
                second_result = second?.ToString(), no_second_native_call = input.NativeBatches == batches,
                before_characters = 0, after_characters = a.GetProperty("characters").GetInt32(), after_pastes = a.GetProperty("paste_messages").GetInt32(),
                clipboard_sequence_before_input = sequence, clipboard_sequence_after_input = Native.GetClipboardSequenceNumber(),
                control_released = (Native.GetAsyncKeyState(0xA2) & 0x8000) == 0, v_released = (Native.GetAsyncKeyState(0x56) & 0x8000) == 0 };
            string json = JsonSerializer.Serialize(receipt);
            File.WriteAllText(@"C:\CliphoardDev\evidence\actual-short-uipi.json", json);
            status.Text = json;
        }
        catch (Exception e) { status.Text = "Boundary probe refused: " + e.GetType().Name; }
        finally { probing = false; }
    }
}
