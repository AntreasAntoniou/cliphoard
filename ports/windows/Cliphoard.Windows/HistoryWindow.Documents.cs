namespace Cliphoard.Windows;

internal sealed partial class HistoryWindow
{
    private bool extractingDocuments;
    private async void AnalyzePendingDocuments()
    {
        if (!store.State.DocumentTextEnabled || extractingDocuments || locked || closing) return;
        extractingDocuments = true;
        long generation = analysisGeneration;
        CancellationToken cancellation = analysisLifetime.Token;
        bool pdf = store.State.PdfTextEnabled, richText = store.State.RichTextEnabled;
        try
        {
            var pending = store.State.Items.Where(item => item.Kind == "Files" && item.DocumentText is null && !item.AnalysisVetoed).ToArray();
            foreach (HistoryItem item in pending)
            {
                string fingerprint = SensitiveRevealState.Fingerprint(item);
                var output = new System.Text.StringBuilder();
                bool truncated = false;
                foreach (string path in item.Text.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).Take(20))
                {
                    cancellation.ThrowIfCancellationRequested();
                    if (DocumentWorkerClient.Format(path, pdf, richText) is null) continue;
                    try
                    {
                        DocumentResponse result = await Task.Run(() => DocumentWorkerClient.ExtractAsync(path, pdf, richText, cancellation), cancellation);
                        output.AppendLine(result.Text); truncated |= result.Truncated;
                        if (output.Length >= 200000) { truncated = true; break; }
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (IOException) { }
                }
                if (locked || closing || generation != analysisGeneration || cancellation.IsCancellationRequested) return;
                if (!store.State.DocumentTextEnabled || !store.State.Items.Contains(item) || item.AnalysisVetoed || fingerprint != SensitiveRevealState.Fingerprint(item)) continue;
                string text = output.ToString();
                if (text.Length > 200000) text = text[..200000];
                long before = item.Flags; item.Flags |= ContentSafety.Flags(text, item.Source);
                item.DocumentText = item.AnalysisVetoed ? "" : text;
                item.DocumentTruncated = truncated;
                if (item.Flags != before) PrivacyClassificationChanged(item);
                store.Trim(); store.Save(); rankedKey = ""; searchCancellation.Cancel(); Refresh();
            }
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing && generation == analysisGeneration) Notice("Document extraction could not complete. Refresh the snapshot to retry."); }
        finally
        {
            extractingDocuments = false;
            if (!locked && !closing && store.State.DocumentTextEnabled && store.State.Items.Any(item => item.Kind == "Files" && item.DocumentText is null && !item.AnalysisVetoed)) DispatcherQueue.TryEnqueue(AnalyzePendingDocuments);
        }
    }
}
