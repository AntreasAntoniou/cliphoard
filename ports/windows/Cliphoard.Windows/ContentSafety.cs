using System.Text.RegularExpressions;
using System.Security.Cryptography;
using System.Text;
namespace Cliphoard.Windows;

internal static class ContentSafety
{
    internal static bool RequiresAuthentication(HistoryItem item, bool includeNsfw = true) => ((item.Flags | ItemFlags(item)) & ~(includeNsfw ? 8L : 136L)) != 0;
    internal static long ItemFlags(HistoryItem item) => Flags(item.Text + "\n" + item.Source + "\n" + item.OcrText + "\n" + item.Transcript + "\n" + item.DocumentText + "\n" + item.MediaText + "\n" + string.Join('\n', item.Tags), item.Source) | AlternateFlags(item);
    internal sealed record RepresentationSafety(string Fingerprint, long Flags);
    internal static long AlternateFlags(HistoryItem item)
    {
        byte[]? rich = item.RichText, html = item.Html;
        if (rich is not { Length: > 0 } && html is not { Length: > 0 }) return 0;
        if (rich?.Length > 512 * 1024 || html?.Length > 512 * 1024) return ContentDetectors.Quarantined;
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Span<byte> lengths = stackalloc byte[8];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(lengths, rich?.Length ?? -1);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(lengths[4..], html?.Length ?? -1);
        hash.AppendData(lengths);
        if (rich is not null) hash.AppendData(rich);
        if (html is not null) hash.AppendData(html);
        string fingerprint = Convert.ToHexString(hash.GetHashAndReset());
        if (item.RepresentationSafety is { } cached && cached.Fingerprint == fingerprint) return cached.Flags;
        long flags = 0;
        try
        {
            if (rich is { Length: > 0 }) flags |= Flags(RtfText.Read(rich, 512 * 1024 + 1, default, includeHidden: true));
            if (html is { Length: > 0 })
            {
                string visible = ClipboardContent.HtmlText(html) ?? throw new IOException("Unsupported HTML representation.");
                string source = System.Net.WebUtility.HtmlDecode(new UTF8Encoding(false, true).GetString(html));
                flags |= Flags(visible) | Flags(source);
            }
        }
        catch (Exception error) when (error is IOException or ArgumentException or RegexMatchTimeoutException)
        {
            flags |= ContentDetectors.Quarantined;
        }
        item.RepresentationSafety = new(fingerprint, flags);
        return flags;
    }
    // Stable high-confidence signatures from the Mac detector. Scan locally before indexing.
    private static readonly Regex Credentials = new(@"(?<![A-Za-z0-9_-])(?:AKIA[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|(?:sk_live_|rk_live_|rk_test_|sk_test_|whsec_)[A-Za-z0-9_]{16,}|AIza[A-Za-z0-9_-]{35,}|sk-[A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*)", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    internal static long Flags(string text, string? source = null) => CredentialFlags(text) | ContentDetectors.Scan(text, source);
    internal static long CredentialFlags(string text)
    {
        if (text.Contains("-----begin", StringComparison.OrdinalIgnoreCase) && text.Contains("private key-----", StringComparison.OrdinalIgnoreCase)) return 1;
        try { return Credentials.IsMatch(text) ? 1 : 0; }
        catch (RegexMatchTimeoutException) { return 2; }
    }
}
