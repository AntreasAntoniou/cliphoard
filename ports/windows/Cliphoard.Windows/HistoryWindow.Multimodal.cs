namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    private CancellationTokenSource multimodalCancellation = new();
    private bool multimodalSearching;
    private void ClearMultimodal()
    {
        multimodalCancellation.Cancel(); multimodalSearching = false; multimodalKey = ""; combinedImages.Clear(); audioMatches.Clear(); videoMatches.Clear(); validMedia.Clear(); fusedScores.Clear();
    }
    private void ScheduleMultimodalSearch()
    {
        string modality = EffectiveModality;
        if (modality == "text" || store.State.SearchMode == "image" || indexingMedia || indexingPaused) return;
        string key = QueryKey() + modality + store.State.SearchTextEnabled + store.State.SearchImagesEnabled + store.State.SearchAudioEnabled + store.State.SearchVideoEnabled;
        if (multimodalKey == key) return;
        multimodalKey = key; multimodalSearching = ActiveQuery.Length != 0; combinedImages.Clear(); audioMatches.Clear(); videoMatches.Clear(); validMedia.Clear();
        multimodalCancellation.Cancel(); multimodalCancellation.Dispose(); multimodalCancellation = CancellationTokenSource.CreateLinkedTokenSource(analysisLifetime.Token);
        CancellationToken cancellation = multimodalCancellation.Token; string query = ActiveQuery;
        bool pictures = modality == "images" || modality == "all" && store.State.SearchImagesEnabled;
        bool sounds = modality == "audio" || modality == "all" && store.State.SearchAudioEnabled;
        bool videos = modality == "video" || modality == "all" && store.State.SearchVideoEnabled;
        HistoryItem[] images = store.State.Items.Where(item => item.Kind == "Image" && !item.AnalysisVetoed).ToArray();
        HistoryItem[] files = store.State.Items.Where(item => item.MediaIndex is not null && !item.AnalysisVetoed && item.MediaIndex.MatchesSettings(store.State)).ToArray();
        string backend = store.State.ImageModel;
        _ = RunAsync();
        async Task RunAsync()
        {
            try
            {
                var audio = new Dictionary<string, MediaMatch>(); var video = new Dictionary<string, MediaMatch>(); var available = new HashSet<string>();
                var pictureScores = new Dictionary<string, double>();
                await Task.Run(async () =>
                {
                    foreach (HistoryItem item in files)
                    {
                        cancellation.ThrowIfCancellationRequested();
                        if (item.MediaIndex!.FileUnchanged()) available.Add(item.Id);
                    }
                    if (query.Length == 0) return;
                    if (pictures && ReadyForImages) pictureScores = await RankImagesAsync(images, backend, query, null, false, cancellation);
                    if ((!sounds && !videos) || available.Count == 0) return;
                    await semantic.PrepareMediaAsync(false, modelLifetime.Token, null);
                    float[] question = await semantic.EmbedMediaAsync(query, true, cancellation);
                    try
                    {
                        foreach (HistoryItem item in files.Where(item => available.Contains(item.Id)))
                        {
                            cancellation.ThrowIfCancellationRequested(); if (item.AnalysisVetoed) continue;
                            MediaIndex index = item.MediaIndex!;
                            foreach (MediaMoment moment in index.Moments)
                            {
                                bool sound = sounds && (moment.Modality == "audio" || moment.Modality == "speech" && !index.Video);
                                bool picture = videos && (moment.Modality == "video" || moment.Modality == "speech" && index.Video);
                                if (!sound && !picture) continue;
                                float[] vector = MediaIndex.Unpack(moment.Vector);
                                double score; try { score = SemanticEngine.Dot(question, vector); } finally { Array.Clear(vector); }
                                var match = new MediaMatch(item.Id, moment.Start, moment.End, score, moment.Modality == "speech" ? "Speech" : sound ? "Audio track" : "Video frame", moment.Text);
                                if (sound && (!audio.TryGetValue(item.Id, out MediaMatch? priorAudio) || score > priorAudio.Score)) audio[item.Id] = match;
                                if (picture && (!video.TryGetValue(item.Id, out MediaMatch? priorVideo) || score > priorVideo.Score)) video[item.Id] = match;
                            }
                        }
                    }
                    finally { Array.Clear(question); }
                }, cancellation);
                if (locked || closing || cancellation.IsCancellationRequested || multimodalKey != key) return;
                combinedImages = pictureScores; validMedia.UnionWith(available);
                foreach (var pair in audio) audioMatches[pair.Key] = pair.Value;
                foreach (var pair in video) videoMatches[pair.Key] = pair.Value;
                multimodalSearching = false; Refresh();
            }
            catch (OperationCanceledException) { }
            catch { if (!locked && !closing && multimodalKey == key) { multimodalSearching = false; Notice("Some media search results are unavailable. Check the prepared local models and indexed files."); Refresh(); } }
        }
    }
    private bool MatchesUnifiedQuery(HistoryItem item)
    {
        if (EffectiveModality == "text" || store.State.SearchMode == "image") return MatchesQuery(item);
        if (item.AnalysisVetoed) return false;
        bool empty = ActiveQuery.Length == 0;
        bool pictures = item.Kind == "Image" && (empty || combinedImages.GetValueOrDefault(item.Id) >= (store.State.ImageModel == "openvision-tiny-p8" ? OpenVisionModel.RelevanceFloor : GemmaPictureRelevance.MinimumSpecificity));
        bool sound = empty ? validMedia.Contains(item.Id) && item.MediaIndex!.Audio : audioMatches.ContainsKey(item.Id);
        bool video = empty ? validMedia.Contains(item.Id) && item.MediaIndex!.Video : videoMatches.ContainsKey(item.Id);
        return EffectiveModality switch
        {
            "images" => pictures, "audio" => sound, "video" => video,
            "all" => store.State.SearchTextEnabled && MatchesQuery(item) || store.State.SearchImagesEnabled && pictures || store.State.SearchAudioEnabled && sound || store.State.SearchVideoEnabled && video,
            _ => false
        };
    }
    private void BuildFusion(HistoryItem[] scope)
    {
        fusedScores.Clear(); if (EffectiveModality != "all" || ActiveQuery.Length == 0) return;
        var ids = scope.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        string[] text = store.State.SearchTextEnabled ? scope.Where(MatchesQuery).OrderByDescending(SearchScore).Select(item => item.Id).ToArray() : Array.Empty<string>();
        string[] images = store.State.SearchImagesEnabled ? combinedImages.Where(pair => ids.Contains(pair.Key) && pair.Value >= (store.State.ImageModel == "openvision-tiny-p8" ? OpenVisionModel.RelevanceFloor : GemmaPictureRelevance.MinimumSpecificity)).OrderByDescending(pair => pair.Value).Select(pair => pair.Key).ToArray() : Array.Empty<string>();
        if (store.State.SearchImagesEnabled && store.State.ImageModel == "openvision-tiny-p8")
        {
            var imageIds = scope.Where(item => item.Kind == "Image").Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
            images = RankFusion.Order(new[] { text.Where(imageIds.Contains), images }); text = text.Where(id => !imageIds.Contains(id)).ToArray();
        }
        IEnumerable<string> audio = store.State.SearchAudioEnabled ? audioMatches.Values.Where(match => ids.Contains(match.Id)).OrderByDescending(match => match.Score).Select(match => match.Id) : Array.Empty<string>();
        IEnumerable<string> video = store.State.SearchVideoEnabled ? videoMatches.Values.Where(match => ids.Contains(match.Id)).OrderByDescending(match => match.Score).Select(match => match.Id) : Array.Empty<string>();
        fusedScores = RankFusion.Scores(new[] { text, images, audio, video });
    }
    private double UnifiedScore(HistoryItem item) => EffectiveModality switch
    {
        "all" => fusedScores.GetValueOrDefault(item.Id),
        "audio" => audioMatches.GetValueOrDefault(item.Id)?.Score ?? 0,
        "video" => videoMatches.GetValueOrDefault(item.Id)?.Score ?? 0,
        "images" when store.State.SearchMode != "image" => combinedImages.GetValueOrDefault(item.Id),
        _ => SearchScore(item)
    };
}
