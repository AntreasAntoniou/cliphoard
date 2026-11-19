using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using System.Text;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    private bool indexingMedia;
    private readonly Dictionary<string, MediaMatch> audioMatches = new(), videoMatches = new();
    private readonly HashSet<string> validMedia = new();
    private Dictionary<string, double> combinedImages = new();
    private Dictionary<string, double> fusedScores = new();
    private string multimodalKey = "";
    private string EffectiveModality => store.State.SearchMode == "image" ? "images" : store.State.SearchModality;
    private static HistoryItem FileClip(string path)
    {
        byte[] paths = Encoding.Unicode.GetBytes(path + "\0\0"), payload = new byte[20 + paths.Length];
        BitConverter.GetBytes(20).CopyTo(payload, 0); BitConverter.GetBytes(1).CopyTo(payload, 16); paths.CopyTo(payload, 20);
        return new() { Kind = "Files", Format = 15, Text = path, Source = "Selected file", Payload = payload };
    }
    private async void ChooseMediaFiles()
    {
        if (locked || closing || indexingMedia || !store.Writable) return;
        bool suspended = captureSuspended; captureSuspended = true; handingOff = true; ++epoch;
        try
        {
            var picker = new FileOpenPicker(); foreach (string extension in MediaFormats.Extensions) picker.FileTypeFilter.Add(extension);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
            var files = await picker.PickMultipleFilesAsync(); if (locked || closing || files.Count == 0) return;
            handingOff = false; captureSuspended = suspended; clipboard?.Baseline();
            if (files.Count > 10 || store.State.Items.Count(item => item.MediaIndex is not null) + files.Count > 100) { Notice("Choose up to 10 media files at a time, with 100 indexed files maximum."); return; }
            foreach (var file in files)
            {
                if (locked || closing) return;
                var item = FileClip(file.Path); item.Flags = ContentSafety.Flags(item.Text, item.Source); item.AnalysisNsfwAllowed = !NsfwActive;
                if (item.AnalysisVetoed) { Notice("The selected file requires protection and was withheld from indexing."); continue; }
                HistoryItem? existing = store.State.Items.FirstOrDefault(candidate => candidate.Kind == "Files" && candidate.Text == item.Text);
                if (existing is null) { store.Add(item); existing = store.State.Items.FirstOrDefault(candidate => candidate.Id == item.Id); }
                if (existing is not null) await IndexMediaAsync(existing);
            }
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing) Notice("The media selection could not complete. Prepare the local media model and retry."); }
        finally { handingOff = false; captureSuspended = suspended; clipboard?.Baseline(); if (!locked && !closing) Refresh(); }
    }
    private async Task IndexMediaAsync(HistoryItem item)
    {
        UpdateAnalysisPolicy();
        if (indexingMedia || locked || closing || item.AnalysisVetoed || item.Kind != "Files" || !store.State.Items.Contains(item)) return;
        string path = item.Text.Split('\n')[0].TrimEnd('\r');
        string fingerprint = SensitiveRevealState.Fingerprint(item); long generation = analysisGeneration;
        string preset = store.State.MediaPreset, coverage = store.State.MediaSpeechCoverage, speech = store.State.SpeechModel;
        bool screen = NsfwActive && !NsfwPolicy.Exempt(item);
        bool screenVideo = screen && store.State.NsfwVideo, screenAudio = screen && store.State.NsfwAudio;
        CancellationToken cancellation = analysisLifetime.Token;
        indexingMedia = true; searchCancellation.Cancel(); searching = false; Refresh();
        try
        {
            await semantic.ClearAsync(); await ClearImagesAsync(); await ClearScreeningAsync();
            var progress = new Progress<string>(message => { if (!locked && !closing && generation == analysisGeneration) Notice(message); });
            MediaIndex index = await Task.Run(() => MediaIndexer.BuildAsync(path, preset, coverage, speech, screenVideo, screenAudio, semantic, () => !locked && !closing && generation == analysisGeneration && !item.AnalysisVetoed, cancellation, progress), cancellation);
            if (locked || closing || cancellation.IsCancellationRequested || generation != analysisGeneration || !store.State.Items.Contains(item) || fingerprint != SensitiveRevealState.Fingerprint(item) || item.AnalysisVetoed) return;
            item.MediaIndex = index;
            item.Transcript = string.Join('\n', index.Moments.Where(moment => moment.Modality == "speech").Select(moment => moment.Text));
            if (item.Transcript.Length > 65536) item.Transcript = item.Transcript[..65536];
            item.Flags |= ContentSafety.Flags(item.MediaText, item.Source);
            store.Save(); multimodalKey = rankedKey = ""; Notice("Media index saved encrypted. Search Audio, Video or All to find moments.");
        }
        catch (MediaContentRefused refused)
        {
            if (!locked && !closing && generation == analysisGeneration && store.State.Items.Contains(item) && fingerprint == SensitiveRevealState.Fingerprint(item)) { item.Flags |= refused.Flags; PrivacyClassificationChanged(item); store.Save(); }
            Notice("Recognized media content requires protection and was withheld from the index.");
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing) Notice("Media indexing could not complete. Verify the cached Gemma and speech models, local file access and selected limits."); }
        finally
        {
            indexingMedia = false;
            if (!locked && !closing) { rankedKey = ""; if (!ReadyForSearch) _ = PrepareSearchAsync(false); Refresh(); }
        }
    }
    private void ShowMediaMoment(HistoryItem item)
    {
        if (locked || closing || item.AnalysisVetoed || Concealed(item) || item.MediaIndex is not MediaIndex index || !index.FileUnchanged()) { Notice("The indexed file changed or requires protection. Select it again to refresh the index."); return; }
        MediaMatch? match = EffectiveModality == "audio" ? audioMatches.GetValueOrDefault(item.Id) : videoMatches.GetValueOrDefault(item.Id) ?? audioMatches.GetValueOrDefault(item.Id);
        var window = new Window { Title = "Cliphoard media" }; var theme = Theme;
        var panel = new StackPanel { Spacing = 12, Padding = new Thickness(20), Background = Brush(theme.Bar), RequestedTheme = theme.Dark ? ElementTheme.Dark : ElementTheme.Light };
        panel.Children.Add(Text(match?.Source ?? "Indexed media", theme, 18));
        panel.Children.Add(Text($"Moment {TimeSpan.FromSeconds(match?.Start ?? 0):g} · {index.Coverage:P0} sampled sound coverage · {index.Speech} speech", theme, 12, true));
        if (match?.Passage is string passage) panel.Children.Add(new TextBox { Text = passage, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, MaxHeight = 130 });
        global::Windows.Media.Playback.MediaPlayer? player = null;
        MediaPlayerElement? element = null;
        global::Windows.Media.Core.MediaSource? source = null;
        FileStream? lease = null; global::Windows.Storage.Streams.IRandomAccessStream? stream = null; bool stopped = false;
        void Release()
        {
            if (stopped) return; stopped = true;
            try
            {
                if (element is not null) element.SetMediaPlayer(null);
                if (player is not null) { player.MediaOpened -= MediaOpened; player.Pause(); player.Source = null; }
            }
            finally
            {
                try { player?.Dispose(); }
                finally
                {
                    try { source?.Dispose(); }
                    finally { try { stream?.Dispose(); } finally { lease?.Dispose(); } }
                }
            }
        }
        void MediaOpened(global::Windows.Media.Playback.MediaPlayer sender, object args)
        {
            if (stopped) return;
            DispatcherQueue.TryEnqueue(() => { if (!stopped && !locked && !closing) sender.PlaybackSession.Position = TimeSpan.FromSeconds(match?.Start ?? 0); });
        }
        try
        {
            lease = LocalFileLease.Open(index.Path, 2L * 1024 * 1024 * 1024);
            if (LocalFileLease.Identity(lease) != index.FileIdentity) throw new IOException("Indexed file identity changed.");
            stream = lease.AsRandomAccessStream();
            player = new global::Windows.Media.Playback.MediaPlayer { AutoPlay = false };
            string contentType = Path.GetExtension(index.Path).ToLowerInvariant() switch { ".mp3" => "audio/mpeg", ".wav" => "audio/wav", ".flac" => "audio/flac", ".aac" => "audio/aac", ".m4a" => "audio/mp4", ".wma" => "audio/x-ms-wma", ".webm" => "video/webm", ".mkv" => "video/x-matroska", ".avi" => "video/x-msvideo", ".wmv" => "video/x-ms-wmv", ".mov" => "video/quicktime", ".ogg" or ".opus" => "audio/ogg", _ => "video/mp4" };
            player.MediaOpened += MediaOpened;
            window.Closed += (_, _) => Release();
            source = global::Windows.Media.Core.MediaSource.CreateFromStream(stream, contentType); player.Source = source;
            element = new MediaPlayerElement { AreTransportControlsEnabled = true, Height = index.Video ? 340 : 90 }; element.SetMediaPlayer(player); panel.Children.Add(element);
            window.Content = panel; DesktopVisual.FitWindow(window, 760, index.Video ? 600 : 350); DesktopVisual.StyleWindow(window, theme); ShowAuxiliary(window);
        }
        catch { Release(); Notice("Windows could not open this indexed media file for local playback."); }

    }
}
