using System.Net.Mail;
using System.Text.RegularExpressions;
namespace Cliphoard.Windows;
internal static class ContentClassifier
{
    internal static bool IsColor(string text)
    {
        string value = text.Trim(); string digits = value.TrimStart('#');
        return digits.All(Uri.IsHexDigit) && (value.StartsWith('#') ? digits.Length is 3 or 6 or 8 : digits.Length is 6 or 8 && digits.Any(char.IsAsciiDigit));
    }
    internal static string Classify(string text)
    {
        string value = text.Trim();
        if (IsColor(value)) return "Color";
        if (value.Length is > 0 and < 2048)
        {
            if (value.StartsWith("mailto:", StringComparison.OrdinalIgnoreCase)) return "Link";
            string candidate = value.TrimEnd('.', ',', ')');
            if (!candidate.Any(char.IsWhiteSpace))
            {
                if (Uri.TryCreate(candidate, UriKind.Absolute, out Uri? uri) && uri.Scheme is "http" or "https" or "ftp" && uri.Host.Length != 0) return "Link";
                if (MailAddress.TryCreate(candidate, out MailAddress? email) && email.Address == candidate && candidate.Contains('@') && email.Host.Contains('.')) return "Link";
                if (Regex.IsMatch(candidate, @"^(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?\.)+[\p{L}]{2,63}(?::[0-9]{1,5})?(?:[/\?#][^\s]*)?$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100))) return "Link";
            }
        }
        return text.Contains('\n') && (text.Contains('{') || text.Contains("import ") || text.Contains("def ")) ? "Code" : "Text";
    }
}
