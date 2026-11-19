using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;

internal sealed partial class HistoryWindow
{
    private readonly EmbeddingCache indexes;
    private readonly SemanticEngine semantic;
    private CancellationTokenSource analysisLifetime = new(), searchCancellation = new(), modelLifetime = new();
    private bool indexingPaused;
    private string rankedKey = "";
    private Dictionary<string, double> semanticScores = new();
    private Dictionary<string, AutomaticTag[]> automaticTags = new();
    private Dictionary<string, string[]> suggestedTags = new();
    private HashSet<string> semanticMatches = new();
    private long analysisGeneration, modelGeneration;
    private bool preparingModel, recognizingImages, searching;
    private bool UsesImageSearch => store.State.SearchMode == "image" || EffectiveModality == "images" || EffectiveModality == "all" && store.State.SearchImagesEnabled;
    private bool SearchPending => searchInput.Composing || searchInput.Pending || ActiveQuery.Length != 0 && (searching || multimodalSearching || UsesImageSearch && preparingImages);

    private int SelectedDimension => ModelCatalog.Dimension(store.State.SemanticModel, store.State.OgmaDimension);
    private double RelevanceFloor => store.State.SemanticModel.StartsWith("open-ogma-", StringComparison.Ordinal) ? (SelectedDimension == 1024 ? .40 : .58) : .20;
    private bool ReadyForSearch => semantic.Ready && semantic.Model == store.State.SemanticModel && semantic.Dimension == SelectedDimension;
    private string selectedModelKey = "";

