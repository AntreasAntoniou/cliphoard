using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;
internal sealed partial class DesktopSettingsWindow
{
    private void MediaSearchSettings(StackPanel body, DesktopTheme theme)
    {
        body.Children.Add(Text("Pictures, audio and video", theme, 17));
        var modality = new ComboBox { Header = "Search in", ItemsSource = new[] { "Text", "Images", "Audio", "Video", "All" }, SelectedIndex = Array.IndexOf(new[] { "text", "images", "audio", "video", "all" }, store.State.SearchMode == "image" ? "images" : store.State.SearchModality), HorizontalAlignment = HorizontalAlignment.Stretch };
        modality.SelectionChanged += (_, _) => { if (rebuilding || modality.SelectedIndex < 0) return; store.State.SearchModality = new[] { "text", "images", "audio", "video", "all" }[modality.SelectedIndex]; if (store.State.SearchMode == "image") store.State.SearchMode = "smart"; Commit(); }; body.Children.Add(modality);
        void Capability(string title, bool enabled, Action<bool> change)
        {
            var toggle = new ToggleSwitch { Header = title, IsOn = enabled };
            toggle.Toggled += (_, _) => { if (rebuilding) return; change(toggle.IsOn); Commit(); }; body.Children.Add(toggle);
        }
        Capability("Include text in All", store.State.SearchTextEnabled, value => store.State.SearchTextEnabled = value);
        Capability("Include pictures in All", store.State.SearchImagesEnabled, value => store.State.SearchImagesEnabled = value);
        Capability("Include audio in All", store.State.SearchAudioEnabled, value => store.State.SearchAudioEnabled = value);
        Capability("Include video in All", store.State.SearchVideoEnabled, value => store.State.SearchVideoEnabled = value);
        var preset = new ComboBox { Header = "Media sampling", ItemsSource = new[] { "Lightweight", "Balanced", "Detailed" }, SelectedIndex = store.State.MediaPreset switch { "lightweight" => 0, "detailed" => 2, _ => 1 }, HorizontalAlignment = HorizontalAlignment.Stretch };
        preset.SelectionChanged += (_, _) => { if (rebuilding || preset.SelectedIndex < 0) return; store.State.MediaPreset = new[] { "lightweight", "balanced", "detailed" }[preset.SelectedIndex]; Commit(); }; body.Children.Add(preset);
        var coverage = new ComboBox { Header = "Speech coverage", ItemsSource = new[] { "Sounds only", "Speech in sampled moments", "Every spoken passage · up to one hour" }, SelectedIndex = store.State.MediaSpeechCoverage switch { "off" => 0, "full" => 2, _ => 1 }, HorizontalAlignment = HorizontalAlignment.Stretch };
        coverage.SelectionChanged += (_, _) => { if (rebuilding || coverage.SelectedIndex < 0) return; store.State.MediaSpeechCoverage = new[] { "off", "sampled", "full" }[coverage.SelectedIndex]; Commit(); }; body.Children.Add(coverage);
        body.Children.Add(Text("Choose files from the bar’s search menu or index a copied file from its context menu. Up to 120 sampling windows span each file. Full speech covers every thirty-second window for files up to one hour. Changing sampling or speech settings requires reindexing selected files. Windows decodes installed local media formats. Extracted frames and audio stay in memory; derived indexes are encrypted.", theme, 12, true));
        var prepare = new Button { Content = "Download and prepare media search" };
        prepare.Click += async (_, _) => { prepare.IsEnabled = false; bool ready = await RunPreparationAsync(prepareMedia); if (closed) return; prepare.Content = ready ? "Media model is ready offline" : "Retry media preparation"; prepare.IsEnabled = !ready; }; body.Children.Add(prepare);
    }
}
