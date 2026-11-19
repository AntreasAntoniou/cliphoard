using Microsoft.UI.Xaml;
namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    private readonly SemanticEngine screening = new();
    private bool screeningContent;
    private readonly SemaphoreSlim screeningLane = new(1);
    private OpenVisionModel? screeningVision;
    private float[][]? imageScreeningPositive, imageScreeningNegative;
    private readonly DispatcherTimer protectionPoll = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool previousNsfwActive;
    private void InitializeScreening()
    {
        previousNsfwActive = NsfwActive;
        protectionPoll.Tick += (_, _) =>
        {
            bool active = NsfwActive;
            if (active == previousNsfwActive || locked || closing) return;
            previousNsfwActive = active; revealed.Clear(); ++epoch; InvalidateAnalysis(); UpdateAnalysisPolicy();
            if (auxiliary is not DesktopSettingsWindow) auxiliary?.Close();
            Refresh(); if (active) ScreenPendingContent();
        };
        protectionPoll.Start();
    }
    private float[][]? screeningPositive, screeningNegative;
    private readonly Dictionary<string, string> screened = new();
    private bool NsfwActive => store.State.NsfwEnabled && (!store.State.NsfwFocusOnly || FocusProtection.Read() != false);
    private void UpdateAnalysisPolicy()
    {
        bool active = NsfwActive;
        foreach (HistoryItem item in store.State.Items) item.AnalysisNsfwAllowed = !active || NsfwPolicy.Exempt(item);
    }
    private async void ScreenPendingContent()
    {
        if (!NsfwActive || transcribingSpeech || screeningContent || locked || closing) return;
        screeningContent = true;
        long generation = analysisGeneration;
        CancellationToken cancellation = analysisLifetime.Token;
        try
        {
            foreach (HistoryItem item in store.State.Items.ToArray())
            {
                if (NsfwPolicy.Exempt(item)) continue;
                if (NsfwPolicy.Labelled(item)) { if ((item.Flags & 128) == 0) { item.Flags |= 128; PrivacyClassificationChanged(item); store.Save(); } continue; }
                if (item.Kind == "Files" || item.AnalysisVetoed || (item.Kind == "Image" ? !store.State.NsfwImages : !store.State.NsfwText)) continue;
                string fingerprint = SensitiveRevealState.Fingerprint(item);
                if (screened.GetValueOrDefault(item.Id) == fingerprint) continue;
                bool match = await Task.Run(async () =>
                {
                    await screeningLane.WaitAsync(cancellation);
                    try
                    {
                    if (item.Kind == "Image")
                    {
                        if (screeningVision is null)
                        {
                            await OpenVisionModel.EnsureAsync(false, cancellation, null);
                            screeningVision = new OpenVisionModel();
                        }
                        if (imageScreeningPositive is null || imageScreeningNegative is null)
                        {
                            imageScreeningPositive = NsfwPolicy.Positive.Select(prompt => screeningVision.EmbedText(prompt, cancellation)).ToArray();
                            imageScreeningNegative = NsfwPolicy.Negative.Select(prompt => screeningVision.EmbedText(prompt, cancellation)).ToArray();
                        }
                        return NsfwPolicy.PossibleMatch(screeningVision.EmbedPixels(await OpenVisionModel.PixelsAsync(item, cancellation), cancellation), imageScreeningPositive, imageScreeningNegative);
                    }
                    return await ScreenTextUnlockedAsync(item.Text, cancellation);
                    } finally { screeningLane.Release(); }
                }, cancellation);
                if (locked || closing || generation != analysisGeneration || cancellation.IsCancellationRequested) return;
                if (!NsfwActive || !store.State.Items.Contains(item) || fingerprint != SensitiveRevealState.Fingerprint(item)) continue;
                if (match) { item.Flags |= 128; PrivacyClassificationChanged(item); store.Save(); }
                screened[item.Id] = SensitiveRevealState.Fingerprint(item);
            }
            Refresh();
        }
        catch (OperationCanceledException) { }
        catch { /* Explicit labels remain protective when a local model is unavailable. */ }
        finally { screeningContent = false; }
    }
    private async Task<bool> ScreenTranscriptAsync(string text, CancellationToken cancellation)
    {
        if (ContentDetectors.HasNsfwLabel(text)) return true;
        await screeningLane.WaitAsync(cancellation);
        try { return await ScreenTextUnlockedAsync(text, cancellation); }
        finally { screeningLane.Release(); }
    }
    private async Task<bool> ScreenTextUnlockedAsync(string text, CancellationToken cancellation)
    {
        await screening.PrepareAsync(false, cancellation);
        if (screeningPositive is null || screeningNegative is null)
        {
            var positive = new List<float[]>(); var negative = new List<float[]>();
            foreach (string prompt in NsfwPolicy.Positive) positive.Add(await screening.EmbedAsync(prompt, cancellation));
            foreach (string prompt in NsfwPolicy.Negative) negative.Add(await screening.EmbedAsync(prompt, cancellation));
            cancellation.ThrowIfCancellationRequested(); screeningPositive = positive.ToArray(); screeningNegative = negative.ToArray();
        }
        return NsfwPolicy.PossibleMatch(await screening.EmbedAsync(text, cancellation), screeningPositive, screeningNegative);
    }
    private async Task ClearScreeningAsync()
    {
        await screeningLane.WaitAsync();
        try
        {
            await screening.ClearAsync(); screeningVision?.Dispose(); screeningVision = null;
            foreach (float[] vector in (screeningPositive ?? Array.Empty<float[]>()).Concat(screeningNegative ?? Array.Empty<float[]>()).Concat(imageScreeningPositive ?? Array.Empty<float[]>()).Concat(imageScreeningNegative ?? Array.Empty<float[]>())) Array.Clear(vector);
            screeningPositive = screeningNegative = imageScreeningPositive = imageScreeningNegative = null; screened.Clear();
        }
        finally { screeningLane.Release(); }
    }
}