    private void InvalidateAnalysis(bool sessionRevoked = false)
    {
        ++analysisGeneration;
        ClearMultimodal();
        if (sessionRevoked) { ++modelGeneration; modelLifetime.Cancel(); modelLifetime.Dispose(); modelLifetime = new(); }
        analysisLifetime.Cancel(); analysisLifetime.Dispose(); analysisLifetime = new();
        searchCancellation.Cancel();
        rankedKey = ""; semanticScores.Clear(); automaticTags.Clear(); suggestedTags.Clear(); semanticMatches.Clear(); searching = false;
    }
    private void AnalysisSettingsChanged()
    {
        string key = store.State.SemanticModel + ":" + SelectedDimension + ":" + store.State.ImageModel + ":" + store.State.SpeechModel;
        InvalidateAnalysis(selectedModelKey != key);
        selectedModelKey = key;
        UpdateAnalysisPolicy();
        if (searchInput.Pending) SearchDraftChanged();
        if (store.State.OcrEnabled) AnalyzePendingImages();
        AnalyzePendingDocuments(); ScreenPendingContent();
        if (UsesImageSearch && !ReadyForImages) _ = PrepareImagesAsync(false);
        if (!ReadyForSearch) _ = PrepareSearchAsync(false);
    }
    private async Task<bool> PrepareSearchAsync(bool download)
    {
        if (preparingModel || locked || closing) return false;
        preparingModel = true;
        long generation = modelGeneration;
        CancellationToken cancellation = modelLifetime.Token;
        string model = store.State.SemanticModel;
        int dimension = SelectedDimension;
        try
        {
            var progress = new Progress<string>(message => { if (!locked && !closing && generation == modelGeneration) Notice(message); });
            await Task.Run(() => semantic.PrepareAsync(download, cancellation, progress, model, dimension), cancellation);
            if (locked || closing || generation != modelGeneration) return false;
            rankedKey = ""; BuildChrome(); Refresh(); return true;
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing && generation == modelGeneration) Notice(download ? "Semantic model preparation failed. Exact search remains available. Try Download again." : "Prepare the semantic model in Search settings to enable neural search."); }
        finally
        {
            preparingModel = false;
            if (!locked && !closing && generation != modelGeneration && store.State.SearchMode is "neural" or "smart" or "essence") _ = PrepareSearchAsync(false);
        }
        return false;
    }
    private string ModelText(HistoryItem item) => item.Kind switch
    {
        "Image" => string.IsNullOrEmpty(item.OcrText) ? item.Text : item.OcrText,
        "Files" => string.Join("\n", item.Text.Split('\n').Select(path => Path.GetFileName(path.TrimEnd('\r')))) + "\n" + item.Transcript + (store.State.DocumentTextEnabled ? "\n" + item.DocumentText : ""),
        _ => item.Text
    };
    private string QueryKey() => store.State.SearchMode + "\0" + referenceImage?.Fingerprint + perceptualReference + "\0" + searchInput.Submitted + "\0" + string.Join(';', store.State.Items.Select(item => item.Id + item.Fingerprint + item.Flags + item.AnalysisNsfwAllowed + item.OcrText + item.Transcript + item.DocumentText + string.Join(',', item.Tags)));
    private void ScheduleSemanticSearch()
    {
        if (indexingMedia || EffectiveModality is "audio" or "video" || EffectiveModality == "images" && store.State.SearchMode != "image") return;
        if (store.State.SearchMode == "image") { ScheduleImageSearch(); return; }
        if (!ReadyForSearch || indexingPaused) return;
        string key = QueryKey();
        if (key == rankedKey) return;
        rankedKey = key; semanticScores.Clear(); searching = true;
        searchCancellation.Cancel(); searchCancellation.Dispose();
        searchCancellation = CancellationTokenSource.CreateLinkedTokenSource(analysisLifetime.Token);
        CancellationToken cancellation = searchCancellation.Token;
        string query = ActiveQuery;
        var documents = store.State.Items.Where(item => !item.AnalysisVetoed).Select(item =>
            new SemanticDocument(item.Id, ModelText(item), item.Tags.ToArray(), item.DismissedSuggestions.ToArray())).ToArray();
        TagBasket basket = TagCatalog.Compose(store.State);
        string mode = store.State.SearchMode;
        double threshold = store.State.TagThreshold, floor = RelevanceFloor;
        _ = RankAsync();
        async Task RankAsync()
        {
            try
            {
                var progress = new Progress<(int Done, int Total)>(value =>
                {
                    if (!locked && !closing && searching && rankedKey == key && value.Done % 16 == 0)
                        count.Text = $"Indexing locally · {value.Done} / {value.Total}";
                });
                var ranked = await Task.Run(() => semantic.SearchAsync(query, documents, basket, threshold, mode, floor, cancellation, progress), cancellation);
                if (cancellation.IsCancellationRequested || locked || closing || rankedKey != key) return;
                if (!store.State.DocumentTagsEnabled)
                    foreach (HistoryItem file in store.State.Items.Where(item => item.Kind == "Files" && item.DocumentText is not null)) { ranked.Tags.Remove(file.Id); ranked.Suggestions.Remove(file.Id); }
                semanticScores = ranked.Scores; automaticTags = ranked.Tags; suggestedTags = ranked.Suggestions; semanticMatches = ranked.Matches; searching = false; Refresh();
            }
            catch (OperationCanceledException) { }
            catch { if (!locked && !closing && rankedKey == key) { searching = false; Notice("Neural search could not complete. Exact matches remain available."); Refresh(); } }
        }
    }
    private bool MatchesQuery(HistoryItem item)
    {
        string query = ActiveQuery.Trim();
        if (store.State.SearchMode == "image" && referenceImage is not null) return !item.AnalysisVetoed && item.Kind == "Image" && semanticMatches.Contains(item.Id);
        if (query.Length == 0) return store.State.SearchMode != "image" || item.Kind == "Image";
        if (item.AnalysisVetoed) return false;
        bool exact = (item.SearchText + (store.State.DocumentTextEnabled ? "\n" + item.DocumentText : "")).Contains(query.TrimStart('#'), StringComparison.OrdinalIgnoreCase) || item.Source.Contains(query, StringComparison.OrdinalIgnoreCase);
        return store.State.SearchMode switch
        {
            "image" => item.Kind == "Image" && ReadyForImages && semanticScores.GetValueOrDefault(item.Id) >= (store.State.ImageModel == "openvision-tiny-p8" ? OpenVisionModel.RelevanceFloor : GemmaPictureRelevance.MinimumSpecificity),
            "tag" => ReadyForSearch ? semanticMatches.Contains(item.Id) : item.Tags.Any(tag => tag.Contains(query.TrimStart('#'), StringComparison.OrdinalIgnoreCase)),
            "neural" or "essence" => ReadyForSearch ? semanticMatches.Contains(item.Id) : exact,
            "smart" => exact || semanticMatches.Contains(item.Id),
            _ => exact
        };
    }
    private double SearchScore(HistoryItem item)
    {
        if (referenceImage is null && string.IsNullOrWhiteSpace(ActiveQuery) || store.State.SearchMode is "exact" or "tag") return 0;
        return semanticScores.GetValueOrDefault(item.Id);
    }
    private void ShowSearchModes(Button button)
    {
        var menu = new MenuFlyout();
        var modalities = new MenuFlyoutSubItem { Text = "Search in" };
        foreach (string modality in new[] { "all", "text", "images", "audio", "video" })
        {
            var option = new ToggleMenuFlyoutItem { Text = char.ToUpperInvariant(modality[0]) + modality[1..], IsChecked = EffectiveModality == modality };
            option.Click += (_, _) => { ++epoch; store.State.SearchModality = modality; if (store.State.SearchMode == "image") store.State.SearchMode = "smart"; store.Save(); InvalidateAnalysis(); if (UsesImageSearch && !ReadyForImages) _ = PrepareImagesAsync(false); BuildChrome(); Refresh(); search.Focus(FocusState.Programmatic); };
            modalities.Items.Add(option);
        }
        menu.Items.Add(modalities);
        var files = new MenuFlyoutItem { Text = "Choose audio or video files…", IsEnabled = !indexingMedia }; files.Click += (_, _) => ChooseMediaFiles(); menu.Items.Add(files);
        var cancelMedia = new MenuFlyoutItem { Text = "Cancel media indexing", IsEnabled = indexingMedia }; cancelMedia.Click += (_, _) => InvalidateAnalysis(); menu.Items.Add(cancelMedia);
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var mode in new[] { ("exact", "Exact"), ("tag", "Tags"), ("neural", "Neural"), ("smart", "Smart"), ("image", "Image") })
        {
            var option = new ToggleMenuFlyoutItem { Text = mode.Item2, IsChecked = store.State.SearchMode == mode.Item1 };
            option.Click += (_, _) =>
            {
                ++epoch; store.State.SearchMode = mode.Item1; store.Save(); rankedKey = "";
                if (mode.Item1 is "neural" or "smart" or "tag" && !ReadyForSearch) _ = PrepareSearchAsync(false);
                if (mode.Item1 == "image" && !ReadyForImages) _ = PrepareImagesAsync(false);
                BuildChrome(); Refresh(); search.Focus(FocusState.Programmatic);
            };
            menu.Items.Add(option);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var reference = new MenuFlyoutItem { Text = "Choose reference image…" }; reference.Click += (_, _) => ChooseReferenceImage(); menu.Items.Add(reference);
        var clearReference = new MenuFlyoutItem { Text = "Clear reference image", IsEnabled = referenceImage is not null }; clearReference.Click += (_, _) => { ClearReferenceImage(); rankedKey = ""; Refresh(); }; menu.Items.Add(clearReference);
        menu.ShowAt(button);
    }
    private async void AnalyzePendingImages()
    {
        if (!store.State.OcrEnabled || locked || closing || recognizingImages) return;
        recognizingImages = true;
        bool unavailable = false;
        long generation = analysisGeneration;
        CancellationToken cancellation = analysisLifetime.Token;
        var pending = store.State.Items.Where(item => item.Kind == "Image" && item.OcrText is null && !item.AnalysisVetoed).ToArray();
        try
        {
            foreach (var item in pending)
            {
                try
                {
                    string text = await Task.Run(() => ImageAnalysis.RecognizeAsync(item, cancellation), cancellation);
                    if (cancellation.IsCancellationRequested || locked || closing || generation != analysisGeneration) return;
                    if (!store.State.Items.Contains(item) || !store.State.OcrEnabled) continue;
                    long before = item.Flags; item.Flags |= ContentSafety.Flags(text);
                    item.OcrText = item.AnalysisVetoed ? "" : text;
                    if (item.Flags != before) PrivacyClassificationChanged(item);
                    store.Trim(); store.Save(); searchCancellation.Cancel(); rankedKey = ""; Refresh();
                }
                catch (OperationCanceledException) { return; }
                catch (IOException)
                {
                    if (locked || closing || generation != analysisGeneration) return;
                    if (store.State.Items.Contains(item)) { item.OcrText = ""; store.Save(); }
                }
                catch
                {
                    unavailable = true;
                    if (!locked && !closing && generation == analysisGeneration) Notice("OCR is unavailable. Check installed Windows recognition languages.");
                    return;
                }
            }
        }
        finally
        {
            recognizingImages = false;
            if (!unavailable && !locked && !closing && store.State.OcrEnabled && store.State.Items.Any(item => item.Kind == "Image" && item.OcrText is null && !item.AnalysisVetoed)) DispatcherQueue.TryEnqueue(AnalyzePendingImages);
        }
    }
}
