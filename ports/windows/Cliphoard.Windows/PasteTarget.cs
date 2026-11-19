using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
namespace Cliphoard.Windows;

/// Retains the original process handle so PID reuse cannot validate a different target.
internal sealed class PasteTarget : IDisposable
{
    private readonly nint hwnd;
    private readonly uint pid;
    private readonly SafeProcessHandle process;
    private readonly WindowStamp stamp;
    private PasteTarget(nint hwnd, uint pid, SafeProcessHandle process, WindowStamp stamp) { this.hwnd = hwnd; this.pid = pid; this.process = process; this.stamp = stamp; }
    internal static PasteTarget? Capture(nint ownWindow)
    {
        nint window = Native.GetForegroundWindow();
        if (window == 0 || window == ownWindow) return null;
        Native.GetWindowThreadProcessId(window, out uint id);
        if (id == 0 || id == (uint)Environment.ProcessId) return null;
        SafeProcessHandle handle = Native.OpenProcess(0x1000, false, id); // QUERY_LIMITED_INFORMATION only.
        if (handle.IsInvalid) { handle.Dispose(); return null; }
        WindowStamp? stamp = WindowStamp.Create(window);
        if (stamp is null) { handle.Dispose(); return null; }
        var target = new PasteTarget(window, id, handle, stamp);
        if (!target.ValidIdentity() || Native.GetForegroundWindow() != window) { target.Dispose(); return null; }
        return target;
    }
    private bool ValidIdentity()
    {
        if (!stamp.Valid || !Native.GetExitCodeProcess(process, out uint code) || code != 259) return false;
        Native.GetWindowThreadProcessId(hwnd, out uint current);
        if (current != pid || !Native.ProcessIdToSessionId(pid, out uint session) || session != (uint)Process.GetCurrentProcess().SessionId) return false;
        if (!Native.OpenProcessToken(process, 8, out SafeAccessTokenHandle token)) return false;
        using (token)
        using (var target = new WindowsIdentity(token.DangerousGetHandle()))
        using (var currentUser = WindowsIdentity.GetCurrent())
            return currentUser.User is not null && target.User is not null && currentUser.User.Equals(target.User);
    }
    internal bool RestoreFocus() => ValidIdentity() && Native.SetForegroundWindow(hwnd) && Native.GetForegroundWindow() == hwnd;
    internal bool CanPaste()
    {
        if (!ValidIdentity()) return false;
        // Refuse held modifiers; never alter another application's physical key state.
        foreach (int key in new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }) if ((Native.GetAsyncKeyState(key) & 0x8000) != 0) return false;
        return true;
    }
    internal bool IsVerifiedForeground() => CanPaste() && Native.GetForegroundWindow() == hwnd;
    internal PasteSubmission PasteOnlyIfVerifiedForeground(PasteInput input) => input.Submit(IsVerifiedForeground);
    public void Dispose() { stamp.Dispose(); process.Dispose(); }
}
