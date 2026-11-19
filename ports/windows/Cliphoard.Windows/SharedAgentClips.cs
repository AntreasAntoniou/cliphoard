using System.Text;
namespace Cliphoard.Windows;
internal sealed record SharedAgentClip(string Id, string Kind, string Text);
internal static class SharedAgentClips
{
    internal static SharedAgentClip[] Select(HistoryState state)
    {
        var result = new List<SharedAgentClip>(); long bytes = 0;
        foreach (HistoryItem item in state.Items)
        {
            if (!item.Tags.Contains("agent-share", StringComparer.Ordinal) || item.Kind is not ("Text" or "Code" or "Link" or "Color") || item.Flags != 0 || item.RichText is not null || item.Html is not null || item.PayloadLength != 0 || string.IsNullOrEmpty(item.Text)) continue;
            string[] fields = new[] { item.Text, item.Source, item.OcrText ?? "", item.Transcript ?? "", item.DocumentText ?? "", item.MediaText }.Concat(item.Tags).ToArray();
            if (fields.Any(field => field.StartsWith("enc1:", StringComparison.Ordinal) || Encoding.UTF8.GetByteCount(field) > 65536 || ContentSafety.Flags(field, item.Source) != 0) || NsfwPolicy.Labelled(item)) continue;
            bytes += Encoding.UTF8.GetByteCount(item.Text);
            if (bytes > 16 * 1024 * 1024 || result.Count >= 4096) throw new IOException("Shared export exceeds its bound.");
            result.Add(new(Guid.Parse(item.Id).ToString("D"), item.Kind is "Text" or "Code" ? "text" : item.Kind.ToLowerInvariant(), item.Text));
        }
        return result.ToArray();
    }
}
