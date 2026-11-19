using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
namespace Cliphoard.Windows;

internal sealed partial class HistoryWindow
{
    private bool preparingSpeech, transcribingSpeech;
    private async Task<bool> PrepareSpeechAsync(bool download)
    {
        if (preparingSpeech || locked || closing) return false;
        preparingSpeech = true;
        string model = store.State.SpeechModel;
        long generation = modelGeneration;
        CancellationToken cancellation = modelLifetime.Token;
        try
        {
            var progress = new Progress<string>(message => { if (!locked && !closing && generation == modelGeneration) Notice(message); });
            await Task.Run(() => SpeechModel.EnsureAsync(model, download, cancellation, progress), cancellation);
            if (locked || closing || generation != modelGeneration) return false;
            Notice("Whisper model is verified and ready for local transcription."); return true;
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing && generation == modelGeneration) Notice("Whisper preparation failed. Check free space and retry the explicit download."); }
        finally { preparingSpeech = false; }
        return false;
    }
    private async Task TranscribeClipAsync(HistoryItem item, TextBox result, Button button, Window inspector)
    {
        if (transcribingSpeech || item.AnalysisVetoed || locked || closing || !store.State.Items.Contains(item)) return;
        string path = item.Text.Split('\n')[0].TrimEnd('\r');
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(analysisLifetime.Token);
        CancellationTokenSource? active = cancellation;
        bool inspectorClosed = false;
        inspector.Closed += (_, _) => { inspectorClosed = true; active?.Cancel(); };
        transcribingSpeech = true; button.IsEnabled = false; button.Content = "Transcribing locally…";
        long generation = analysisGeneration;
        string model = store.State.SpeechModel;
        try
        {
            // Release the optional emulated media engine before admitting the largest speech model.
            searchCancellation.Cancel(); searching = false; rankedKey = "";
            await semantic.ClearAsync(); await ClearScreeningAsync();
            string transcript = await Task.Run(() => MediaSpeechTranscript.ReadAsync(path, model, cancellation.Token), cancellation.Token);
            if (cancellation.IsCancellationRequested || inspectorClosed || locked || closing || generation != analysisGeneration || !store.State.Items.Contains(item) || item.AnalysisVetoed) return;
            bool explicitContent = false;
            long recognizedFlags = ContentSafety.Flags(transcript);
            if ((recognizedFlags & ~8L) == 0 && NsfwActive && !NsfwPolicy.Exempt(item) && (store.State.NsfwAudio || store.State.NsfwVideo))
            {
                try { explicitContent = await Task.Run(() => ScreenTranscriptAsync(transcript, cancellation.Token), cancellation.Token); }
                catch (IOException) { explicitContent = ContentDetectors.HasNsfwLabel(transcript); }
            }
            if (cancellation.IsCancellationRequested || inspectorClosed || locked || closing || generation != analysisGeneration || !store.State.Items.Contains(item)) return;
            long before = item.Flags;
            if (explicitContent) item.Flags |= 128;
            item.Flags |= recognizedFlags;
            item.Transcript = item.AnalysisVetoed ? "" : transcript;
            if (item.Flags != before) PrivacyClassificationChanged(item);
            store.Trim(); store.Save(); searchCancellation.Cancel(); rankedKey = ""; Refresh();
            if (item.AnalysisVetoed) { if (!inspectorClosed) inspector.Close(); Notice("The recognized content requires protection and was withheld from search."); }
            else { result.Text = transcript; Notice("Transcript saved with the encrypted clip."); }
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing && !inspectorClosed) Notice("Transcription could not complete. Prepare the selected Whisper model and choose a supported local audio or video file up to one hour."); }
        finally
        {
            active = null; transcribingSpeech = false;
            if (!inspectorClosed) { button.IsEnabled = true; button.Content = "Transcribe audio"; }
            if (!locked && !closing)
            {
                if (store.State.SearchMode is "neural" or "smart" or "essence" && !ReadyForSearch) _ = PrepareSearchAsync(false);
                if (store.State.SearchMode == "image" && !ReadyForImages) _ = PrepareImagesAsync(false);
            }
        }
    }
}
