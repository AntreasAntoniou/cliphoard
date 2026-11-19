using System.Text;
namespace Cliphoard.Windows;
internal sealed record ManagerPreview(HistoryItem[] Items, int Skipped, string[] Tables);
internal static class ManagerImportClient
{
    internal static async Task<ManagerPreview> PreviewAsync(string source, string path, CancellationToken cancellation)
    {
        using var lease = LocalFileLease.Open(path, 256 * 1024 * 1024);
        using FileStream? wal = source != "flycut" && File.Exists(path + "-wal") ? LocalFileLease.Open(path + "-wal", 256 * 1024 * 1024) : null;
        ManagerImportResponse response = await PrivateWorkerCall.SendAsync<ManagerImportRequest, ManagerImportResponse>("--manager-import-worker", new(source, path), 24 * 1024 * 1024, 60, 768u * 1024 * 1024, cancellation);
        if (!response.Success || response.Items.Length > 10000 || response.Skipped < 0 || response.Tables?.Length > 100) throw new IOException("Unsupported manager store.");
        var items = new List<HistoryItem>();
        foreach (ManagerImportItem value in response.Items)
        {
            cancellation.ThrowIfCancellationRequested();
            if (value.Text.Length > 65536 || value.Source.Length > 1024 || !double.IsFinite(value.Created) || value.Created < 0 || value.Created >= 253402300799 || value.Image?.Length > 8 * 1024 * 1024) throw new IOException("Invalid import preview.");
            var item = new HistoryItem { Text = value.Text, Source = value.Source.Length == 0 ? source : value.Source, Captured = DateTimeOffset.UnixEpoch.AddSeconds(value.Created), Kind = value.Kind switch { "image" => "Image", "file" => "Files", "link" => "Link", "color" => "Color", "text" => HistoryClipboard.Classify(value.Text), _ => throw new IOException("Unsupported import kind.") } };
            if (value.Image is byte[] image) { item.Payload = await ImageAnalysis.NormalizeImageAsync(image, cancellation); item.Format = 0; }
            else if (value.Kind == "file")
            {
                // Preserve imported Mac paths as recorded data. File verbs require a valid local Windows path.
                string pathText = Uri.TryCreate(value.Text, UriKind.Absolute, out Uri? uri) && uri.IsFile ? uri.LocalPath : value.Text;
                item.Text = pathText;
                byte[] paths = Encoding.Unicode.GetBytes(pathText + "\0\0"); byte[] drop = new byte[20 + paths.Length]; BitConverter.GetBytes(20).CopyTo(drop, 0); BitConverter.GetBytes(1).CopyTo(drop, 16); paths.CopyTo(drop, 20); item.Payload = drop; item.Format = 15;
            }
            item.Flags |= ContentSafety.Flags(item.Text, item.Source); items.Add(item);
        }
        return new(items.ToArray(), response.Skipped, response.Tables ?? Array.Empty<string>());
    }
}
