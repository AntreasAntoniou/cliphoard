namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    private void PruneIndexes()
    {
        var ids = store.State.Items.Where(item => !item.AnalysisVetoed).Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        _ = Task.Run(() => { try { indexes.Retain(ids); } catch (IOException) { } catch (UnauthorizedAccessException) { } });
    }
    private async Task ForgetIndexesAsync()
    {
        indexingPaused = true; InvalidateAnalysis();
        await semantic.ClearAsync();
        await ClearImagesAsync();
        try { await Task.Run(indexes.Forget); Notice("Cached semantic indexes forgotten. Resume indexing when ready."); }
        catch { Notice("Some cached indexes could not be removed. Indexing stays paused."); }
    }
}
