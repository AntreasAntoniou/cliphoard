using System.Diagnostics;
using System.Drawing.Imaging;
using System.Reflection;
using System.Text.Json;
using Cliphoard.Windows;

// Synthetic quality measurements. No clipboard, owner history, or implicit downloads.
internal static class SearchEvaluation
{
    private sealed record Document(string Id, string Text, string[] Tags);
    private sealed record Query(string Id, string Text, string[] Relevant, string? Mode);
    private sealed record Corpus(int Version, Document[] Documents, Query[] Queries);
    private sealed record Outcome(string Id, string Query, string[] Relevant, string[] Returned,
        int? FirstRelevantRank, double Milliseconds, Dictionary<string, double> Scores);

    internal static void PrepareProfile()
    {
        const string directory = @"C:\CliphoardDev\qualification\interactive-profile";
        VerifiedModelAssets.CheckPath(directory);
        if (File.ReadAllText(Path.Combine(directory, ".synthetic-only")) != "CLIPHOARD_SYNTHETIC_V1")
            throw new IOException("Synthetic profile marker missing.");
        using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.SearchEvaluation.json")
            ?? throw new IOException("Search corpus missing.");
        Corpus corpus = JsonSerializer.Deserialize<Corpus>(resource, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new IOException("Invalid search corpus.");
        var store = new HistoryStore(directory);
        if (!store.Writable) throw new IOException("Synthetic profile is unavailable.");
        store.State.Limit = 0;
        foreach (Document document in corpus.Documents)
            store.Add(new HistoryItem { Text = document.Text, Tags = document.Tags.ToList(), Source = "Synthetic search evaluation" });
        foreach (HistoryItem picture in Pictures().Values)
        {
            picture.Source = "Synthetic search evaluation";
            store.Add(picture);
        }
        store.State.SearchMode = "neural"; store.State.SearchModality = "text";
        store.State.SemanticModel = "open-ogma-small"; store.State.OgmaDimension = 1024;
        store.State.ImageModel = "embeddinggemma-2-740m";
        store.Save();
        if (!store.Writable || store.UnsavedChanges) throw new IOException("Synthetic search profile could not be saved.");
        Console.WriteLine(JsonSerializer.Serialize(new { synthetic_search_profile_ready = true, added_text_cases = corpus.Documents.Length, added_images = 8 }));
    }

    internal static async Task TextAsync()
    {
        using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.SearchEvaluation.json")
            ?? throw new IOException("Search corpus missing.");
        Corpus corpus = JsonSerializer.Deserialize<Corpus>(resource, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new IOException("Invalid search corpus.");
        var documents = corpus.Documents.Select(document => new SemanticDocument(document.Id, document.Text, document.Tags, Array.Empty<string>())).ToArray();
        var basket = TagCatalog.Compose(new HistoryState());
        using var lifetime = new CancellationTokenSource(TimeSpan.FromMinutes(30));
        foreach (TextModelInfo model in ModelCatalog.Text)
        foreach (int dimension in model.OgmaHeads ? new[] { 384, 1024 } : new[] { model.Dimension })
        {
            using var engine = new SemanticEngine();
            var preparation = Stopwatch.StartNew();
            await engine.PrepareAsync(false, lifetime.Token, model: model.Id, dimension: dimension);
            preparation.Stop();
            double floor = model.OgmaHeads ? dimension == 1024 ? .40 : .58 : .20;
            foreach (string mode in new[] { "neural", "smart" })
            {
                var outcomes = new List<Outcome>();
                foreach (Query query in corpus.Queries)
                {
                    var timer = Stopwatch.StartNew();
                    var result = await engine.SearchAsync(query.Text, documents, basket, .28, query.Mode ?? mode, floor, lifetime.Token);
                    string[] returned = result.Scores.Where(pair => result.Matches.Contains(pair.Key))
                        .OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key).ToArray();
                    timer.Stop();
                    outcomes.Add(Measure(query, returned, timer.Elapsed.TotalMilliseconds, result.Scores));
                }
                Report("text", model.Id, dimension, mode, "mixed-16", corpus.Version, preparation.Elapsed.TotalMilliseconds, outcomes);
            }
        }
    }

    internal static async Task ImagesAsync()
    {
        using var lifetime = new CancellationTokenSource(TimeSpan.FromMinutes(30));
        var pictures = Pictures();
        var queries = new[]
        {
            new Query("short-red", "red", new[] { "red" }, null),
            new Query("phrase-red", "a red picture", new[] { "red" }, null),
            new Query("short-blue", "blue", new[] { "blue" }, null),
            new Query("phrase-blue", "a blue picture", new[] { "blue" }, null),
            new Query("short-green", "green", new[] { "green" }, null),
            new Query("cat-short", "cat", new[] { "cat" }, null),
            new Query("cat-phrase", "a drawing of a cat", new[] { "cat" }, null),
            new Query("cat-synonym", "feline", new[] { "cat" }, null),
            new Query("clock-short", "clock", new[] { "clock" }, null),
            new Query("tree-short", "tree", new[] { "tree" }, null),
            new Query("no-answer-airplane", "airplane", Array.Empty<string>(), null),
            new Query("no-answer-ocean", "ocean waves", Array.Empty<string>(), null)
        };
        try
        {
            foreach (string backend in ModelCatalog.Images)
            {
                var vectors = new Dictionary<string, float[]>();
                var backgrounds = new List<float[]>();
                using var gemma = new GemmaWorkerClient();
                OpenVisionModel? vision = null;
                var preparation = Stopwatch.StartNew();
                try
                {
                    if (backend == "openvision-tiny-p8")
                    {
                        await OpenVisionModel.EnsureAsync(false, lifetime.Token, null);
                        vision = new OpenVisionModel();
                    }
                    else
                    {
                        await gemma.PrepareAsync(false, lifetime.Token, null);
                        foreach (string background in GemmaPictureRelevance.BackgroundQueries)
                            backgrounds.Add(await gemma.EmbedAsync(background, true, lifetime.Token));
                    }
                    foreach (var pair in pictures)
                        vectors[pair.Key] = vision is null
                            ? await gemma.EmbedAsync("", false, lifetime.Token, image: pair.Value.Payload)
                            : vision.EmbedPixels(await OpenVisionModel.PixelsAsync(pair.Value, lifetime.Token), lifetime.Token);
                    preparation.Stop();
                    var collections = new Dictionary<string, string[]>
                    {
                        ["single-red"] = new[] { "red" },
                        ["red-blue"] = new[] { "red", "blue" },
                        ["mixed-8"] = pictures.Keys.ToArray(),
                        ["duplicate-red"] = pictures.Keys.Append("red-copy").ToArray()
                    };
                    vectors["red-copy"] = vectors["red"].ToArray();
                    foreach (var collection in collections)
                    {
                        var selected = collection.Value.ToDictionary(id => id, id => vectors[id]);
                        var outcomes = new List<Outcome>();
                        foreach (Query original in queries)
                        {
                            string[] expected = original.Relevant.Where(selected.ContainsKey).ToArray();
                            if (expected.Contains("red") && selected.ContainsKey("red-copy")) expected = expected.Append("red-copy").ToArray();
                            Query query = original with { Relevant = expected };
                            var timer = Stopwatch.StartNew();
                            Dictionary<string, double> scores;
                            double floor;
                            if (vision is not null)
                            {
                                scores = vision.RankText(query.Text, selected, lifetime.Token);
                                floor = OpenVisionModel.RelevanceFloor;
                            }
                            else
                            {
                                float[] question = await gemma.EmbedAsync(query.Text, true, lifetime.Token);
                                try
                                {
                                    scores = new();
                                    foreach (var pair in selected)
                                        if (GemmaPictureRelevance.Score(question, pair.Value, backgrounds) is double score) scores[pair.Key] = score;
                                }
                                finally { Array.Clear(question); }
                                floor = GemmaPictureRelevance.MinimumSpecificity;
                            }
                            string[] returned = scores.Where(pair => pair.Value >= floor).OrderByDescending(pair => pair.Value)
                                .ThenBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key).ToArray();
                            timer.Stop();
                            outcomes.Add(Measure(query, returned, timer.Elapsed.TotalMilliseconds, scores));
                        }
                        Report("image", backend, vision is null ? 768 : 192, "image", collection.Key, 1, preparation.Elapsed.TotalMilliseconds, outcomes);
                    }
                }
                finally
                {
                    vision?.Dispose();
                    foreach (float[] vector in vectors.Values.Concat(backgrounds)) Array.Clear(vector);
                }
            }
        }
        finally { foreach (HistoryItem picture in pictures.Values) if (picture.Payload is byte[] bytes) Array.Clear(bytes); }
    }

