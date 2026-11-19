using System.Text;
using System.Text.RegularExpressions;
using System.Net;
namespace Cliphoard.Windows;

internal static class ClipboardContent
{
    internal const int MediaLimit = 8 * 1024 * 1024;
    internal static bool IsPng(byte[] bytes)
    {
        if (bytes.Length < 33 || bytes.Length > MediaLimit || !bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137,80,78,71,13,10,26,10 }) || !bytes.AsSpan(12,4).SequenceEqual("IHDR"u8)) return false;
        uint width = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(16,4)), height = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(20,4));
        return width is > 0 and <= 8192 && height is > 0 and <= 8192 && (ulong)width * height <= 16_777_216;
    }
    internal static string? HtmlText(byte[] bytes)
    {
        if (bytes.Length > 512 * 1024) return null;
        string header = Encoding.ASCII.GetString(bytes, 0, Math.Min(bytes.Length, 4096));
        int Offset(string name)
        {
            var match = Regex.Match(header, @"(?:^|\r?\n)" + name + @":\s*(\d+)", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50));
            return match.Success && int.TryParse(match.Groups[1].Value, out int value) ? value : -1;
        }
        int start = Offset("StartFragment"), end = Offset("EndFragment");
        if (start < 0 || end <= start || end > bytes.Length) return null;
        string html = new UTF8Encoding(false, true).GetString(bytes, start, end-start);
        html = Regex.Replace(html, @"<(script|style)\b[^>]*>.*?</\1\s*>", "", RegexOptions.IgnoreCase | RegexOptions.Singleline, TimeSpan.FromMilliseconds(100));
        html = Regex.Replace(html, @"<(br\s*/?|/p|/div|/li|/tr)\s*>", "\n", RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(100));
        html = Regex.Replace(html, "<[^>]*>", "", RegexOptions.None, TimeSpan.FromMilliseconds(100));
        string text = WebUtility.HtmlDecode(html).Trim(); return text.Length is > 0 and <= 65536 ? text : null;
    }
    internal static string? DropText(byte[] bytes)
    {
        if (bytes.Length < 24 || bytes.Length > MediaLimit || BitConverter.ToUInt32(bytes, 16) != 1) return null;
        uint offset = BitConverter.ToUInt32(bytes); if (offset < 20 || offset > bytes.Length - 4 || offset % 2 != 0 || (bytes.Length - offset) % 2 != 0) return null;
        string raw = new UnicodeEncoding(false, false, true).GetString(bytes, (int)offset, bytes.Length - (int)offset);
        int end = raw.IndexOf("\0\0", StringComparison.Ordinal); if (end < 1) return null;
        string[] paths = raw[..end].Split('\0'); if (paths.Length > 32 || paths.Any(string.IsNullOrWhiteSpace) || raw[..end].Length > 65536) return null;
        return string.Join("\n", paths);
    }
    internal static List<string> Tags(string input) => input.Split(new[] { ',', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(t => t.TrimStart('#')).Where(t => t.Length is > 0 and <= 40).Distinct(StringComparer.OrdinalIgnoreCase).Take(20).ToList();
    internal static bool Excluded(string source, IEnumerable<string> exclusions) => exclusions.Concat(new[] { "1Password", "KeePass", "KeePassXC", "Bitwarden", "LastPass", "Dashlane", "NordPass" }).Any(name => string.Equals(Path.GetFileNameWithoutExtension(name.Trim()), Path.GetFileNameWithoutExtension(source), StringComparison.OrdinalIgnoreCase));
}
