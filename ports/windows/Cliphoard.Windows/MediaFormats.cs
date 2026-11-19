namespace Cliphoard.Windows;
internal static class MediaFormats
{
    internal static readonly string[] Extensions = { ".wav", ".mp3", ".m4a", ".aac", ".flac", ".wma", ".mp4", ".mov", ".m4v", ".avi", ".wmv", ".mkv", ".webm", ".ogg", ".opus" };
    internal static bool Supports(string path) => Extensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);
}
