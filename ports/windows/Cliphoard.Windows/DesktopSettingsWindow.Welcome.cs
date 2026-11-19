using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;
internal sealed partial class DesktopSettingsWindow
{
    private async Task ShowWelcomeAsync()
    {
        if (closed) return;
        string originalModel = store.State.SemanticModel, originalImage = store.State.ImageModel;
        int originalLimit = store.State.Limit;
        string originalPreset = store.State.MediaPreset, originalSpeech = store.State.MediaSpeechCoverage;
        bool originalAudio = store.State.SearchAudioEnabled, originalVideo = store.State.SearchVideoEnabled;
        string draftPreset = originalPreset, draftSpeech = originalSpeech;
        bool draftAudio = originalAudio, draftVideo = originalVideo;
        string draftModel = originalModel, draftImage = originalImage;
        int draftLimit = originalLimit;
        var originalTags = store.State.TagOverlays.ToHashSet(StringComparer.Ordinal);
        var draftTags = originalTags.ToHashSet(StringComparer.Ordinal);
        int step = 0, confirmedRemoval = -1;
        var theme = Theme;
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.RequestedTheme, Background = Brush(theme.Card), Foreground = Brush(theme.Primary), CloseButtonText = "Later", DefaultButton = ContentDialogButton.Primary, MaxWidth = 680 };
        void RenderStep()
        {
            dialog.Title = new[] { "Welcome to Cliphoard", "Choose automatic categories", "On-device text search", "Find pictures", "Find audio and video", "Choose how much to keep", "Your Pro licence", "Review your choices" }[step];
            dialog.PrimaryButtonText = step == 7 ? "Finish" : "Next"; dialog.SecondaryButtonText = step == 0 ? "" : "Back";
            var body = new StackPanel { Spacing = 14 };
            switch (step)
            {
                case 0:
                    body.Children.Add(Text("Copy in any Windows app, then press Ctrl+Alt+Shift+B to open your history. Search, select a card and press Enter to paste. Shift+Enter pastes plain text. Ctrl+C copies without pasting.", theme, 14));
                    body.Children.Add(Text("History stays encrypted in your Windows account. Capture stops while the session is locked or disconnected. Protected content requires Windows Hello.", theme, 13, true));
                    break;
                case 1:
                    body.Children.Add(Text("General uses factual chips. Add specialist vocabularies for categories from your local model.", theme, 13, true));
                    foreach (TagBasket basket in TagCatalog.BuiltIn.Where(basket => basket.Id != "general"))
                    {
                        var choice = new CheckBox { Content = basket.Name, IsChecked = draftTags.Contains(basket.Id) };
                        choice.Click += (_, _) => { if (choice.IsChecked == true) draftTags.Add(basket.Id); else draftTags.Remove(basket.Id); }; body.Children.Add(choice);
                    }
                    break;
                case 2:
                    var model = new ComboBox { Header = "Text model", ItemsSource = ModelCatalog.Text.Select(entry => entry.Title).ToArray(), SelectedIndex = Array.FindIndex(ModelCatalog.Text, entry => entry.Id == draftModel), HorizontalAlignment = HorizontalAlignment.Stretch };
                    model.SelectionChanged += (_, _) => { if (model.SelectedIndex >= 0) draftModel = ModelCatalog.Text[model.SelectedIndex].Id; }; body.Children.Add(model);
                    body.Children.Add(Text("Basic matching works immediately. Other models need an explicit download in Search settings. You can choose Exact, Tags, Neural or Smart search.", theme, 13, true));
                    break;
                case 3:
                    var images = new ComboBox { Header = "Image model", ItemsSource = new[] { "OpenVision Tiny", "EmbeddingGemma 2" }, SelectedIndex = draftImage == "embeddinggemma-2-740m" ? 1 : 0, HorizontalAlignment = HorizontalAlignment.Stretch };
                    images.SelectionChanged += (_, _) => draftImage = images.SelectedIndex == 1 ? "embeddinggemma-2-740m" : "openvision-tiny-p8"; body.Children.Add(images);
                    body.Children.Add(Text("Search image content with words or a reference image. A card’s context menu also finds visually similar images. Model downloads are available in Search settings.", theme, 13, true));
                    break;
                case 4:
                    var audio = new CheckBox { Content = "Include audio when searching All", IsChecked = draftAudio };
                    audio.Click += (_, _) => draftAudio = audio.IsChecked == true; body.Children.Add(audio);
                    var video = new CheckBox { Content = "Include video when searching All", IsChecked = draftVideo };
                    video.Click += (_, _) => draftVideo = video.IsChecked == true; body.Children.Add(video);
                    var sampling = new ComboBox { Header = "Sampling", ItemsSource = new[] { "Lightweight", "Balanced", "Detailed" }, SelectedIndex = Array.IndexOf(new[] { "lightweight", "balanced", "detailed" }, draftPreset), HorizontalAlignment = HorizontalAlignment.Stretch };
                    sampling.SelectionChanged += (_, _) => { if (sampling.SelectedIndex >= 0) draftPreset = new[] { "lightweight", "balanced", "detailed" }[sampling.SelectedIndex]; }; body.Children.Add(sampling);
                    var coverage = new ComboBox { Header = "Speech", ItemsSource = new[] { "Sounds only", "Speech in sampled moments", "Every spoken passage" }, SelectedIndex = Array.IndexOf(new[] { "off", "sampled", "full" }, draftSpeech), HorizontalAlignment = HorizontalAlignment.Stretch };
                    coverage.SelectionChanged += (_, _) => { if (coverage.SelectedIndex >= 0) draftSpeech = new[] { "off", "sampled", "full" }[coverage.SelectedIndex]; }; body.Children.Add(coverage);
                    body.Children.Add(Text("Choose local files explicitly from the search menu. Gemma finds frames and sounds. Whisper adds speech. Full speech covers files up to one hour. Prepare the selected models in Search settings.", theme, 13, true));
                    break;
                case 6:
                    body.Children.Add(Text(OfflineLicence.Verify(store.State.LicenceKey).Pro ? "Your Pro licence is verified offline." : "You can add a signed Cliphoard Pro licence from About in Settings. Verification works offline.", theme, 14));
                    body.Children.Add(Text("Model downloads start when you choose Download in Search settings.", theme, 13, true));
                    break;
                case 5:
                    int[] limits = { 100, 200, 500, 1000, 5000, 0 };
                    var history = new ComboBox { Header = "Unpinned clips to retain", ItemsSource = limits.Select(value => value == 0 ? "Unlimited" : value.ToString()).ToArray(), SelectedIndex = Array.IndexOf(limits, draftLimit), HorizontalAlignment = HorizontalAlignment.Stretch };
                    history.SelectionChanged += (_, _) => { if (history.SelectedIndex >= 0) { draftLimit = limits[history.SelectedIndex]; confirmedRemoval = -1; } }; body.Children.Add(history);
                    body.Children.Add(Text("Pinned clips stay until you remove them. Unlimited history grows on disk as you copy. Encrypted backups can move your clips between Windows and Mac.", theme, 13, true));
                    break;
                case 7:
                    body.Children.Add(Text($"Text model · {ModelCatalog.Text.First(entry => entry.Id == draftModel).Title}\nImage model · {(draftImage == "embeddinggemma-2-740m" ? "EmbeddingGemma 2" : "OpenVision Tiny")}\nSpecialist vocabularies · {draftTags.Count}\nAudio in All · {(draftAudio ? "On" : "Off")} · Video in All · {(draftVideo ? "On" : "Off")}\nMedia · {draftPreset} sampling · {draftSpeech} speech\nHistory · {(draftLimit == 0 ? "Unlimited" : draftLimit.ToString())} unpinned clips", theme, 14));
                    body.Children.Add(Text("Finish saves the choices you changed. Downloads start from the explicit buttons in Search settings.", theme, 13, true));
                    break;
            }
            dialog.Content = new ScrollViewer { Content = body, MaxHeight = 460, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        }
        dialog.SecondaryButtonClick += (_, args) => { args.Cancel = true; --step; confirmedRemoval = -1; RenderStep(); };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (step < 7) { args.Cancel = true; ++step; RenderStep(); return; }
            int remove = draftLimit == originalLimit || draftLimit == 0 ? 0 : Math.Max(0, store.State.Items.Count(item => !item.Pinned) - draftLimit);
            if (remove > 0 && confirmedRemoval != remove)
            {
                args.Cancel = true; confirmedRemoval = remove;
                var panel = (StackPanel)((ScrollViewer)dialog.Content).Content;
                panel.Children.Add(Text($"This choice removes {remove} older unpinned clips. Export a backup first if you need them.", theme, 13));
                dialog.PrimaryButtonText = $"Remove {remove} and finish"; dialog.DefaultButton = ContentDialogButton.Close; return;
            }
            if (draftModel != originalModel) store.State.SemanticModel = draftModel;
            if (draftImage != originalImage) store.State.ImageModel = draftImage;
            if (!draftTags.SetEquals(originalTags)) store.State.TagOverlays = draftTags.Order(StringComparer.Ordinal).ToList();
            if (draftLimit != originalLimit) { store.State.Limit = draftLimit; store.Trim(); }
            if (draftPreset != originalPreset) store.State.MediaPreset = draftPreset;
            if (draftSpeech != originalSpeech) store.State.MediaSpeechCoverage = draftSpeech;
            if (draftAudio != originalAudio) store.State.SearchAudioEnabled = draftAudio;
            if (draftVideo != originalVideo) store.State.SearchVideoEnabled = draftVideo;
            store.State.OnboardingCompleted = true; Commit();
        };
        RenderStep(); await dialog.ShowAsync();
    }
}
