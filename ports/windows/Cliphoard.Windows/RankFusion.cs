namespace Cliphoard.Windows;
internal static class RankFusion
{
    internal static Dictionary<string, double> Scores(IEnumerable<IEnumerable<string>> lanes)
    {
        var scores = new Dictionary<string, double>(StringComparer.Ordinal);
        foreach (IEnumerable<string> lane in lanes)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal); int rank = 0;
            foreach (string id in lane)
            {
                if (seen.Add(id)) scores[id] = scores.GetValueOrDefault(id) + 1.0 / (60 + rank + 1);
                ++rank;
            }
        }
        return scores;
    }
    internal static string[] Order(IEnumerable<IEnumerable<string>> lanes) => Scores(lanes).OrderByDescending(pair => pair.Value).ThenBy(pair => Guid.Parse(pair.Key)).Select(pair => pair.Key).ToArray();
}
