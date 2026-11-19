using System.Text.Json;
using System.Text.RegularExpressions;

namespace Cliphoard.Windows;

internal static class ContentShape
{
    private static readonly HashSet<string> Commands = new() { "git", "cd", "brew", "sudo", "docker", "kubectl", "npm", "pip", "ssh", "curl" };
    private static readonly string[] Keywords = { "func ", "def ", "class ", "function ", "return ", "import ", "var ", "let ", "=> ", "public ", "private " };
    private static bool Matches(string text, string pattern) => Regex.IsMatch(text, pattern, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    internal static string? Of(string text, string kind = "Text")
    {
        if (kind is not ("Text" or "Code")) return null;
        string value = text.Trim();
        if (value.Length == 0) return null;
        string[] lines = value.Split('\n');
        bool single = value.IndexOfAny(new[] { ' ', '\t', '\n' }) < 0;
        try
        {
            if (single && Matches(value, @"^[\p{L}+.\-]+://.+$")) return "url";
            string verb = value.Split(new[] { ' ', '\t', '\n' }, StringSplitOptions.RemoveEmptyEntries)[0];
            if (value.StartsWith("$ ", StringComparison.Ordinal) || value.StartsWith("$\t", StringComparison.Ordinal)) return "command";
            if (value.StartsWith('#') && Commands.Contains(value[1..].TrimStart(' ', '\t').Split(' ')[0].ToLowerInvariant()) || Commands.Contains(verb)) return "command";
            if (value.Contains("```") || (value.Contains('{') || value.Contains('}')) && value.Contains(';')
                || lines.Length >= 2 && lines.Any(line => line.StartsWith(' ') || line.StartsWith('\t')) && Keywords.Any(value.Contains)) return "code";
            if (value[0] is '{' or '[' && value[^1] is '}' or ']')
            {
                try { using var document = JsonDocument.Parse(value); return "json"; }
                catch (JsonException) { }
            }
            if (lines.Length >= 2 && lines.Select(line => line.Trim()).Count(line => line.StartsWith("- ", StringComparison.Ordinal) || Matches(line, @"^[A-Za-z0-9_.-]+:( .*)?$")) >= 2) return "yaml";
            if (single && (value.StartsWith('/') || value.StartsWith("~/", StringComparison.Ordinal) || value.StartsWith("./", StringComparison.Ordinal) || value.StartsWith("../", StringComparison.Ordinal)
                || value.Length >= 3 && char.IsAsciiLetter(value[0]) && value[1] == ':' && value[2] == '\\')) return "path";
            if (single && value.StartsWith('#') && value.Length is 4 or 5 or 7 or 9 && value[1..].All(Uri.IsHexDigit)) return "color";
            if (single && value.Length <= 64 && value.Any(char.IsDigit) && (Matches(value, @"^[+-]?[$£€¥]?[0-9][0-9,._]*%?$|^[0-9][0-9,._]*[$£€¥%]?$|^[A-Za-z0-9]+([-_][A-Za-z0-9]+)*$"))) return "value";
        }
        catch (RegexMatchTimeoutException) { }
        return null;
    }
    internal static string? Lifecycle(HistoryItem item, DateTimeOffset now)
    {
        if (item.Pinned || item.UseCount >= 3) return "sticky";
        TimeSpan age = now - item.Captured;
        if (item.UseCount == 0 && age.TotalDays > 14) return "throwaway";
        if (item.UseCount == 0 && age.TotalHours < 1) return "fresh";
        return null;
    }
}
