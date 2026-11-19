#if DEBUG
using System.Text.Json;
namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    partial void RecordSyntheticSessionFailure(Exception error)
    {
        const string profile = @"C:\CliphoardDev\qualification\interactive-profile";
        if (!store.DirectoryPath.Equals(profile, StringComparison.OrdinalIgnoreCase)) return;
        try
        {
            if (File.ReadAllText(Path.Combine(profile, ".synthetic-only")) != "CLIPHOARD_SYNTHETIC_V1") return;
            string path = Path.Combine(profile, "session-failures.jsonl"); VerifiedModelAssets.CheckPath(path);
            if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024) return;
            File.AppendAllText(path, JsonSerializer.Serialize(new { type = error.GetType().FullName, code = error.HResult, stack = error.StackTrace, at = DateTimeOffset.UtcNow }) + "\n");
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException) { }
    }
    partial void RecordSyntheticPaste(bool copied, bool restored, bool ready, bool current, bool written, long requested, long actual)
    {
        const string profile = @"C:\CliphoardDev\qualification\interactive-profile";
        if (!store.DirectoryPath.Equals(profile, StringComparison.OrdinalIgnoreCase)) return;
        try
        {
            if (File.ReadAllText(Path.Combine(profile, ".synthetic-only")) != "CLIPHOARD_SYNTHETIC_V1") return;
            string path = Path.Combine(profile, "paste-events.jsonl"); VerifiedModelAssets.CheckPath(path);
            if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024) return;
            File.AppendAllText(path, JsonSerializer.Serialize(new { copied, restored, ready, current, written, requested, actual, at = DateTimeOffset.UtcNow }) + "\n");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
    partial void RecordSyntheticSession(uint reason, uint session)
    {
        const string profile = @"C:\CliphoardDev\qualification\interactive-profile";
        if (!store.DirectoryPath.Equals(profile, StringComparison.OrdinalIgnoreCase)) return;
        try
        {
            string marker = Path.Combine(profile, ".synthetic-only");
            if (File.ReadAllText(marker) != "CLIPHOARD_SYNTHETIC_V1") return;
            string path = Path.Combine(profile, "session-events.jsonl"); VerifiedModelAssets.CheckPath(path);
            if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024) return;
            File.AppendAllText(path, JsonSerializer.Serialize(new { reason, session, locked, items = store.State.Items.Count, shown = shown.Count, reference = referenceImage is not null, grants = revealed.Count, agent_connected = agents.Connected, target = target is not null, query_characters = searchInput.Submitted.Length, media_matches = audioMatches.Count + videoMatches.Count + combinedImages.Count, media_worker_ready = semantic.MediaReady, unsaved = store.UnsavedChanges, writable = store.Writable, at = DateTimeOffset.UtcNow }) + "\n");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
#endif
