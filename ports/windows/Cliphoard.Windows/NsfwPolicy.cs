namespace Cliphoard.Windows;

internal static class NsfwPolicy
{
    internal static readonly string[] Positive = {
        "sexually explicit pornography", "explicit nude sexual content", "people having sexual intercourse",
        "naked adults performing sexual acts", "a closeup of naked adult genitals", "graphic sexual activity",
        "sexual activity and explicit sexual sounds"
    };
    internal static readonly string[] Negative = {
        "ordinary work document or screenshot", "people in everyday clothing", "landscape animals or objects",
        "medical anatomy or health education", "music conversation or ordinary environmental sounds",
        "medical examination and cancer screening", "classical nude art and figure drawing",
        "people at the beach wearing swimsuits", "a romantic wedding kiss",
        "programming source code and software documentation", "sexual health education, contraception and reproductive biology"
    };
    internal static bool Exempt(HistoryItem item) => item.Tags.Any(tag => tag.Equals("nsfw-exempt", StringComparison.OrdinalIgnoreCase));
    internal static bool Labelled(HistoryItem item) => !Exempt(item) && new[] { item.Text, item.OcrText ?? "", item.DocumentText ?? "", item.Transcript ?? "", item.MediaText }.Concat(item.Tags).Any(ContentDetectors.HasNsfwLabel);
    internal static bool PossibleMatch(float[] vector, IReadOnlyList<float[]> positive, IReadOnlyList<float[]> negative)
    {
        bool Valid(float[] value) => value.Length == vector.Length && value.Length > 0 && value.All(float.IsFinite) && value.Any(number => number != 0);
        if (!Valid(vector) || positive.Count == 0 || negative.Count == 0 || !positive.Concat(negative).All(Valid)) return false;
        double yes = positive.Max(value => Cosine(vector, value));
        double no = negative.Max(value => Cosine(vector, value));
        return yes >= .20 && yes - no >= .06;
    }
    internal static bool RequiresAuthentication(HistoryItem item, bool active)
    {
        return ContentSafety.RequiresAuthentication(item, false) || active && !Exempt(item) && ((item.Flags & 128) != 0 || Labelled(item));
    }
    private static double Cosine(float[] first, float[] second)
    {
        double dot = 0, a = 0, b = 0;
        for (int index = 0; index < first.Length; ++index) { dot += (double)first[index] * second[index]; a += (double)first[index] * first[index]; b += (double)second[index] * second[index]; }
        return dot / Math.Sqrt(a * b);
    }
}