    private static Outcome Measure(Query query, string[] returned, double milliseconds, Dictionary<string, double> scores)
    {
        int index = Array.FindIndex(returned, query.Relevant.Contains);
        return new(query.Id, query.Text, query.Relevant, returned, index < 0 ? null : index + 1, milliseconds, scores);
    }

    private static void Report(string modality, string model, int dimension, string mode, string collection, int corpusVersion,
        double preparationMilliseconds, List<Outcome> outcomes)
    {
        Outcome[] positive = outcomes.Where(outcome => outcome.Relevant.Length > 0).ToArray();
        Outcome[] negative = outcomes.Where(outcome => outcome.Relevant.Length == 0).ToArray();
        var retrieved = outcomes.SelectMany(outcome => outcome.Returned.Take(3).Select(id => (Outcome: outcome, Id: id))).ToArray();
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            evaluation = "synthetic-search-v1", modality, model, dimension, mode, collection, corpusVersion,
            preparationMilliseconds, queries = outcomes.Count,
            hitAt1 = positive.Count(outcome => outcome.FirstRelevantRank == 1) / (double)positive.Length,
            hitAt3 = positive.Count(outcome => outcome.FirstRelevantRank <= 3) / (double)positive.Length,
            meanReciprocalRank = positive.Average(outcome => outcome.FirstRelevantRank is int rank ? 1.0 / rank : 0),
            noAnswerFalsePositiveRate = negative.Count(outcome => outcome.Returned.Length > 0) / (double)negative.Length,
            precisionAt3 = retrieved.Length == 0 ? 0 : retrieved.Count(pair => pair.Outcome.Relevant.Contains(pair.Id)) / (double)retrieved.Length,
            meanReturned = outcomes.Average(outcome => outcome.Returned.Length),
            includesColdDocumentIndexing = modality == "text" && mode == "neural",
            outcomes
        }));
    }

    private static Dictionary<string, HistoryItem> Pictures()
    {
        var result = new Dictionary<string, HistoryItem>();
        foreach (string id in new[] { "red", "blue", "green", "cat", "clock", "tree", "text", "blank" })
        {
            using var bitmap = new Bitmap(224, 224);
            using var graphics = Graphics.FromImage(bitmap);
            graphics.Clear(id switch { "red" => Color.Red, "blue" => Color.Blue, "green" => Color.Lime, _ => Color.White });
            using var pen = new Pen(Color.Black, 5);
            switch (id)
            {
                case "cat":
                    graphics.FillEllipse(Brushes.Gray, 53, 65, 120, 115);
                    graphics.FillPolygon(Brushes.Gray, new[] { new Point(53, 100), new Point(55, 35), new Point(97, 72) });
                    graphics.FillPolygon(Brushes.Gray, new[] { new Point(130, 72), new Point(171, 35), new Point(173, 100) });
                    graphics.FillEllipse(Brushes.Green, 78, 100, 18, 14); graphics.FillEllipse(Brushes.Green, 132, 100, 18, 14);
                    graphics.FillPolygon(Brushes.Pink, new[] { new Point(103, 130), new Point(123, 130), new Point(113, 143) });
                    graphics.DrawLine(pen, 45, 125, 98, 139); graphics.DrawLine(pen, 128, 139, 185, 125);
                    graphics.DrawLine(pen, 45, 149, 98, 145); graphics.DrawLine(pen, 128, 145, 185, 149);
                    break;
                case "clock":
                    graphics.DrawEllipse(pen, 32, 32, 160, 160);
                    graphics.DrawLine(pen, 112, 112, 112, 55); graphics.DrawLine(pen, 112, 112, 155, 112);
                    break;
                case "tree":
                    graphics.FillRectangle(Brushes.SaddleBrown, 98, 110, 28, 95);
                    graphics.FillEllipse(Brushes.ForestGreen, 42, 20, 140, 135);
                    break;
                case "text":
                    using (var font = new Font("Arial", 24)) graphics.DrawString("Synthetic\nclipboard\nnote", font, Brushes.Black, 12, 30);
                    break;
            }
            using var bytes = new MemoryStream(); bitmap.Save(bytes, ImageFormat.Png);
            result[id] = new HistoryItem { Kind = "Image", Payload = bytes.ToArray(), Format = 0 };
        }
        return result;
    }
}
