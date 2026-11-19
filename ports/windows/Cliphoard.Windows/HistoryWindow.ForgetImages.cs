namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    private async Task ForgetImageUnderstandingAsync()
    {
        if (locked || closing || !store.Writable) return;
        InvalidateAnalysis(); ClearReferenceImage();
        await semantic.ClearAsync(); await ClearImagesAsync();
        if (locked || closing) return;
        try
        {
            bool complete = true;
            try { store.ForgetImageUnderstanding(); }
            catch { complete = false; }
            var keep = store.State.Items.Where(item => item.Kind != "Image").Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
            await Task.Run(() => indexes.Retain(keep));
            if (!locked && !closing)
            {
                Notice(complete ? "Recognized text and derived image indexes were forgotten. New images still follow your OCR setting." : "Cached image indexes were removed. Stored text cleanup could not finish; check history storage and retry."); Refresh();
            }
        }
        catch { if (!locked && !closing) Notice("Image understanding could not be fully forgotten. Check history storage and retry."); }
    }
}
