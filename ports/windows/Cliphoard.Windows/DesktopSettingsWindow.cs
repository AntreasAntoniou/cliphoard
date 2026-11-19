using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;

internal sealed partial class DesktopSettingsWindow : Window
{
    private readonly HistoryStore store;
    private readonly Action changed, quit, cancelPreparation;
    private readonly AgentWriteController agents;
    private readonly Action<bool> pauseIndexing;
    private bool semanticIndexingPaused;
    private readonly Func<Task> forgetIndexes, forgetImages;
    private readonly Func<Task<bool>> prepareSemantic, prepareImages, prepareSpeech, prepareMedia;
    private readonly Action<bool> suspendCapture;
    private readonly Grid root = new();
    private readonly ScrollViewer scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private string section = "Appearance";
    private bool rebuilding;
    private volatile bool closed;
    private readonly object archivePublishGate = new();
    private readonly CancellationTokenSource settingsLifetime = new();
    private DesktopTheme Theme => DesktopThemes.Resolve(store.State.Theme, IsSystemDark());
    internal DesktopSettingsWindow(HistoryStore store, Action changed, Action quit, Action<bool> suspendCapture, Func<Task<bool>> prepareSemantic, Func<Task<bool>> prepareImages, Func<Task<bool>> prepareSpeech, Func<Task<bool>> prepareMedia, Action<bool> pauseIndexing, Func<Task> forgetIndexes, Func<Task> forgetImages, AgentWriteController agents, Action cancelPreparation, bool welcome = false, string? initialSection = null, bool initiallyPaused = false)
    {
        this.cancelPreparation = cancelPreparation; this.agents = agents; agents.Changed += AgentChanged;
        if (initialSection is not null) section = initialSection;
        this.pauseIndexing = pauseIndexing; this.forgetIndexes = forgetIndexes; this.forgetImages = forgetImages;
        semanticIndexingPaused = initiallyPaused;
        this.suspendCapture = suspendCapture; this.prepareSemantic = prepareSemantic; this.prepareImages = prepareImages; this.prepareSpeech = prepareSpeech; this.prepareMedia = prepareMedia;
        Closed += (_, _) => { agents.Changed -= AgentChanged; lock (archivePublishGate) closed = true; settingsLifetime.Cancel(); this.suspendCapture(false); };
        this.store = store; this.changed = changed; this.quit = quit; Title = "Cliphoard Settings"; Content = root;
        DesktopVisual.FitWindow(this, 920, 740); Render();
        if (welcome) { bool shown = false; root.Loaded += async (_, _) => { if (!shown) { shown = true; await ShowWelcomeAsync(); } }; }
    }
    private static bool IsSystemDark() { var bg = new global::Windows.UI.ViewManagement.UISettings().GetColorValue(global::Windows.UI.ViewManagement.UIColorType.Background); return bg.R + bg.G + bg.B < 384; }
    private void Commit() { if (closed) return; store.Save(); changed(); }
    private void Render(string? focusSection = null)
    {
        rebuilding = true; var t = Theme; SystemBackdrop = t.Material ? new DesktopAcrylicBackdrop() : null; DesktopVisual.StyleWindow(this, t); root.Children.Clear(); root.ColumnDefinitions.Clear(); root.RequestedTheme = t.Dark ? ElementTheme.Dark : ElementTheme.Light; root.Background = Brush(t.Bar); root.ColumnDefinitions.Add(new() { Width = new GridLength(170) }); root.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        var navigation = new StackPanel { Padding = new Thickness(16, 24, 12, 16), Spacing = 6, Background = Alpha(t.Primary, .035) };
        navigation.Children.Add(Text("Cliphoard", t, 19)); navigation.Children.Add(new Border { Height = 18 });
        foreach (string name in new[] { "Appearance", "General", "Search", "Tags", "Privacy", "Backup", "Agent notes", "About" })
        {
            var button = new Button { Content = Text(name, t, 13), HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(12, 9, 12, 9), CornerRadius = new CornerRadius(8), Background = name == section ? Alpha(t.Accent, .16) : Brush("#00000000"), BorderThickness = new Thickness(0) };
            button.Click += (_, _) =>
            {
                section = name;
                scroll.ChangeView(null, 0, null, true);
                Render(name);
            };
            if (name == focusSection)
            {
                button.Loaded += (_, _) => button.Focus(FocusState.Programmatic);
            }
            navigation.Children.Add(button);
        }
        root.Children.Add(new ScrollViewer { Content = navigation, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        var body = new StackPanel { Spacing = 20, Padding = new Thickness(26, 24, 26, 26), HorizontalAlignment = HorizontalAlignment.Stretch }; body.Children.Add(Text(section, t, 24));
        if (section == "Appearance") Appearance(body, t); else if (section == "General") General(body, t); else if (section == "Search") Search(body, t); else if (section == "Tags") Tags(body, t); else if (section == "Privacy") Privacy(body, t); else if (section == "Agent notes") AgentNotes(body, t); else if (section == "About") About(body, t); else Backup(body, t);
        scroll.Content = body; Grid.SetColumn(scroll, 1); root.Children.Add(scroll);
        if (AppWindow.TitleBar is { } title) { title.BackgroundColor = Color(t.Bar); title.ForegroundColor = Color(t.Primary); title.ButtonBackgroundColor = Color(t.Bar); title.ButtonForegroundColor = Color(t.Primary); }
        rebuilding = false;
    }
    private void Appearance(StackPanel body, DesktopTheme t)
    {
        var theme = new ComboBox { Header = "Theme", ItemsSource = DesktopThemes.All, SelectedItem = DesktopThemes.All.First(i => i.Id == store.State.Theme), HorizontalAlignment = HorizontalAlignment.Stretch };
        theme.SelectionChanged += (_, _) => { if (rebuilding || theme.SelectedItem is not DesktopTheme chosen) return; store.State.Theme = chosen.Id; Commit(); Render(); }; body.Children.Add(theme);
        var gallery = new Grid { ColumnSpacing = 10, RowSpacing = 10 };
        for (int i = 0; i < 3; ++i) gallery.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        for (int i = 0; i < 6; ++i) gallery.RowDefinitions.Add(new() { Height = new GridLength(106) });
        int index = 0;
        foreach (DesktopTheme option in DesktopThemes.All)
        {
            DesktopTheme palette = DesktopThemes.Resolve(option.Id, IsSystemDark()); bool active = option.Id == store.State.Theme;
            var preview = new Grid { RowSpacing = 7, Padding = new Thickness(9), Background = Brush(palette.Bar), CornerRadius = new CornerRadius(8) }; preview.RowDefinitions.Add(new() { Height = new GridLength(14) }); preview.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); preview.RowDefinitions.Add(new() { Height = GridLength.Auto });
            var bar = new Border { Height = 9, CornerRadius = new CornerRadius(5), BorderThickness = new Thickness(1), BorderBrush = Alpha(palette.Accent, .5), Background = Alpha(palette.Primary, .03) }; preview.Children.Add(bar);
            var samples = new Grid { ColumnSpacing = 6 }; for (int i = 0; i < 3; ++i) { samples.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); var card = new Border { Background = Brush(palette.Card), BorderBrush = i == 0 ? Brush(palette.Accent) : Brush(palette.Border), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(3), Child = new Border { Background = Alpha(palette.Primary, .2), Height = 2, Margin = new Thickness(5, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center } }; Grid.SetColumn(card, i); samples.Children.Add(card); } Grid.SetRow(samples, 1); preview.Children.Add(samples);
            var label = Text(option.Id == "system" ? "Automatic" : option.Title, palette, 10); label.MaxLines = 1; label.TextTrimming = TextTrimming.CharacterEllipsis; Grid.SetRow(label, 2); preview.Children.Add(label);
            var button = new Button { Content = preview, Padding = new Thickness(2), BorderThickness = new Thickness(active ? 2 : 1), BorderBrush = active ? Brush(t.Accent) : Brush(t.Border), Background = Brush(palette.Bar), CornerRadius = new CornerRadius(10), HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
            ToolTipService.SetToolTip(button, option.Title); Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, option.Title + (active ? ", selected" : "")); button.Click += (_, _) => { store.State.Theme = option.Id; Commit(); Render(); }; Grid.SetRow(button, index / 3); Grid.SetColumn(button, index % 3); gallery.Children.Add(button); ++index;
        }
        body.Children.Add(gallery);
        body.Children.Add(Text("Layout", t, 15));
        var layouts = new Grid { ColumnSpacing = 10 };
        string[] keys = { "strip", "spotlight", "list" };
        for (int i = 0; i < 3; ++i)
        {
            int chosen = i; layouts.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            var content = new StackPanel { Spacing = 8 }; content.Children.Add(Icon(i == 0 ? "\uF0E2" : i == 1 ? "\uE8A9" : "\uE8FD", t.Accent, 22)); var title = Text(DesktopThemes.Layouts[i], t, 11); title.TextAlignment = TextAlignment.Center; content.Children.Add(title);
            var button = new Button { Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center, Padding = new Thickness(10, 14, 10, 14), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), BorderBrush = store.State.Layout == keys[i] ? Brush(t.Accent) : Brush(t.Border), Background = store.State.Layout == keys[i] ? Alpha(t.Accent, .12) : Brush(t.Card) };
            button.Click += (_, _) => { store.State.Layout = keys[chosen]; Commit(); Render(); }; Grid.SetColumn(button, i); layouts.Children.Add(button);
        }
        body.Children.Add(layouts);
        var heightLabel = Text($"Bar height   {store.State.PreviewHeight * 100 / 250}%", t, 13); body.Children.Add(heightLabel);
        var slider = new Slider { Minimum = 200, Maximum = 400, StepFrequency = 10, SmallChange = 10, LargeChange = 50, Value = store.State.PreviewHeight }; Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(slider, "Bar height");
        slider.ValueChanged += (_, _) => { if (rebuilding) return; store.State.PreviewHeight = DesktopThemes.Height((int)slider.Value); heightLabel.Text = $"Bar height   {store.State.PreviewHeight * 100 / 250}%"; Commit(); }; body.Children.Add(slider);
        var reset = new Button { Content = "Reset height", HorizontalAlignment = HorizontalAlignment.Left }; reset.Click += (_, _) => slider.Value = 250; body.Children.Add(reset);
        body.Children.Add(Text("Resize clip previews and results. Controls keep their normal size. Changes apply immediately and are saved.", t, 11, true));
    }
    private void General(StackPanel body, DesktopTheme t)
    {
        var startup = new ToggleSwitch { Header = "Launch at login", IsOn = DesktopStartup.Enabled };
        var startupStatus = Text("Start quietly in the Windows tray when you sign in.", t, 11, true);
        startup.Toggled += (_, _) => { if (rebuilding) return; try { DesktopStartup.SetEnabled(startup.IsOn); startupStatus.Text = "Saved. Changes apply at the next Windows sign-in."; } catch { startupStatus.Text = "The startup setting could not be changed. Another installation may own it."; rebuilding = true; startup.IsOn = DesktopStartup.Enabled; rebuilding = false; } };
        body.Children.Add(startup); body.Children.Add(startupStatus);
        var sound = new ToggleSwitch { Header = "Play sound on copy", IsOn = store.State.SoundEnabled };
        sound.Toggled += (_, _) => { if (rebuilding) return; store.State.SoundEnabled = sound.IsOn; Commit(); }; body.Children.Add(sound);
        var soundChoice = new ComboBox { Header = "Copy sound", ItemsSource = HistoryState.CaptureSounds.ToArray(), DisplayMemberPath = "Value", SelectedValuePath = "Key", SelectedValue = store.State.SoundName, HorizontalAlignment = HorizontalAlignment.Stretch };
        soundChoice.SelectionChanged += (_, _) => { if (rebuilding || soundChoice.SelectedValue is not string name) return; store.State.SoundName = name; Commit(); }; body.Children.Add(soundChoice);
        var previewSound = new Button { Content = "Preview sound" }; previewSound.Click += (_, _) => HistoryWindow.PreviewCaptureSound(store.State.SoundName); body.Children.Add(previewSound);
        var focusSearch = new ToggleSwitch { Header = "Focus search when opened", IsOn = store.State.TakeFocusOnSummon };
        focusSearch.Toggled += (_, _) => { if (rebuilding) return; store.State.TakeFocusOnSummon = focusSearch.IsOn; Commit(); }; body.Children.Add(focusSearch);
        var pause = new ToggleSwitch { Header = "Pause clipboard capture", IsOn = store.State.Paused }; pause.Toggled += (_, _) => { if (rebuilding) return; store.State.Paused = pause.IsOn; Commit(); }; body.Children.Add(pause);
        var limit = new ComboBox { Header = "History size", ItemsSource = new[] { "100", "200", "500", "1000", "5000", "Unlimited" }, SelectedItem = store.State.Limit == 0 ? "Unlimited" : store.State.Limit.ToString(), HorizontalAlignment = HorizontalAlignment.Stretch }; limit.SelectionChanged += (_, _) => { if (rebuilding || limit.SelectedItem is not string choice) return; store.State.Limit = choice == "Unlimited" ? 0 : int.Parse(choice); store.Trim(); Commit(); }; body.Children.Add(limit);
        body.Children.Add(Text("Shortcuts", t, 15)); body.Children.Add(Text("Ctrl+Alt+Shift+B  Open / close\nEnter  Paste · Shift+Enter  Paste plain text\nCtrl+C  Copy · Ctrl+1–9  Quick paste\nCtrl+Enter  Inspect · Ctrl+P  Pin\nCtrl+Backspace  Delete · Ctrl+,  Settings\nEsc  Close · Ctrl+Q  Quit", t, 12, true));
        var clear = new Button { Content = "Clear unpinned history…" }; clear.Click += async (_, _) =>
        {
            var confirmation = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.RequestedTheme, Background = Brush(t.Card), Foreground = Brush(t.Primary), Title = "Clear unpinned history?", Content = "Pinned clips will stay. This cannot be undone.", PrimaryButtonText = "Clear history", CloseButtonText = "Cancel" };
            if (await confirmation.ShowAsync() == ContentDialogResult.Primary && !closed) { store.State.Items.RemoveAll(i => !i.Pinned); Commit(); }
        }; body.Children.Add(clear);
        var logging = new ToggleSwitch { Header = "Debug logging", IsOn = store.State.DebugLogging };
        logging.Toggled += (_, _) => { if (rebuilding) return; store.State.DebugLogging = logging.IsOn; Commit(); }; body.Children.Add(logging);
        body.Children.Add(Text("Keeps the latest 256 event names and UTC times encrypted on this account.", t, 12, true));
        var diagnostics = new Button { Content = "View diagnostic log" };
        diagnostics.Click += async (_, _) =>
        {
            string entries = string.Join("\n", store.State.Diagnostics.Select(entry => DateTimeOffset.FromUnixTimeSeconds(entry.At).ToString("u") + "  " + entry.Event));
            var log = new TextBox { Text = entries.Length == 0 ? "No diagnostic events recorded." : entries, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 160, MaxHeight = 350 };
            await new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.RequestedTheme, Title = "Diagnostic log", Content = log, CloseButtonText = "Done" }.ShowAsync();
        }; body.Children.Add(diagnostics);
        var exit = new Button { Content = "Quit Cliphoard" }; exit.Click += (_, _) => quit(); body.Children.Add(exit);
    }
    private void Privacy(StackPanel body, DesktopTheme t)
    {
        body.Children.Add(Text("Local to this Windows account", t, 16)); body.Children.Add(Text("History is encrypted on this device. Nothing is uploaded. Capture stops while Windows is locked or disconnected. Apps can mark copied content as excluded from history.", t, 13, true));
        var nsfw = new ToggleSwitch { Header = "Conceal possible explicit content", IsOn = store.State.NsfwEnabled };
        nsfw.Toggled += (_, _) => { if (rebuilding) return; store.State.NsfwEnabled = nsfw.IsOn; Commit(); }; body.Children.Add(nsfw);
        var focus = new ToggleSwitch { Header = "Apply explicit-content protection during Focus sessions", IsOn = store.State.NsfwFocusOnly };
        focus.Toggled += (_, _) => { if (rebuilding) return; store.State.NsfwFocusOnly = focus.IsOn; Commit(); }; body.Children.Add(focus);
        var screenText = new ToggleSwitch { Header = "Screen text with the local MiniLM model", IsOn = store.State.NsfwText };
        screenText.Toggled += (_, _) => { if (rebuilding) return; store.State.NsfwText = screenText.IsOn; Commit(); }; body.Children.Add(screenText);
        var screenImages = new ToggleSwitch { Header = "Screen images with the local OpenVision model", IsOn = store.State.NsfwImages };
        screenImages.Toggled += (_, _) => { if (rebuilding) return; store.State.NsfwImages = screenImages.IsOn; Commit(); }; body.Children.Add(screenImages);
        var screenAudio = new ToggleSwitch { Header = "Screen indexed audio locally with Gemma", IsOn = store.State.NsfwAudio };
        screenAudio.Toggled += (_, _) => { if (rebuilding) return; store.State.NsfwAudio = screenAudio.IsOn; Commit(); }; body.Children.Add(screenAudio);
        var screenVideo = new ToggleSwitch { Header = "Screen indexed video frames locally with Gemma", IsOn = store.State.NsfwVideo };
        screenVideo.Toggled += (_, _) => { if (rebuilding) return; store.State.NsfwVideo = screenVideo.IsOn; Commit(); }; body.Children.Add(screenVideo);
        body.Children.Add(Text("Possible matches require Windows Hello. The nsfw-exempt user label exempts explicit-content screening. Sensitive credentials keep their protection. Unknown Focus state keeps conditional protection active.", t, 12, true));
        body.Children.Add(Text("Excluded apps", t, 16));
        var excluded = new TextBox { Text = string.Join("\n", store.State.ExcludedApps), AcceptsReturn = true, Height = 100, PlaceholderText = "One process name per line, e.g. notepad.exe" }; body.Children.Add(excluded);
        var saved = Text("Password-manager processes and private clipboard formats are excluded automatically.", t, 11, true);
        var apply = new Button { Content = "Save exclusions" }; apply.Click += (_, _) => { var names = excluded.Text.Split(new[] { '\r', '\n', ',' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries); if (names.Length > 100 || names.Any(name => name.Length > 200 || name.IndexOfAny(new[] { '\\', '/', ':' }) >= 0)) { saved.Text = "Use up to 100 process names, without paths."; return; } store.State.ExcludedApps = names.Distinct(StringComparer.OrdinalIgnoreCase).ToList(); Commit(); saved.Text = "Saved. Exclusions apply to future copies; saved history is unchanged."; }; body.Children.Add(apply); body.Children.Add(saved);
        body.Children.Add(Text("Capture limits", t, 16)); body.Children.Add(Text("Text up to 65,536 characters; bitmap images up to 8 MB; file lists up to 32 paths. Unsupported or oversized formats are skipped. Optional document extraction reads supported local files in an isolated, time- and memory-bounded worker. Snapshots are encrypted with history.", t, 12, true));
    }
}
