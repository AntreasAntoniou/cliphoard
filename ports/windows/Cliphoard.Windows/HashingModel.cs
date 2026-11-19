using System.Globalization;
using System.Text;
namespace Cliphoard.Windows;

internal static class HashingModel
{
    internal static ulong Fnv1a(string value)
    {
        ulong hash = 0xcbf29ce484222325;
        foreach (byte item in Encoding.UTF8.GetBytes(value)) hash = unchecked((hash ^ item) * 0x100000001b3);
        return hash;
    }
    internal static float[] Embed(string text)
    {
        string lower = text.ToLowerInvariant();
        int[] starts = StringInfo.ParseCombiningCharacters(lower).Append(lower.Length).ToArray();
        var vector = new float[256];
        var word = new StringBuilder();
        void AddWord() { if (word.Length > 0) { ++vector[(int)(Fnv1a(word.ToString()) % 256)]; word.Clear(); } }
        for (int index = 0; index < starts.Length - 1; ++index)
        {
            string element = lower[starts[index]..starts[index + 1]];
            if (Rune.IsLetterOrDigit(Rune.GetRuneAt(element, 0))) word.Append(element);
            else AddWord();
            if (index >= 2) ++vector[(int)(Fnv1a(lower[starts[index - 2]..starts[index + 1]]) % 256)];
        }
        AddWord();
        float squared = 0;
        foreach (float value in vector) squared += value * value;
        float norm = MathF.Sqrt(squared);
        return norm > 0 ? vector.Select(value => value / norm).ToArray() : vector;
    }
}
