namespace Cliphoard.Windows;

internal static class GemmaPictureRelevance
{
    internal static readonly string[] BackgroundQueries = { "an image", "a picture" };
    internal const double MinimumSpecificity = .035;

    internal static double? Score(float[] query, float[] image, IReadOnlyList<float[]> backgrounds)
    {
        if (backgrounds.Count == 0 || backgrounds.Prepend(query).Append(image).Any(vector =>
            vector.Length != 768 || vector.Any(value => !float.IsFinite(value)) || vector.All(value => value == 0))) return null;
        double specificity = SemanticEngine.Dot(query, image) - backgrounds.Max(vector => SemanticEngine.Dot(vector, image));
        return specificity >= MinimumSpecificity ? specificity : null;
    }
}
