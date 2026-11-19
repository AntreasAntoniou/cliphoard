using System.Security.Cryptography;
using System.Text;
namespace Cliphoard.Windows;
internal static class ArchivePassphrase
{
    internal static int Strength(string value)
    {
        int length = new System.Globalization.StringInfo(value).LengthInTextElements;
        if (length < 12) return 0;
        var runes = value.EnumerateRunes().ToArray();
        int classes = (runes.Any(System.Text.Rune.IsLower) ? 1 : 0) + (runes.Any(System.Text.Rune.IsUpper) ? 1 : 0) + (runes.Any(System.Text.Rune.IsNumber) ? 1 : 0) + (runes.Any(rune => !System.Text.Rune.IsLetter(rune) && !System.Text.Rune.IsNumber(rune)) ? 1 : 0);
        double bits = length * new[] { 2.0, 4.7, 5.7, 6.0, 6.5 }[classes];
        return bits < 60 ? 1 : bits < 80 ? 2 : bits < 110 ? 3 : 4;
    }
    internal static string StrengthLabel(int strength) => new[] { "too short", "weak", "fair", "good", "strong" }[Math.Clamp(strength, 0, 4)];
    internal static string Generate()
    {
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        byte[] bytes = RandomNumberGenerator.GetBytes(25);
        try { return string.Join('-', Enumerable.Range(0, 5).Select(group => new string(bytes.Skip(group * 5).Take(5).Select(value => alphabet[value & 31]).ToArray()))); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
}
