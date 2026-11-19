using System.Text.Json;
namespace Cliphoard.Windows;

// Explicit synthetic mode only; bounded metadata snapshot, never clipboard text.
internal static class FixtureAudit
{
    private static readonly List<object> events = new();
    internal static void Record(string operation, object metadata)
    {
        try
        {
            if (events.Count == 64) events.RemoveAt(0);
            events.Add(new { operation, utc = DateTime.UtcNow, metadata });
            File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "fixture-audit.json"), JsonSerializer.Serialize(events));
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
