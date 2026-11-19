using System.Runtime.InteropServices;
namespace Cliphoard.Windows;
internal sealed class TrayIcon : IDisposable
{
    internal const uint Message = 0x8001;
    private Notify data;
    private bool dark;
    internal TrayIcon(nint hwnd)
    {
        dark = SystemDark();
        data = new() { Size = (uint)Marshal.SizeOf<Notify>(), Window = hwnd, Id = 1, Flags = 1 | 2 | 4, Callback = Message, Icon = MakeIcon(dark), Tip = "Cliphoard · clipboard history", Info = "", Title = "" };
        if (data.Icon == 0 || !ShellNotify(0, ref data)) { if (data.Icon != 0) DestroyIcon(data.Icon); throw new IOException("Tray unavailable"); }
    }
    internal void RefreshTheme()
    {
        bool nextDark = SystemDark();
        if (nextDark == dark) return;
        nint icon = MakeIcon(nextDark);
        if (icon == 0) return;
        Notify next = data; next.Flags = 2; next.Icon = icon;
        if (!ShellNotify(1, ref next)) { DestroyIcon(icon); return; }
        nint previous = data.Icon; data.Icon = icon; dark = nextDark; DestroyIcon(previous);
    }
    internal void NotifyAgentRequest()
    {
        Notify notification = data; notification.Flags = 0x10; notification.Title = "Cliphoard";
        notification.Info = "An agent is requesting permission to save a note. Open Cliphoard to review it.";
        notification.InfoFlags = 1 | 0x10 | 0x80; notification.Timeout = 10000; ShellNotify(1, ref notification);
    }
    internal int Menu()
    {
        nint menu = CreatePopupMenu();
        try
        {
            AppendMenu(menu, 0, 1, "Open Cliphoard"); AppendMenu(menu, 0, 2, "Pause / resume capture"); AppendMenu(menu, 0, 3, "Settings"); AppendMenu(menu, 0x800, 0, null); AppendMenu(menu, 0, 4, "Quit Cliphoard");
            Native.GetCursorPos(out Native.Point point); Native.SetForegroundWindow(data.Window);
            return TrackPopupMenu(menu, 0x100 | 0x2, point.X, point.Y, 0, data.Window, 0);
        }
        finally { DestroyMenu(menu); }
    }
    public void Dispose() { ShellNotify(2, ref data); if (data.Icon != 0) DestroyIcon(data.Icon); }
    private static bool SystemDark()
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int value && value == 0;
    }
    private static nint MakeIcon(bool dark)
    {
        string path = Path.Combine(AppContext.BaseDirectory, "Assets", dark ? "Cliphoard.Dark.ico" : "Cliphoard.Light.ico");
        return LoadImage(0, path, 1, 32, 32, 0x10);
    }
    [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode)] private static extern nint LoadImage(nint instance, string path, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(nint icon);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Notify
    {
        internal uint Size; internal nint Window; internal uint Id, Flags, Callback; internal nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string Tip;
        internal uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string Info;
        internal uint Timeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string Title;
        internal uint InfoFlags; internal Guid Guid; internal nint Balloon;
    }
    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShellNotify(uint action, ref Notify data);
    [DllImport("user32.dll")] private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(nint menu, uint flags, nuint id, string? text);
    [DllImport("user32.dll")] private static extern int TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rect);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(nint menu);
}
