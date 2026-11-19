using Microsoft.Win32;
namespace Cliphoard.Windows;
internal static class DesktopStartup
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "Cliphoard.Windows";
    private static string Command => "\"" + Path.Combine(AppContext.BaseDirectory, "Cliphoard.Windows.exe") + "\" --background";
    internal static bool Enabled { get { using var key = Registry.CurrentUser.OpenSubKey(Key); return string.Equals(key?.GetValue(Name) as string, Command, StringComparison.OrdinalIgnoreCase); } }
    internal static void SetEnabled(bool value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(Key);
        string? current = key.GetValue(Name) as string;
        if (value) { if (current is not null && !string.Equals(current, Command, StringComparison.OrdinalIgnoreCase)) throw new IOException("Another installation owns this startup entry."); key.SetValue(Name, Command, RegistryValueKind.String); }
        else if (string.Equals(current, Command, StringComparison.OrdinalIgnoreCase)) key.DeleteValue(Name, false);
    }
}
