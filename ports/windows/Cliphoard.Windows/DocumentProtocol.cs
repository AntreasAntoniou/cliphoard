namespace Cliphoard.Windows;
internal sealed record DocumentRequest(string Format, byte[] Bytes, bool Pdf = true, bool RichText = true);
internal sealed record DocumentResponse(bool Success, string Text = "", bool Truncated = false);
internal static class DocumentProtocol
{
    internal const int MaximumFrame = 24 * 1024 * 1024;
}
