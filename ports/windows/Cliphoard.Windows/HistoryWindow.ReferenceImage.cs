using Windows.Storage.Pickers;
namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    private HistoryItem? referenceImage;
    private bool perceptualReference;
    private void ClearReferenceImage() { if (referenceImage?.Payload is byte[] bytes) Array.Clear(bytes); referenceImage = null; perceptualReference = false; }
    private void StartReferenceImage(HistoryItem item, bool perceptual)
    {
        if (locked || closing || item.AnalysisVetoed || item.Kind != "Image") return;
        ClearReferenceImage();
        referenceImage = new() { Id = item.Id, Kind = "Image", Format = item.Format, Payload = item.Payload?.ToArray(), Text = item.Text };
        perceptualReference = perceptual;
        store.State.SearchMode = "image"; store.Save(); searchInput.Reset(""); search.Text = ""; rankedKey = "";
        BuildChrome();
        if (!perceptual && !ReadyForImages) _ = PrepareImagesAsync(false);
        PresentPanel(false, false); Notice(perceptual ? "Visually similar images" : "Searching from your reference image");
    }
    private async void ChooseReferenceImage()
    {
        if (locked || closing || handingOff) return;
        bool suspended = captureSuspended; handingOff = true; captureSuspended = true; ++epoch;
        long generation = analysisGeneration;
        CancellationToken cancellation = analysisLifetime.Token;
        byte[]? bytes = null;
        try
        {
            var picker = new FileOpenPicker();
            foreach (string extension in new[] { ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff", ".webp", ".heic", ".heif" }) picker.FileTypeFilter.Add(extension);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
            var file = await picker.PickSingleFileAsync();
            if (file is null || locked || closing || generation != analysisGeneration) return;
            string path = file.Path;
            if (!Path.IsPathFullyQualified(path) || path.Length < 3 || path[1] != ':' || new DriveInfo(Path.GetPathRoot(path)!).DriveType == DriveType.Network) throw new IOException();
            using (var input = LocalFileLease.Open(path, ClipboardContent.MediaLimit))
            {
                if (input.Length > ClipboardContent.MediaLimit) throw new IOException();
                bytes = new byte[(int)input.Length]; await input.ReadExactlyAsync(bytes, cancellation);
            }
            if (ContentSafety.Flags(Path.GetFileName(path)) != 0 || ContentDetectors.HasNsfwLabel(path)) throw new IOException();
            byte[] normalized = await ImageAnalysis.NormalizeReferenceAsync(bytes, cancellation);
            Array.Clear(bytes); bytes = normalized;
            if (locked || closing || generation != analysisGeneration || cancellation.IsCancellationRequested) return;
            StartReferenceImage(new() { Kind = "Image", Format = 0, Payload = bytes, Text = "Reference image" }, false);
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing) Notice("Choose a locally supported image up to 8 MB and 16 megapixels."); }
        finally { if (bytes is not null) Array.Clear(bytes); handingOff = false; captureSuspended = suspended; clipboard?.Baseline(); }
    }
}
