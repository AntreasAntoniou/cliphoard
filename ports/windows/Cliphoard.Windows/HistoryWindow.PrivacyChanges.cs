namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    private string? inspectedItemId;
    private void PrivacyClassificationChanged(HistoryItem item)
    {
        revealed.Clear();
        if (!item.AnalysisVetoed) return;
        if (referenceImage?.Id == item.Id) ClearReferenceImage();
        if (inspectedItemId == item.Id) auxiliary?.Close();
        InvalidateAnalysis(true); PruneIndexes();
        long generation = modelGeneration;
        _ = ClearAsync();
        async Task ClearAsync()
        {
            await Task.WhenAll(semantic.ClearAsync(), ClearImagesAsync(), ClearScreeningAsync());
            if (locked || closing || generation != modelGeneration) return;
            if (!ReadyForSearch) _ = PrepareSearchAsync(false);
            if (EffectiveModality is "images" or "all" && !ReadyForImages) _ = PrepareImagesAsync(false);
        }
    }
}
