using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;
internal sealed partial class DesktopSettingsWindow
{
    private void Search(StackPanel body, DesktopTheme theme)
    {
        body.Children.Add(Text("On-device search", theme, 17));
        var modes = new ComboBox { Header = "Search mode", ItemsSource = new[] { "Exact", "Tags", "Neural", "Smart", "Image" }, SelectedIndex = store.State.SearchMode switch { "tag" => 1, "neural" or "essence" => 2, "smart" => 3, "image" => 4, _ => 0 }, HorizontalAlignment = HorizontalAlignment.Stretch };
        modes.SelectionChanged += (_, _) => { if (rebuilding) return; store.State.SearchMode = new[] { "exact", "tag", "neural", "smart", "image" }[Math.Max(0, modes.SelectedIndex)]; Commit(); };
        body.Children.Add(modes);
        var timing = new ComboBox { Header = "Search timing", ItemsSource = new[] { "While typing", "After a short pause", "When I press Enter" }, SelectedIndex = store.State.SearchTiming switch { "instant" => 0, "enter" => 2, _ => 1 }, HorizontalAlignment = HorizontalAlignment.Stretch };
        timing.SelectionChanged += (_, _) => { if (rebuilding || timing.SelectedIndex < 0) return; store.State.SearchTiming = new[] { "instant", "pause", "enter" }[timing.SelectedIndex]; Commit(); };
        body.Children.Add(timing);
        body.Children.Add(Text("Exact searches text, recognized image text, sources and labels. Tags searches user labels and automatic categories. Neural uses your selected model. Basic matching uses word and character similarity. Smart combines literal matches with neural ranking.", theme, 13, true));
        string[] modelNames = ModelCatalog.Text.Select(model => model.Id).ToArray();
        var model = new ComboBox { Header = "Semantic model", ItemsSource = ModelCatalog.Text.Select(model => model.Title).ToArray(), SelectedIndex = Array.IndexOf(modelNames, store.State.SemanticModel), HorizontalAlignment = HorizontalAlignment.Stretch };
        body.Children.Add(model);
        var detail = new ComboBox { Header = "Ogma vector detail", ItemsSource = new[] { "Full · 1024 dimensions", "Compact · 384 dimensions" }, SelectedIndex = store.State.OgmaDimension == 1024 ? 0 : 1, IsEnabled = store.State.SemanticModel.StartsWith("open-ogma-", StringComparison.Ordinal), HorizontalAlignment = HorizontalAlignment.Stretch };
        body.Children.Add(detail);
        body.Children.Add(Text("Basic matching works without a download. Download other verified models once, then search offline. Ogma Micro is 10 MB, Ogma Small 36 MB, MiniLM 91 MB, and EmbeddingGemma 2 485 MB plus its 123 MB runtime. Model files come from Hugging Face. Gemma’s runtime comes from Google’s GitHub release. Clipboard content stays on this device. Downloads start only from this button.", theme, 13, true));
        var prepare = new Button { Content = "Download and prepare semantic search" };
        prepare.Click += async (_, _) =>
        {
            prepare.IsEnabled = false;
            prepare.Content = "Preparing… progress appears in the clipboard bar";
            bool ready = await RunPreparationAsync(prepareSemantic);
            if (closed) return;
            prepare.Content = ready ? "Semantic search is ready offline" : "Retry model preparation";
            prepare.IsEnabled = !ready;
        };
        body.Children.Add(prepare);
        model.SelectionChanged += (_, _) => { if (rebuilding || model.SelectedIndex < 0) return; store.State.SemanticModel = modelNames[model.SelectedIndex]; detail.IsEnabled = ModelCatalog.Text[model.SelectedIndex].OgmaHeads; prepare.IsEnabled = true; prepare.Content = "Download and prepare selected model"; Commit(); };
        detail.SelectionChanged += (_, _) => { if (rebuilding || detail.SelectedIndex < 0) return; store.State.OgmaDimension = detail.SelectedIndex == 0 ? 1024 : 384; prepare.IsEnabled = true; prepare.Content = "Prepare selected projection"; Commit(); };

        body.Children.Add(Text("Ogma · MIT. all-MiniLM-L6-v2 · Apache-2.0 · ONNX Runtime · MIT. License notices are included with the application.", theme, 12, true));
        var imageModel = new ComboBox { Header = "Image search model", ItemsSource = new[] { "OpenVision Tiny · 192 dimensions", "EmbeddingGemma 2 · 768 dimensions" }, SelectedIndex = store.State.ImageModel == "openvision-tiny-p8" ? 0 : 1, HorizontalAlignment = HorizontalAlignment.Stretch };
        body.Children.Add(imageModel);
        var images = new Button { Content = "Download and prepare image search" };
        images.Click += async (_, _) => { images.IsEnabled = false; bool ready = await RunPreparationAsync(prepareImages); if (closed) return; images.Content = ready ? "Image model is ready offline" : "Retry image preparation"; images.IsEnabled = !ready; };
        body.Children.Add(images);
        imageModel.SelectionChanged += (_, _) => { if (rebuilding || imageModel.SelectedIndex < 0) return; store.State.ImageModel = imageModel.SelectedIndex == 0 ? "openvision-tiny-p8" : "embeddinggemma-2-740m"; images.IsEnabled = true; images.Content = "Download and prepare image search"; Commit(); };
        body.Children.Add(Text("OpenVision downloads 69 MB. Image mode searches copied images locally. OpenVision needs at least two images for corpus centering. Gemma uses one private x64 CPU worker on Windows ARM64.", theme, 12, true));
        var speech = new ComboBox { Header = "Speech model", ItemsSource = new[] { "Whisper Small · 488 MB", "Whisper Large v3 · 3.10 GB", "Whisper Large v3 Turbo · 1.62 GB" }, SelectedIndex = store.State.SpeechModel switch { "small" => 0, "largeV3" => 1, _ => 2 }, HorizontalAlignment = HorizontalAlignment.Stretch };
        body.Children.Add(speech);
        var speechDownload = new Button { Content = "Download and verify speech model" };
        speechDownload.Click += async (_, _) => { speechDownload.IsEnabled = false; bool ready = await RunPreparationAsync(prepareSpeech); if (closed) return; speechDownload.Content = ready ? "Speech model verified" : "Retry speech preparation"; speechDownload.IsEnabled = !ready; };
        body.Children.Add(speechDownload);
        speech.SelectionChanged += (_, _) => { if (rebuilding || speech.SelectedIndex < 0) return; store.State.SpeechModel = new[] { "small", "largeV3", "turbo" }[speech.SelectedIndex]; speechDownload.IsEnabled = true; speechDownload.Content = "Download and verify speech model"; Commit(); };
        body.Children.Add(Text("Transcription starts from Inspect on a copied local audio or video file up to one hour. File capture reads paths only. Transcripts stay encrypted and participate in search. Speech uses two CPU threads.", theme, 12, true));
        var pauseIndex = new ToggleSwitch { Header = "Pause semantic indexing for this session", IsOn = semanticIndexingPaused };
        pauseIndex.Toggled += (_, _) => { if (!rebuilding) { semanticIndexingPaused = pauseIndex.IsOn; pauseIndexing(pauseIndex.IsOn); } }; body.Children.Add(pauseIndex);
        var forget = new Button { Content = "Forget cached semantic indexes" };
        forget.Click += async (_, _) => { forget.IsEnabled = false; semanticIndexingPaused = true; pauseIndex.IsOn = true; try { await forgetIndexes(); } finally { forget.IsEnabled = true; } }; body.Children.Add(forget);
        AddPreparationCancellation(body);
        MediaSearchSettings(body, theme);
        AddDocumentSettings(body);
        var ocr = new ToggleSwitch { Header = "Recognize text in copied images", IsOn = store.State.OcrEnabled };
        ocr.Toggled += (_, _) => { store.State.OcrEnabled = ocr.IsOn; Commit(); };
        body.Children.Add(ocr);
        var forgetOcr = new Button { Content = "Forget recognized text and image indexes", IsEnabled = store.Writable && store.State.Items.Any(item => item.Kind == "Image") };
        forgetOcr.Click += async (_, _) => { forgetOcr.IsEnabled = false; await forgetImages(); if (!closed) Render(); }; body.Children.Add(forgetOcr);
        body.Children.Add(Text("OCR uses installed Windows recognition languages. Recognized text is stored with the encrypted clip and participates in search. Protected clips are excluded from OCR and semantic indexing.", theme, 13, true));
    }
}
