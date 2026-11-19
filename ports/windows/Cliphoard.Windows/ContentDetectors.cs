using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Cliphoard.Windows;

internal static class ContentDetectors
{
    internal const long Secret = 1, EntropySecret = 2, Financial = 4, Contact = 8, SensitiveIdentity = 16, OneTimeCode = 32, Quarantined = 64, Nsfw = 128;
    private static readonly TimeSpan Budget = TimeSpan.FromMilliseconds(100);
    private static Regex Pattern(string pattern) => new(pattern, RegexOptions.CultureInvariant, Budget);
    private static readonly Regex Tokens = Pattern(@"[^\x09-\x0D ]+");
    private static readonly Regex GroupedDigits = Pattern(@"[0-9]+(?:[ .()\-]{1,2}[0-9]+)*");
    private static readonly Regex Digits = Pattern(@"[0-9]+");
    private static readonly Regex Email = Pattern(@"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$");
    private static readonly Regex NationalId = Pattern(@"(?<![A-Za-z0-9])(?:[0-9]{3}[ -][0-9]{2}[ -][0-9]{4}|[0-9]{3}[ -][0-9]{3}[ -][0-9]{3}|[A-Z]{2}[0-9]{6}[A-D])(?![A-Za-z0-9])");
    private static readonly Regex OtpWord = Pattern(@"(?i)(?<![A-Za-z0-9])(?:code|verification|one-time|one time|otp|passcode|2fa)(?![A-Za-z0-9])");
    private static readonly Regex Url = Pattern(@"https?://[^\s<>""']+");
    private static readonly Regex MagicWord = Pattern(@"(?i)login|verify|magic|confirm|signin|sign-in|auth");
    private static readonly Regex ExplicitNsfw = Pattern(@"(?i)(?:^|[^\p{L}\p{N}])(?:nsfw|porn|pornography|xxx|sexually[ _-]+explicit)(?:$|[^\p{L}\p{N}])");
    private static readonly HashSet<string> SensitiveSources = new(StringComparer.OrdinalIgnoreCase)
    {
        "1password", "1password 7", "1password 8", "bitwarden", "keepassxc", "keepass", "dashlane", "lastpass", "passwords", "keychain access", "secretive", "enpass", "strongbox",
        "com.agilebits.onepassword", "com.agilebits.onepassword4", "com.agilebits.onepassword7", "com.1password.1password", "com.1password.browser-support", "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.apple.Passwords", "com.apple.PasswordManager", "com.apple.keychainaccess"
    };
    private static readonly HashSet<string> StreetSuffixes = new(StringComparer.OrdinalIgnoreCase)
    {
        "street", "st", "road", "rd", "avenue", "ave", "lane", "ln", "drive", "dr", "boulevard", "blvd", "way", "close", "court", "ct", "place", "pl", "terrace", "crescent", "square", "sq", "highway", "hwy", "parkway", "pkwy"
    };
    private static readonly HashSet<string> PhoneGroups = new()
    {
        "3,3,4", "3,4,4", "4,3,3", "4,3,4", "2,4,4", "3,4", "5,6", "4,6", "4,7", "2,3,3,4", "3,3,3,3"
    };
    private static readonly Regex Filename = Pattern(@"\.[A-Za-z]{1,5}$");
    private static readonly Regex HouseNumber = Pattern(@"^[0-9]{1,5}[A-Za-z]?$");
    private static readonly Regex Postcode = Pattern(@"^(?:[0-9]{5}(?:-[0-9]{4})?|[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2})$");
    private static readonly Regex Outward = Pattern(@"^[A-Z]{1,2}[0-9][A-Z0-9]?$");
    private static readonly Regex Inward = Pattern(@"^[0-9][A-Z]{2}$");

