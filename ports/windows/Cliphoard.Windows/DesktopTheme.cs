using System.Text.Json;
namespace Cliphoard.Windows;

internal sealed class DesktopTheme
{
    public string Id { get; set; } = "system";
    public string Title { get; set; } = "";
    public string Bar { get; set; } = "#F5F5F5";
    public string Card { get; set; } = "#FFFFFF";
    public string Accent { get; set; } = "#2980F5";
    public string Pin { get; set; } = "#F28C1A";
    public string Border { get; set; } = "#D1D1D1";
    public string Hover { get; set; } = "#9E9E9E";
    public string Tag { get; set; } = "#EDEDED";
    public string Muted { get; set; } = "#6B6B6B";
    public double Radius { get; set; } = 12;
    public double SelectedWidth { get; set; } = 2;
    public bool Dark { get; set; }
    public bool Material { get; set; }
    public bool Serif { get; set; }
    public string Primary => Dark ? "#ECECF0" : "#222222";
    public string Font => Serif ? "Georgia" : "Segoe UI Variable";
    public override string ToString() => Title;
}
internal static class DesktopThemes
{
    private sealed class Catalog { public List<DesktopTheme> Themes { get; set; } = new(); }
    internal static readonly IReadOnlyList<DesktopTheme> All = Load();
    internal static readonly string[] Layouts = { "Card Strip", "Spotlight Palette", "Compact List" };
    private static List<DesktopTheme> Load()
    {
        using var stream = typeof(DesktopThemes).Assembly.GetManifestResourceStream("Cliphoard.Windows.ThemePresets.json") ?? throw new IOException("Theme palette missing");
        return JsonSerializer.Deserialize<Catalog>(stream)?.Themes ?? throw new IOException("Theme palette invalid");
    }
    internal static DesktopTheme Resolve(string id, bool systemDark) => All.FirstOrDefault(t => t.Id == (id == "system" ? systemDark ? "oneDark" : "swiss" : id)) ?? All.First(t => t.Id == "swiss");
    internal static string Validate(string? id) => All.Any(t => t.Id == id) ? id! : "system";
    internal static string ValidateLayout(string? layout) => layout is "strip" or "spotlight" or "list" ? layout : "strip";
    internal static int Height(int value) => Math.Clamp(value, 200, 400);
}
