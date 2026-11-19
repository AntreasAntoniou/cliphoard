namespace Cliphoard.Windows;

internal sealed partial class HistoryWindow
{
    private OpenVisionModel? vision;
    private readonly SemaphoreSlim visionLane = new(1);
    private readonly Dictionary<string, float[]> imageVectors = new();
    private readonly List<float[]> gemmaImageBackgrounds = new();
    private bool preparingImages;
    private string imageBackend = "";
    private bool ReadyForImages => store.State.ImageModel == "embeddinggemma-2-740m" ? semantic.MediaReady : vision is not null;

    private async Task<bool> PrepareImagesAsync(bool download)
    {
        if (preparingImages || locked || closing) return false;
        preparingImages = true;
        string backend = store.State.ImageModel;
        long generation = modelGeneration;
        CancellationToken cancellation = modelLifetime.Token;
        try
        {
            var progress = new Progress<string>(message => { if (!locked && !closing && generation == modelGeneration) Notice(message); });
            await Task.Run(async () =>
            {
                await visionLane.WaitAsync(cancellation);
                try
                {
                    if (backend == "embeddinggemma-2-740m") await semantic.PrepareMediaAsync(download, cancellation, progress);
                    else if (vision is null)
                    {
                        await OpenVisionModel.EnsureAsync(download, cancellation, progress);
                        var next = new OpenVisionModel();
                        if (cancellation.IsCancellationRequested) { next.Dispose(); cancellation.ThrowIfCancellationRequested(); }
                        vision = next;
                    }
                }
                finally { visionLane.Release(); }
            }, cancellation);
            if (locked || closing || generation != modelGeneration) return false;
            rankedKey = ""; multimodalKey = ""; BuildChrome(); Refresh(); return true;
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing && generation == modelGeneration) Notice("Prepare the selected image model in Search settings."); }
        finally
        {
            preparingImages = false;
            if (!locked && !closing && generation != modelGeneration && UsesImageSearch && !ReadyForImages) _ = PrepareImagesAsync(false);
            else if (!locked && !closing && generation == modelGeneration) Refresh();
        }
        return false;
    }
    private async Task ClearImagesAsync()
    {
        await visionLane.WaitAsync();
        try
        {
            vision?.Dispose(); vision = null;
            foreach (float[] vector in imageVectors.Values.Concat(gemmaImageBackgrounds)) Array.Clear(vector);
            imageVectors.Clear(); gemmaImageBackgrounds.Clear();
        }
        finally { visionLane.Release(); }
    }
    private void ScheduleImageSearch()
    {
        if (referenceImage is null && string.IsNullOrWhiteSpace(ActiveQuery) || !perceptualReference && !ReadyForImages) return;
        string key = QueryKey();
        if (rankedKey == key) return;
        rankedKey = key; semanticScores.Clear(); searching = true;
        searchCancellation.Cancel(); searchCancellation.Dispose();
        searchCancellation = CancellationTokenSource.CreateLinkedTokenSource(analysisLifetime.Token);
        CancellationToken cancellation = searchCancellation.Token;
        string backend = store.State.ImageModel, query = ActiveQuery;
        HistoryItem? reference = referenceImage; bool perceptual = perceptualReference;
        HistoryItem[] candidates = store.State.Items.Where(item => item.Kind == "Image" && !item.AnalysisVetoed).ToArray();
        _ = RankAsync();
        async Task RankAsync()
        {
            try
            {
                var scores = await Task.Run(() => RankImagesAsync(candidates, backend, query, reference, perceptual, cancellation), cancellation);
                if (cancellation.IsCancellationRequested || locked || closing || key != rankedKey) return;
                semanticScores = scores; semanticMatches = scores.Keys.ToHashSet(); searching = false; Refresh();
            }
            catch (OperationCanceledException) { }
            catch { if (!locked && !closing && key == rankedKey) { searching = false; Notice("Image search could not complete. Check the selected model in Search settings."); } }
        }
    }
    private async Task<Dictionary<string, double>> RankImagesAsync(HistoryItem[] candidates, string backend, string query, HistoryItem? reference, bool perceptual, CancellationToken cancellation)
    {
        await visionLane.WaitAsync(cancellation);
        try
        {
            if (reference is not null && perceptual)
            {
                float[] perceptualQuestion = await PerceptualImage.FeatureAsync(reference, cancellation);
                try
                {
                    var neighbors = new Dictionary<string, double>();
                    foreach (HistoryItem item in candidates.Where(item => item.Id != reference.Id))
                    {
                        float[] feature = await PerceptualImage.FeatureAsync(item, cancellation);
                        try { neighbors[item.Id] = SemanticEngine.Dot(perceptualQuestion, feature); } finally { Array.Clear(feature); }
                    }
                    return neighbors.OrderByDescending(pair => pair.Value).Take(8).ToDictionary(pair => pair.Key, pair => pair.Value);
                }
                finally { Array.Clear(perceptualQuestion); }
            }
            if (imageBackend != backend)
            {
                foreach (var vector in imageVectors.Values.Concat(gemmaImageBackgrounds)) Array.Clear(vector);
                imageVectors.Clear(); gemmaImageBackgrounds.Clear(); imageBackend = backend;
            }
            var keep = new HashSet<string>();
            var vectors = new Dictionary<string, float[]>();
            foreach (HistoryItem item in candidates)
            {
                cancellation.ThrowIfCancellationRequested();
                if (item.AnalysisVetoed) continue;
                string identity = item.Id + ":" + item.Fingerprint;
                keep.Add(identity);
                if (!imageVectors.TryGetValue(identity, out float[]? vector))
                {
                    string signature = "image:" + backend + ":v1";
                    vector = indexes.Read(item.Id, signature, item.Fingerprint, backend == "embeddinggemma-2-740m" ? 768 : 192);
                    if (vector is null)
                    {
                        vector = backend == "embeddinggemma-2-740m"
                            ? await semantic.EmbedMediaAsync("", false, cancellation, image: await ImageAnalysis.PngAsync(item, cancellation))
                            : (vision ?? throw new IOException("Image model is unavailable.")).EmbedPixels(await OpenVisionModel.PixelsAsync(item, cancellation), cancellation);
                        cancellation.ThrowIfCancellationRequested();
                        indexes.Write(item.Id, signature, item.Fingerprint, vector, cancellation);
                    }
                    cancellation.ThrowIfCancellationRequested(); imageVectors[identity] = vector;
                }
                vectors[item.Id] = vector;
            }
            foreach (string identity in imageVectors.Keys.Where(identity => !keep.Contains(identity)).ToArray()) { Array.Clear(imageVectors[identity]); imageVectors.Remove(identity); }
            if (reference is not null)
            {
                float[] feature = backend == "embeddinggemma-2-740m"
                    ? await semantic.EmbedMediaAsync("", false, cancellation, image: await ImageAnalysis.PngAsync(reference, cancellation))
                    : vision!.EmbedPixels(await OpenVisionModel.PixelsAsync(reference, cancellation), cancellation);
                try { return vectors.Where(pair => pair.Key != reference.Id).Select(pair => (pair.Key, Score: SemanticEngine.Dot(feature, pair.Value))).OrderByDescending(pair => pair.Score).Take(30).ToDictionary(pair => pair.Key, pair => pair.Score); }
                finally { Array.Clear(feature); }
            }
            if (backend != "embeddinggemma-2-740m") return vision!.RankText(query, vectors, cancellation);
            float[] question = await semantic.EmbedMediaAsync(query, true, cancellation);
            try
            {
                if (gemmaImageBackgrounds.Count == 0)
                {
                    var prepared = new List<float[]>();
                    foreach (string background in GemmaPictureRelevance.BackgroundQueries)
                        prepared.Add(await semantic.EmbedMediaAsync(background, true, cancellation));
                    cancellation.ThrowIfCancellationRequested();
                    gemmaImageBackgrounds.AddRange(prepared);
                }
                var relevant = new Dictionary<string, double>();
                foreach (var pair in vectors)
                    if (GemmaPictureRelevance.Score(question, pair.Value, gemmaImageBackgrounds) is double score) relevant[pair.Key] = score;
                return relevant;
            }
            finally { Array.Clear(question); }
        }
        finally { visionLane.Release(); }
    }

}
