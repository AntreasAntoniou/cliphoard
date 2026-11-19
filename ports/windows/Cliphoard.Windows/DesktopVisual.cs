using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
namespace Cliphoard.Windows;
internal static class DesktopVisual
{
    internal static Color Color(string hex)
    {
        string value = hex.TrimStart('#');
        byte alpha = value.Length == 8 ? Convert.ToByte(value[..2], 16) : (byte)255;
        int offset = value.Length == 8 ? 2 : 0;
        return global::Windows.UI.Color.FromArgb(alpha, Convert.ToByte(value.Substring(offset, 2), 16), Convert.ToByte(value.Substring(offset + 2, 2), 16), Convert.ToByte(value.Substring(offset + 4, 2), 16));
    }
    internal static SolidColorBrush Brush(string hex) => new(Color(hex));
    internal static SolidColorBrush Alpha(string hex, double opacity) { var color = Color(hex); color.A = (byte)(255 * opacity); return new(color); }
    internal static TextBlock Text(string text, DesktopTheme theme, double size = 12, bool muted = false) => new() { Text = text, FontSize = size, Foreground = Brush(muted ? theme.Muted : theme.Primary), FontFamily = new FontFamily(theme.Font), TextWrapping = TextWrapping.Wrap };
    internal static FontIcon Icon(string glyph, string color, double size = 12) => new() { Glyph = glyph, FontSize = size, FontFamily = new FontFamily("Segoe Fluent Icons"), Foreground = Brush(color) };
    internal static Button IconButton(string glyph, string name, DesktopTheme theme, Action action, double size = 16)
    {
        var button = new Button { Content = Icon(glyph, theme.Muted, size), Width = 36, Height = 36, Padding = new Thickness(0), CornerRadius = new CornerRadius(7), BorderThickness = new Thickness(0), Background = Brush("#00000000") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name); ToolTipService.SetToolTip(button, name); button.Click += (_, _) => action(); return button;
    }
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint window, uint attribute, ref int value, int size);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    internal static void FitWindow(Window window, int width, int height)
    {
        window.AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Cliphoard.ico"));
        nint hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window); double scale = Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
        if (!Native.GetCursorPos(out Native.Point cursor)) return;
        var monitor = new Native.MonitorInfo { Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.MonitorInfo>() };
        if (!Native.GetMonitorInfo(Native.MonitorFromPoint(cursor, 2), ref monitor)) return;
        int w = Math.Min((int)(width * scale), monitor.Work.Right - monitor.Work.Left - 48), h = Math.Min((int)(height * scale), monitor.Work.Bottom - monitor.Work.Top - 48);
        window.AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(monitor.Work.Left + (monitor.Work.Right - monitor.Work.Left - w) / 2, monitor.Work.Top + (monitor.Work.Bottom - monitor.Work.Top - h) / 2, Math.Max(w, 1), Math.Max(h, 1)));
    }
    internal static void StyleWindow(Window window, DesktopTheme theme, bool borderless = false)
    {
        window.AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", theme.Dark ? "Cliphoard.Dark.ico" : "Cliphoard.Light.ico"));
        nint hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        int dark = theme.Dark ? 1 : 0; DwmSetWindowAttribute(hwnd, 20, ref dark, 4);
        var border = Color(theme.Border); var background = Color(theme.Bar); double alpha = border.A / 255.0;
        int r = (int)(border.R * alpha + background.R * (1 - alpha)), g = (int)(border.G * alpha + background.G * (1 - alpha)), b = (int)(border.B * alpha + background.B * (1 - alpha));
        int nativeColor = borderless ? -2 : r | (g << 8) | (b << 16); DwmSetWindowAttribute(hwnd, 34, ref nativeColor, 4);
        var title = window.AppWindow.TitleBar; title.BackgroundColor = background; title.ForegroundColor = Color(theme.Primary); title.ButtonBackgroundColor = background; title.ButtonForegroundColor = Color(theme.Primary);
    }
    internal static string Glyph(HistoryItem item) => item.Kind switch { "Link" => "\uE71B", "Image" => "\uEB9F", "Files" => "\uE8A5", "Color" => "\uE790", _ => "\uE8A4" };
}
