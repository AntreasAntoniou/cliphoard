namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    private async Task<bool> PrepareMediaSettingsAsync()
    {
        if (locked || closing || indexingMedia) return false;
        long generation = modelGeneration; CancellationToken cancellation = modelLifetime.Token;
        try
        {
            var progress = new Progress<string>(message => { if (!locked && !closing && generation == modelGeneration) Notice(message); });
            await Task.Run(() => semantic.PrepareMediaAsync(true, cancellation, progress), cancellation);
            if (locked || closing || generation != modelGeneration) return false;
            Notice("Gemma media search is ready offline."); multimodalKey = ""; Refresh(); return true;
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing) Notice("Media preparation failed. Check free space and retry the explicit download."); }
        return false;
    }
}
