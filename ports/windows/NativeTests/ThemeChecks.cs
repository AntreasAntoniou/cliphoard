using Cliphoard.Windows;
using System.Text.Json;
internal static class ThemeChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool condition) { ++checks; if (!condition) throw new Exception($"Theme check {checks} failed"); }
        Check(DesktopThemes.All.Count == 18 && DesktopThemes.All.Select(t => t.Id).Distinct().Count() == 18);
        foreach (var theme in DesktopThemes.All)
        {
            var resolved = DesktopThemes.Resolve(theme.Id, false);
            Check(new[] { resolved.Bar, resolved.Card, resolved.Accent, resolved.Pin, resolved.Border, resolved.Hover, resolved.Tag, resolved.Muted }.All(hex => hex.StartsWith('#') && hex.Length is 7 or 9 && hex.Skip(1).All(Uri.IsHexDigit)));
            Check(resolved.Radius is >= 8 and <= 14 && resolved.SelectedWidth is >= 2 and <= 3.5);
        }
        Check(DesktopThemes.Resolve("system", true).Id == "oneDark");
        Check(DesktopThemes.Resolve("system", false).Id == "swiss");
        Check(DesktopThemes.Resolve("paper", false).Serif && DesktopThemes.Resolve("glass", true).Material);
        Check(DesktopThemes.Validate("unsupported") == "system" && DesktopThemes.ValidateLayout("unsupported") == "strip");
        Check(DesktopThemes.Height(10) == 200 && DesktopThemes.Height(900) == 400);
        string directory = Path.Combine(Path.GetTempPath(), "Cliphoard-themes-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new HistoryStore(directory); store.State.Theme = "dracula"; store.State.Layout = "spotlight"; store.State.PreviewHeight = 310; store.Save();
            var loaded = new HistoryStore(directory); Check(loaded.Writable && loaded.State.Theme == "dracula" && loaded.State.Layout == "spotlight" && loaded.State.PreviewHeight == 310);
            store.State.Theme = "unknown future theme"; store.State.Layout = "unknown future layout"; store.State.PreviewHeight = -1; store.Save(); loaded = new HistoryStore(directory);
            Check(loaded.Writable && loaded.State.Theme == "system" && loaded.State.Layout == "strip" && loaded.State.PreviewHeight == 200);
        }
        finally { Directory.Delete(directory, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { theme_checks = checks, themes = 18, layouts = 3, status = "passed" }));
    }
}
