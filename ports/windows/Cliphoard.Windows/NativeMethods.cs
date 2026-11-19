using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Cliphoard.Windows;

internal static class Native
{
    internal const uint WM_CLIPBOARDUPDATE = 0x031D, WM_HOTKEY = 0x0312, WM_WTSSESSION_CHANGE = 0x02B1;
    internal const uint CF_UNICODETEXT = 13;
    internal delegate nint SubclassProc(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data);
    internal delegate nint KeyboardHook(int code, nuint message, nint data);
    [StructLayout(LayoutKind.Sequential)] internal struct KeyboardHookData { internal uint Key, Scan, Flags, Time; internal nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] internal struct Message { internal nint Window; internal uint Id; internal nuint WParam; internal nint LParam; internal uint Time; internal Point Position; internal uint Private; }
    [DllImport("user32.dll", EntryPoint = "SetWindowsHookExW", SetLastError = true)] internal static extern nint SetWindowsHookEx(int id, KeyboardHook callback, nint module, uint thread);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] internal static extern nint CallNextHookEx(nint hook, int code, nuint message, nint data);
    [DllImport("user32.dll", EntryPoint = "GetMessageW")] internal static extern int GetMessage(out Message message, nint window, uint min, uint max);
    [DllImport("user32.dll", EntryPoint = "PostThreadMessageW")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool PostThreadMessage(uint thread, uint message, nuint wParam, nint lParam);
    [DllImport("kernel32.dll")] internal static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", EntryPoint = "GetModuleHandleW", CharSet = CharSet.Unicode)] internal static extern nint GetModuleHandle(string? name);
    [StructLayout(LayoutKind.Sequential)] internal struct Point { internal int X, Y; }
    [StructLayout(LayoutKind.Sequential)] internal struct WindowPosition { internal nint Window, After; internal int X, Y, Width, Height; internal uint Flags; }
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { internal int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] internal struct MonitorInfo { internal uint Size; internal Rect Monitor, Work; internal uint Flags; }
    [StructLayout(LayoutKind.Sequential)] internal struct KeyboardInput { internal ushort Key, Scan; internal uint Flags, Time; internal nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] internal struct MouseInput { internal int X, Y; internal uint Data, Flags, Time; internal nuint Extra; }
    [StructLayout(LayoutKind.Explicit)] internal struct InputUnion { [FieldOffset(0)] internal KeyboardInput Keyboard; [FieldOffset(0)] internal MouseInput Mouse; }
    [StructLayout(LayoutKind.Sequential)] internal struct Input { internal uint Type; internal InputUnion Data; }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool AddClipboardFormatListener(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool RemoveClipboardFormatListener(nint hwnd);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UnregisterHotKey(nint hwnd, int id);
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetWindowSubclass(nint hwnd, SubclassProc callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc callback, nuint id);
    [DllImport("comctl32.dll")] internal static extern nint DefSubclassProc(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint hwnd, out uint pid);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", EntryPoint = "SetPropW", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetProp(nint hwnd, string name, nint value);
    [DllImport("user32.dll", EntryPoint = "GetPropW", CharSet = CharSet.Unicode)] internal static extern nint GetProp(nint hwnd, string name);
    [DllImport("user32.dll", EntryPoint = "RemovePropW", CharSet = CharSet.Unicode)] internal static extern nint RemoveProp(nint hwnd, string name);
    [DllImport("user32.dll", SetLastError = true)] internal static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] internal static extern nint MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll")] internal static extern nint MonitorFromWindow(nint window, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern uint RegisterClipboardFormat(string name);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool OpenClipboard(nint owner);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CloseClipboard();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EmptyClipboard();
    [DllImport("user32.dll")] internal static extern nint GetClipboardData(uint format);
    [DllImport("user32.dll")] internal static extern nint SetClipboardData(uint format, nint handle);
    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] internal static extern nint GetClipboardOwner();
    [DllImport("kernel32.dll")] internal static extern nint GlobalAlloc(uint flags, nuint bytes);
    [DllImport("kernel32.dll")] internal static extern nint GlobalLock(nint handle);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GlobalUnlock(nint handle);
    [DllImport("kernel32.dll")] internal static extern nuint GlobalSize(nint handle);
    [DllImport("kernel32.dll")] internal static extern nint GlobalFree(nint handle);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint code);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ProcessIdToSessionId(uint pid, out uint session);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("wtsapi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool WTSRegisterSessionNotification(nint hwnd, uint flags);
    [DllImport("wtsapi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool WTSUnRegisterSessionNotification(nint hwnd);
}
