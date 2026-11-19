using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Windows.Graphics;
namespace Cliphoard.Windows;

internal sealed class NativeWindowAdapter : IDisposable
{
    private readonly nint hwnd;
    private readonly Native.SubclassProc callback;
    private bool listener, shortcut, alternativeShortcut, session;
    private RectInt32? dockedBounds;
    internal event Action? WorkAreaChanged;
    internal static int RegistrationError { get; private set; }
    internal int ShortcutDeliveries { get; private set; }
    internal string LastShortcut { get; private set; } = "";
    internal event Action? ClipboardChanged;
    internal event Action? Shortcut;
    internal event Action<uint, uint>? SessionRevoked;
    internal event Action<uint, uint>? SessionChanged;
    internal event Action<uint>? TrayAction;
    internal NativeWindowAdapter(nint hwnd)
    {
        this.hwnd = hwnd; callback = WindowProcedure;
        if (!Native.SetWindowSubclass(hwnd, callback, 1, 0)) throw new IOException("Native window hook unavailable");
        listener = Native.AddClipboardFormatListener(hwnd);
        RegistrationError = 0;
        shortcut = Native.RegisterHotKey(hwnd, 1, 0x4007, 0x56);
        int primaryError = shortcut ? 0 : Marshal.GetLastWin32Error();
        alternativeShortcut = Native.RegisterHotKey(hwnd, 2, 0x4007, 0x42); // Ctrl+Alt+Shift+B avoids the Mac clipboard shortcut.
        RegistrationError = !shortcut ? primaryError : alternativeShortcut ? 0 : Marshal.GetLastWin32Error();
        session = Native.WTSRegisterSessionNotification(hwnd, 0);
        if (!listener || !shortcut || !alternativeShortcut || !session) { Dispose(); throw new IOException("Native fixture adapters unavailable"); }
    }
    private nint WindowProcedure(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint data)
    {
        // Never let managed exceptions cross the native callback boundary.
        try
        {
            // Docked content fills the window, including the native frame inset.
            if (message == 0x0083 && wParam != 0 && dockedBounds is not null) return 0;
            if (message == 0x0046 && lParam != 0 && dockedBounds is RectInt32 bounds)
            {
                var position = Marshal.PtrToStructure<Native.WindowPosition>(lParam);
                if ((position.Flags & 3) != 3)
                {
                    position.X = bounds.X; position.Y = bounds.Y;
                    position.Width = bounds.Width; position.Height = bounds.Height;
                    position.Flags &= ~3u;
                    Marshal.StructureToPtr(position, lParam, false);
                }
            }
            // A docked panel cannot enter Windows' interactive move/size loop.
            if (message == 0x0112 && ((uint)wParam & 0xFFF0) is 0xF000 or 0xF010) return 0;
            if (message is 0x007E or 0x001A or 0x02E0) WorkAreaChanged?.Invoke();
            if (message == Native.WM_CLIPBOARDUPDATE) ClipboardChanged?.Invoke();
            else if (message == Native.WM_HOTKEY && (wParam == 1 || wParam == 2))
            {
                LastShortcut = wParam == 2 ? "Ctrl+Alt+Shift+B" : "Ctrl+Alt+Shift+V";
                ++ShortcutDeliveries; Shortcut?.Invoke();
            }
            else if (message == TrayIcon.Message) TrayAction?.Invoke((uint)lParam);
            else if (message == Native.WM_WTSSESSION_CHANGE)
            {
                SessionChanged?.Invoke((uint)wParam, (uint)lParam);
                if (wParam == 2 || wParam == 4 || wParam == 6 || wParam == 7) SessionRevoked?.Invoke((uint)wParam, (uint)lParam);
            }
        }
        catch { /* UI actions fail closed and do not expose clipboard contents. */ }
        return Native.DefSubclassProc(window, message, wParam, lParam);
    }
    internal void PositionAtBottom(AppWindow window, int desiredWidth = 960, int desiredHeight = 320, bool chooseMonitor = false)
    {
        if (!Native.GetCursorPos(out Native.Point point)) throw new IOException("Monitor unavailable");
        nint monitor = chooseMonitor ? Native.MonitorFromPoint(point, 2) : Native.MonitorFromWindow(hwnd, 2);
        Native.MonitorInfo info = new() { Size = (uint)Marshal.SizeOf<Native.MonitorInfo>() };
        if (monitor == 0 || !Native.GetMonitorInfo(monitor, ref info)) throw new IOException("Work area unavailable");
        int width = Math.Min(desiredWidth, info.Work.Right - info.Work.Left), height = Math.Min(desiredHeight, info.Work.Bottom - info.Work.Top);
        if (width <= 0 || height <= 0) throw new IOException("Work area unavailable");
        dockedBounds = new RectInt32(info.Work.Left + (info.Work.Right - info.Work.Left - width) / 2, info.Work.Bottom - height, width, height);
        window.MoveAndResize(dockedBounds.Value);
        Native.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x33); // TOPMOST, recalculate frame, no move/size/activate.
    }
    public void Dispose()
    {
        if (listener) Native.RemoveClipboardFormatListener(hwnd);
        if (shortcut) Native.UnregisterHotKey(hwnd, 1);
        if (alternativeShortcut) Native.UnregisterHotKey(hwnd, 2);
        if (session) Native.WTSUnRegisterSessionNotification(hwnd);
        Native.RemoveWindowSubclass(hwnd, callback, 1);
        listener = shortcut = alternativeShortcut = session = false;
    }
}