    internal static long Scan(string text, string? source = null)
    {
        long flags = SensitiveSource(source) ? Quarantined : 0;
        if (text.Length == 0) return flags;
        try
        {
            Match[] tokens = Tokens.Matches(text).Cast<Match>().ToArray();
            var claimed = new bool[text.Length];
            foreach (Match token in tokens)
            {
                long credentials = ContentSafety.CredentialFlags(token.Value);
                if (credentials != 0) flags |= credentials;
                else if (HighEntropy(token.Value) || tokens.Length == 1 && GeneratedPassword(token.Value)) flags |= EntropySecret;
            }
            if (text.Contains("-----begin", StringComparison.OrdinalIgnoreCase) && text.Contains("private key-----", StringComparison.OrdinalIgnoreCase)) flags |= Secret;
            foreach (Match run in GroupedDigits.Matches(text))
            {
                int[] digits = DigitValues(run.Value);
                if (CardBrand(digits) && Luhn(digits)) { flags |= Financial; Claim(claimed, run.Index, run.Length); }
            }
            foreach (Match run in Digits.Matches(text))
            {
                int[] digits = DigitValues(run.Value);
                if (digits.Length == 9 && digits.Select((digit, index) => digit * new[] { 3, 7, 1 }[index % 3]).Sum() % 10 == 0)
                { flags |= Financial; Claim(claimed, run.Index, run.Length); }
                if (digits.Length is >= 4 and <= 8 && Boundary(text, run.Index - 1) && Boundary(text, run.Index + run.Length))
                {
                    int start = Math.Max(0, run.Index - 48), end = Math.Min(text.Length, run.Index + run.Length + 48);
                    if (OtpWord.IsMatch(text[start..end])) flags |= OneTimeCode;
                }
            }
            int cryptoBudget = 64;
            for (int index = 0; index < tokens.Length; ++index)
            {
                string token = tokens[index].Value;
                if (token.Length >= 4 && char.IsAsciiLetterUpper(token[0]) && char.IsAsciiLetterUpper(token[1]) && char.IsAsciiDigit(token[2]) && char.IsAsciiDigit(token[3]) && token.All(char.IsAsciiLetterOrDigit))
                {
                    int last = index;
                    var candidate = new StringBuilder(token);
                    while (candidate.Length < 15 && last + 1 < tokens.Length && last - index < 8 && tokens[last + 1].Value.All(char.IsAsciiLetterOrDigit)) candidate.Append(tokens[++last].Value);
                    if (token.Length < 15)
                        while (candidate.Length < 34 && last + 1 < tokens.Length && last - index < 8 && tokens[last + 1].Value.All(char.IsAsciiLetterOrDigit)) candidate.Append(tokens[++last].Value);
                    if (Iban(candidate.ToString())) { flags |= Financial; Claim(claimed, tokens[index].Index, tokens[last].Index + tokens[last].Length - tokens[index].Index); }
                }
                if (cryptoBudget > 0 && token.Length is >= 26 and <= 42 && (token[0] is '1' or '3' || token.StartsWith("bc1", StringComparison.OrdinalIgnoreCase) || token.StartsWith("0x", StringComparison.OrdinalIgnoreCase)))
                {
                    --cryptoBudget;
                    if (Bitcoin(token) || Ethereum(token)) { flags |= Financial; Claim(claimed, tokens[index].Index, tokens[index].Length); }
                }
                string trimmed = Trim(token);
                if (trimmed.Length >= 6 && Email.IsMatch(trimmed)) flags |= Contact;
            }
            foreach (Match run in GroupedDigits.Matches(text))
            {
                if (Enumerable.Range(run.Index, run.Length).Any(index => claimed[index])) continue;
                Match[] groups = Digits.Matches(run.Value).Cast<Match>().ToArray();
                int total = groups.Sum(group => group.Length);
                if (run.Index > 0 && text[run.Index - 1] == '+' && total is >= 8 and <= 15
                    || total is >= 9 and <= 13 && PhoneGroups.Contains(string.Join(',', groups.Select(group => group.Length)))
                    || groups.Length == 1 && total == 11 && run.Value[0] == '0') flags |= Contact;
            }
            if (NationalIdentity(text) || Postal(tokens.Select(token => Trim(token.Value)).ToArray())) flags |= SensitiveIdentity;
            foreach (Match url in Url.Matches(text))
                if (MagicWord.IsMatch(url.Value) && url.Value.Split(new[] { '=', '?', '&', '/' }).Any(value => value.Length >= 16 && value.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_') && value.Any(char.IsAsciiLetter) && value.Any(char.IsAsciiDigit) && Entropy(value) >= 3)) flags |= OneTimeCode;
            return flags;
        }
        catch (RegexMatchTimeoutException) { return flags | EntropySecret; }
    }

    internal static bool SensitiveSource(string? source)
    {
        string normalized = string.Concat((source ?? "").Where(character => character is not (>= '\u200b' and <= '\u200f') && character != '\ufeff')).Trim();
        if (normalized.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) normalized = normalized[..^4];
        return SensitiveSources.Contains(normalized);
    }
    internal static bool HasNsfwLabel(string text)
    {
        try { return ExplicitNsfw.IsMatch(Uri.UnescapeDataString(text)); }
        catch (Exception error) when (error is UriFormatException or RegexMatchTimeoutException) { return true; }
    }
    private static string Trim(string value) => value.TrimStart('(', '<', '"', '\'').TrimEnd(',', '.', ';', ':', '!', '?', ')', '>', '"', '\'');
    private static bool Boundary(string text, int index) => index < 0 || index >= text.Length || !char.IsAsciiLetterOrDigit(text[index]);
    private static int[] DigitValues(string value) => value.Where(char.IsAsciiDigit).Select(character => character - '0').ToArray();
    private static void Claim(bool[] claimed, int start, int count) => Array.Fill(claimed, true, start, count);
    internal static bool Luhn(int[] digits)
    {
        int sum = 0;
        bool twice = false;
        for (int index = digits.Length - 1; index >= 0; --index)
        {
            int digit = digits[index];
            if (twice) { digit *= 2; if (digit > 9) digit -= 9; }
            sum += digit; twice = !twice;
        }
        return digits.Length >= 2 && sum % 10 == 0;
    }
    private static bool CardBrand(int[] digits)
    {
        int Prefix(int length) => digits.Take(length).Aggregate(0, (sum, digit) => sum * 10 + digit);
        return digits.Length is 13 or 16 or 19 && Prefix(1) == 4
            || digits.Length == 16 && (Prefix(2) is >= 51 and <= 55 || Prefix(4) is >= 2221 and <= 2720)
            || digits.Length == 15 && Prefix(2) is 34 or 37
            || digits.Length is >= 16 and <= 19 && (Prefix(4) == 6011 || Prefix(2) == 65);
    }
    internal static bool Iban(string value)
    {
        if (value.Length is < 15 or > 34 || !char.IsAsciiLetterUpper(value[0]) || !char.IsAsciiLetterUpper(value[1]) || !char.IsAsciiDigit(value[2]) || !char.IsAsciiDigit(value[3])) return false;
        int remainder = 0;
        foreach (char character in value[4..] + value[..4])
        {
            if (char.IsAsciiDigit(character)) remainder = (remainder * 10 + character - '0') % 97;
            else if (char.IsAsciiLetterUpper(character)) remainder = (remainder * 100 + character - 'A' + 10) % 97;
            else return false;
        }
        return remainder == 1;
    }
    private static bool NationalIdentity(string text)
    {
        foreach (Match match in NationalId.Matches(text))
        {
            string value = match.Value;
            int[] digits = DigitValues(value);
            if (value.Length == 11 && char.IsAsciiDigit(value[0]))
            {
                if (value[3] is ' ' or '-' && value[7] is ' ' or '-' && digits.Length == 9 && digits[0] != 0 && Luhn(digits)) return true;
                if (value[3] is ' ' or '-' && value[6] is ' ' or '-')
                {
                    int area = digits[0] * 100 + digits[1] * 10 + digits[2];
                    if (area is > 0 and < 900 && area != 666 && (digits[3] != 0 || digits[4] != 0) && digits.Skip(5).Any(digit => digit != 0)) return true;
                }
            }
            if (value.Length == 9 && char.IsAsciiLetterUpper(value[0]) && !"DFIQUV".Contains(value[0]) && !"DFIQUVO".Contains(value[1]) && !new[] { "BG", "GB", "NK", "KN", "TN", "NT", "ZZ" }.Contains(value[..2])) return true;
        }
        return false;
    }
    private static bool Postal(string[] tokens)
    {
        bool house = tokens.Take(Math.Max(0, tokens.Length - 1)).Any(value => value.Length <= 5 && HouseNumber.IsMatch(value));
        if (!house || !tokens.Any(StreetSuffixes.Contains)) return false;
        for (int index = 0; index < tokens.Length; ++index)
            if (Postcode.IsMatch(tokens[index]) || index + 1 < tokens.Length && Outward.IsMatch(tokens[index]) && Inward.IsMatch(tokens[index + 1])) return true;
        return false;
    }
    private static bool PathShaped(string value) => value.Length > 0 && (value[0] is '/' or '~' or '.' || value.Length >= 3 && value[1] == ':' && value[2] == '\\' || Filename.IsMatch(value));
    internal static double Entropy(string value)
    {
        if (value.Length == 0) return 0;
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        return bytes.GroupBy(value => value).Sum(group => { double probability = group.Count() / (double)bytes.Length; return -probability * Math.Log2(probability); });
    }
    private static bool HighEntropy(string value)
    {
        if (value.Length < 24 || PathShaped(value) || value.Contains("://") || value.Contains('@') || Guid.TryParseExact(value, "D", out _) || value.All(Uri.IsHexDigit)
            || !value.All(character => char.IsAsciiLetterOrDigit(character) || "-_/+=.@".Contains(character)) || !value.Any(char.IsAsciiDigit)) return false;
        int classes = new[] { value.Any(char.IsAsciiLetterLower), value.Any(char.IsAsciiLetterUpper), value.Any(char.IsAsciiDigit), value.Any(character => !char.IsAsciiLetterOrDigit(character)) }.Count(present => present);
        return classes >= 2 && Entropy(value) >= 3.5 && !PrintableBase64(value);
    }
    private static bool GeneratedPassword(string value)
    {
        if (value.Length is < 16 or > 128 || PathShaped(value) || value.Contains("://") || value.Any(character => character is < '!' or > '~')) return false;
        int consecutiveLetters = 0;
        foreach (char character in value)
        {
            consecutiveLetters = char.IsAsciiLetter(character) ? consecutiveLetters + 1 : 0;
            if (consecutiveLetters > 5) return false;
        }
        return value.Any(char.IsAsciiLetterUpper) && value.Any(char.IsAsciiLetterLower) && value.Any(char.IsAsciiDigit)
            && value.Where(character => !char.IsAsciiLetterOrDigit(character)).Distinct().Count() >= 2 && Entropy(value) >= 3.5;
    }
    private static bool PrintableBase64(string value)
    {
        string normalized = value.Replace('-', '+').Replace('_', '/');
        if (normalized.Length % 4 == 1) return false;
        normalized = normalized.PadRight((normalized.Length + 3) / 4 * 4, '=');
        try
        {
            byte[] bytes = Convert.FromBase64String(normalized);
            return bytes.Length >= 12 && bytes.Count(value => value is >= 0x20 and <= 0x7e or 9 or 10 or 13) / (double)bytes.Length >= .95;
        }
        catch (FormatException) { return false; }
    }
    private static bool Bitcoin(string value)
    {
        if (value.StartsWith("bc1", StringComparison.OrdinalIgnoreCase))
        {
            if (value.Any(char.IsAsciiLetterUpper) && value.Any(char.IsAsciiLetterLower) || value.Length is < 14 or > 90) return false;
            string lower = value.ToLowerInvariant();
            int separator = lower.LastIndexOf('1');
            if (separator < 1 || lower.Length - separator - 1 < 6) return false;
            const string alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
            var codes = lower[..separator].Select(character => character >> 5).Concat(new[] { 0 }).Concat(lower[..separator].Select(character => character & 31)).ToList();
            foreach (char character in lower[(separator + 1)..]) { int index = alphabet.IndexOf(character); if (index < 0) return false; codes.Add(index); }
            int checksum = 1;
            int[] generator = { 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 };
            foreach (int code in codes)
            {
                int top = checksum >> 25;
                checksum = ((checksum & 0x1ffffff) << 5) ^ code;
                for (int bit = 0; bit < 5; ++bit) if (((top >> bit) & 1) != 0) checksum ^= generator[bit];
            }
            return checksum is 1 or 0x2bc830a3;
        }
        if (value.Length is < 26 or > 35) return false;
        const string base58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        BigInteger number = 0;
        foreach (char character in value) { int digit = base58.IndexOf(character); if (digit < 0) return false; number = number * 58 + digit; }
        byte[] decoded = Enumerable.Repeat((byte)0, value.TakeWhile(character => character == '1').Count()).Concat(number.ToByteArray(isUnsigned: true, isBigEndian: true)).ToArray();
        if (decoded.Length != 25 || decoded[0] is not (0 or 5)) return false;
        return SHA256.HashData(SHA256.HashData(decoded.AsSpan(0, 21))).AsSpan(0, 4).SequenceEqual(decoded.AsSpan(21, 4));
    }
    private static bool Ethereum(string value)
    {
        if (value.Length != 42 || !value.StartsWith("0x", StringComparison.OrdinalIgnoreCase) || !value[2..].All(Uri.IsHexDigit)) return false;
        string body = value[2..];
        if (!body.Any(char.IsAsciiLetterLower) || !body.Any(char.IsAsciiLetterUpper)) return true;
        byte[] digest = Keccak256.Hash(Encoding.ASCII.GetBytes(body.ToLowerInvariant()));
        for (int index = 0; index < body.Length; ++index)
        {
            if (!char.IsAsciiLetter(body[index])) continue;
            int nibble = index % 2 == 0 ? digest[index / 2] >> 4 : digest[index / 2] & 15;
            if (char.IsAsciiLetterUpper(body[index]) != (nibble >= 8)) return false;
        }
        return true;
    }
}
