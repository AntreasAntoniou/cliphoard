using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;
using Windows.UI.ViewManagement;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;

internal sealed partial class HistoryWindow
{
    private readonly Grid root = new(), results = new();
    private readonly TextBox search = new() { PlaceholderText = "Search clips…", MaxLength = 512, IsSpellCheckEnabled = false, IsTextPredictionEnabled = false, MinWidth = 80, FontSize = 13, BorderThickness = new Thickness(0), Background = Brush("#00000000"), Padding = new Thickness(0, 7, 0, 7) };
    private readonly StackPanel cards = new() { Spacing = 14 };
    private readonly ScrollViewer scroller = new();
    private readonly Border previewHost = new(), notice = new();
    private readonly TextBlock count = new();
    private readonly List<HistoryItem> shown = new();
    private readonly List<Border> tiles = new();
    private int selected;
    private string filter = "All", timeFilter = "Any time";
    private bool pinnedOnly, chromeReady;
    private Grid? header, searchContainer, footerContainer;
    private Border? footer;
    private void AppearanceChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (closing) return;
        tray?.RefreshTheme();
        if (store.State.Theme == "system" && !locked) ApplyAppearance();
    });
    private void ApplyAppearance()
    {
        var t = Theme;
        root.RequestedTheme = t.Dark ? ElementTheme.Dark : ElementTheme.Light;
        root.Background = Brush(t.Bar);
        SystemBackdrop = t.Material ? new DesktopAcrylicBackdrop() : null;
        DesktopVisual.StyleWindow(this, t, borderless: true);
        root.Resources["SystemAccentColor"] = Color(t.Accent);
        root.Resources["TextControlBackground"] = Brush("#00000000");
        root.Resources["TextControlBackgroundFocused"] = Brush("#00000000");
        BuildChrome(); Refresh(); PositionPanel();
    }
    private void BuildChrome()
    {
        bool restoreSearchFocus = search.FocusState != FocusState.Unfocused;
        var t = Theme;
        if (!chromeReady)
        {
            foreach (GridLength height in new[] { new GridLength(56), GridLength.Auto, new GridLength(1, GridUnitType.Star), new GridLength(34) }) root.RowDefinitions.Add(new() { Height = height });
            root.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(Key), true);
            search.Resources["TextControlBorderBrushFocused"] = Brush("#00000000");
            search.Resources["TextControlBorderThicknessFocused"] = new Thickness(0);
            InitializeSearchInput();
            search.TextChanged += (_, _) => SearchDraftChanged();
            search.GotFocus += (_, _) => { if (search.Parent is Grid grid && grid.Parent is Border pill) pill.BorderBrush = Alpha(Theme.Accent, .8); };
            search.LostFocus += (_, _) => { if (search.Parent is Grid grid && grid.Parent is Border pill) pill.BorderBrush = Alpha(Theme.Accent, .3); };
            Grid.SetRow(results, 2); root.Children.Add(results);
            notice.Padding = new Thickness(16, 7, 16, 7); notice.Visibility = Visibility.Collapsed; Grid.SetRow(notice, 1); root.Children.Add(notice);
            chromeReady = true;
        }
        searchContainer?.Children.Remove(search);
        footerContainer?.Children.Remove(count);
        if (header is not null) root.Children.Remove(header);
        if (footer is not null) root.Children.Remove(footer);
        header = new Grid { Padding = new Thickness(16, 8, 16, 8), ColumnSpacing = 10, BorderBrush = Alpha(t.Primary, .12), BorderThickness = new Thickness(0, 0, 0, 1) };
        foreach (GridLength width in new[] { new GridLength(32), new GridLength(1, GridUnitType.Star), new GridLength(36), new GridLength(36) }) header.ColumnDefinitions.Add(new() { Width = width });
        var logo = new Image { Width = 32, Height = 36, Stretch = Stretch.Uniform }; header.Children.Add(logo); _ = LoadBrand(logo);
        var query = new Grid { ColumnSpacing = 8, Padding = new Thickness(12, 0, 6, 0) };
        searchContainer = query;
        foreach (GridLength width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto, GridLength.Auto }) query.ColumnDefinitions.Add(new() { Width = width });
        query.Children.Add(Icon("\uE721", t.Muted, 13)); search.Foreground = Brush(t.Primary); search.FontFamily = new FontFamily(t.Font); Grid.SetColumn(search, 1); query.Children.Add(search);
        string modeLabel = store.State.SearchMode switch { "neural" or "essence" => "Neural", "smart" => "Smart", "tag" => "Tags", "image" => "Image", _ => "Exact" };
        if (EffectiveModality != "text") modeLabel = EffectiveModality == "all" ? "All · " + modeLabel : char.ToUpperInvariant(EffectiveModality[0]) + EffectiveModality[1..];
        var mode = new Button { Content = Text(modeLabel, t, 11, true), Padding = new Thickness(5, 0, 5, 0), Background = Brush("#00000000"), BorderThickness = new Thickness(0) };
        mode.Click += (_, _) => ShowSearchModes(mode); Grid.SetColumn(mode, 2); query.Children.Add(mode);
        var divider = new Border { Width = 1, Height = 18, Background = Alpha(t.Primary, .13) }; Grid.SetColumn(divider, 3); query.Children.Add(divider);
        var filterButton = new Button { Padding = new Thickness(8, 0, 6, 0), Height = 32, Background = Brush("#00000000"), BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(12) };
        var filterLabel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
        bool active = filter != "All" || pinnedOnly || facetFilters.Count > 0 || timeFilter != "Any time" || userTagFilters.Count > 0;
        filterLabel.Children.Add(Icon("\uE71C", active ? t.Accent : t.Muted, 12)); filterLabel.Children.Add(Text("Filters" + (active ? " •" : ""), t, 11, !active)); filterButton.Content = filterLabel;
        filterButton.Click += (_, _) => ShowFilters(filterButton); Grid.SetColumn(filterButton, 4); query.Children.Add(filterButton);
        var capsule = new Border { Child = query, Height = 38, CornerRadius = new CornerRadius(19), BorderThickness = new Thickness(1), BorderBrush = Alpha(t.Accent, .4), Background = Alpha(t.Primary, .02) }; Grid.SetColumn(capsule, 1); header.Children.Add(capsule);
        var pauseButton = IconButton(store.State.Paused ? "\uE768" : "\uE769", store.State.Paused ? "Resume capture" : "Pause capture", t, TogglePause, 13); Grid.SetColumn(pauseButton, 2); header.Children.Add(pauseButton);
        var gear = IconButton("\uE713", "Settings · Ctrl+,", t, ShowSettings, 17); Grid.SetColumn(gear, 3); header.Children.Add(gear); root.Children.Add(header);
        footer = new Border { Background = Alpha(t.Primary, .04), Padding = new Thickness(16, 4, 16, 4) };
        var bottom = new Grid(); footerContainer = bottom; bottom.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); bottom.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var hints = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
        foreach (var hint in new[] { (store.State.Layout == "strip" ? "← →" : "↑ ↓", "Navigate"), ("↵", "Paste"), ("Ctrl C", "Copy"), ("esc", "Close") })
        {
            var pair = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
            pair.Children.Add(new Border { Child = Text(hint.Item1, t, 10), Background = Alpha(t.Primary, .10), CornerRadius = new CornerRadius(4), Padding = new Thickness(5, 2, 5, 2) }); pair.Children.Add(Text(hint.Item2, t, 10, true)); hints.Children.Add(pair);
        }
        var shortcuts = new Button { Content = Text("ⓘ  Shortcuts", t, 10, true), Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Brush("#00000000") };
        var shortcutMenu = new MenuFlyout(); foreach (string hint in new[] { "Ctrl+1–9     Quick paste", "Shift+Enter     Paste plain text", "Ctrl+P     Pin", "Ctrl+Backspace     Delete", "Ctrl+Enter     Inspect", "Ctrl+,     Settings", "Ctrl+Q     Quit" }) shortcutMenu.Items.Add(new MenuFlyoutItem { Text = hint, IsEnabled = false }); shortcuts.Flyout = shortcutMenu; hints.Children.Add(shortcuts);
        var agentButton = new Button { Content = Text(agents.Pending.Count > 0 ? $"Review {agents.Pending.Count} agent notes" : agents.Connected ? "Agent connected" : "Agent notes", t, 10, true), Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Brush("#00000000") };
        agentButton.Click += (_, _) => ShowAgentSettings(); hints.Children.Add(agentButton);
        bottom.Children.Add(hints); count.FontSize = 11; count.Foreground = Brush(t.Muted); count.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(count, 1); bottom.Children.Add(count); footer.Child = bottom; Grid.SetRow(footer, 3); root.Children.Add(footer);
        if (restoreSearchFocus && !locked && !closing && Native.GetForegroundWindow() == hwnd)
            search.Focus(FocusState.Programmatic);
    }
    private void ShowFilters(Button button)
    {
        var menu = new MenuFlyout();
        var kinds = new MenuFlyoutSubItem { Text = "Clip type" };
        foreach (string kind in new[] { "All", "Text", "Link", "Code", "Color", "Image", "Files" })
        {
            var option = new ToggleMenuFlyoutItem { Text = kind == "All" ? "All types" : kind, IsChecked = filter == kind }; option.Click += (_, _) => { ++epoch; filter = kind; selected = -1; BuildChrome(); Refresh(); scroller.ChangeView(0, 0, null, true); }; kinds.Items.Add(option);
        }
        menu.Items.Add(kinds);
        var pinned = new ToggleMenuFlyoutItem { Text = "Pinned only", IsChecked = pinnedOnly }; pinned.Click += (_, _) => { ++epoch; pinnedOnly = !pinnedOnly; selected = -1; BuildChrome(); Refresh(); }; menu.Items.Add(pinned);
        var times = new MenuFlyoutSubItem { Text = "Time" };
        foreach (string time in new[] { "Any time", "Today", "Yesterday", "This week", "This month", "Last 7 days", "Last 30 days" }) { var option = new ToggleMenuFlyoutItem { Text = time, IsChecked = timeFilter == time }; option.Click += (_, _) => { ++epoch; timeFilter = time; selected = -1; BuildChrome(); Refresh(); }; times.Items.Add(option); }
        var range = new MenuFlyoutItem { Text = "Custom range…" }; range.Click += async (_, _) => await ChooseTimeRangeAsync(); times.Items.Add(range); menu.Items.Add(times);
        AddFacetMenus(menu);
        menu.Items.Add(new MenuFlyoutSeparator()); var clear = new MenuFlyoutItem { Text = "Clear filters" }; clear.Click += (_, _) => { ++epoch; filter = "All"; pinnedOnly = false; facetFilters.Clear(); userTagFilters.Clear(); timeFilter = "Any time"; selected = -1; BuildChrome(); Refresh(); }; menu.Items.Add(clear); menu.ShowAt(button);
    }
    private bool MatchesTime(HistoryItem item)
    {
        TimeScope scope = TimeQuery.Parse(searchInput.Submitted).Scope ?? (timeFilter == "Custom range" && customTime is not null ? customTime : new(timeFilter));
        return scope.Contains(item.Captured, DateTimeOffset.Now);
    }
    private void Refresh()
    {
        if (locked) return;
        UpdateAnalysisPolicy();
        if (!searchInput.Pending)
        {
            ScheduleMultimodalSearch();
            ScheduleSemanticSearch();
        }
        string? selection = selected >= 0 && selected < shown.Count ? shown[selected].Id : null;
        HistoryItem[] scope = store.State.Items.Where(i => (filter == "All" || i.Kind == filter) && (!pinnedOnly || i.Pinned) && MatchesTime(i) && MatchesAdvanced(i)).ToArray();
        BuildFusion(scope);
        shown.Clear();
        if (!searchInput.Pending) shown.AddRange(scope.Where(MatchesUnifiedQuery).OrderByDescending(UnifiedScore).ThenByDescending(i => EffectiveModality != "all" && i.Pinned).ThenBy(i => EffectiveModality == "all" && ActiveQuery.Length != 0 ? Guid.Parse(i.Id) : Guid.Empty));
        selected = Math.Max(0, shown.FindIndex(i => i.Id == selection));
        cards.Children.Clear(); tiles.Clear(); results.Children.Clear(); results.ColumnDefinitions.Clear(); previewHost.Child = null;
        if (scroller.Parent is Panel panel) panel.Children.Remove(scroller);
        bool strip = store.State.Layout == "strip", spotlight = store.State.Layout == "spotlight";
        cards.Orientation = strip ? Orientation.Horizontal : Orientation.Vertical; cards.Spacing = strip ? 14 : 2; cards.Padding = strip ? new Thickness(16, 14, 16, 14) : new Thickness(12, 8, 12, 8);
        scroller.HorizontalScrollBarVisibility = strip ? ScrollBarVisibility.Hidden : ScrollBarVisibility.Disabled; scroller.VerticalScrollBarVisibility = strip ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto; scroller.HorizontalScrollMode = strip ? ScrollMode.Enabled : ScrollMode.Disabled; scroller.VerticalScrollMode = strip ? ScrollMode.Disabled : ScrollMode.Enabled; scroller.Content = cards;
        results.ColumnDefinitions.Add(new() { Width = spotlight ? new GridLength(430) : new GridLength(1, GridUnitType.Star) }); Grid.SetColumn(scroller, 0); results.Children.Add(scroller);
        if (spotlight) { results.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); previewHost.BorderThickness = new Thickness(1, 0, 0, 0); previewHost.BorderBrush = Alpha(Theme.Primary, .12); Grid.SetColumn(previewHost, 1); results.Children.Add(previewHost); }
        foreach (HistoryItem item in shown) { if (strip) AddCard(item); else AddRow(item); }
        if (shown.Count == 0)
        {
            var empty = new StackPanel { Spacing = 8, Margin = new Thickness(30), VerticalAlignment = VerticalAlignment.Center, MaxWidth = 600 };
            string heading = searchInput.Pending ? store.State.SearchTiming == "enter" ? "Press Enter to search" : "Waiting for typing to pause…" : SearchPending ? "Searching locally…" : indexingPaused ? "Semantic indexing is paused" : store.State.Items.Count > 0 || search.Text.Length > 0 || filter != "All" || pinnedOnly ? "No matching clips" : store.State.Paused ? "Capture is paused" : "Your clipboard history starts here";
            string detail = SearchPending ? "Results update when this query completes." : indexingPaused ? "Resume semantic indexing in Search settings to refresh derived results." : ActiveQuery.Length != 0 && UsesImageSearch && !ReadyForImages ? "Prepare the selected image model in Search settings." : ActiveQuery.Length != 0 ? "Try another query or adjust the filters." : "Copy in Windows, then summon Cliphoard with Ctrl+Alt+Shift+B.";
            empty.Children.Add(Icon("\uE8C8", Theme.Muted, 28)); empty.Children.Add(Text(heading, Theme, 15)); empty.Children.Add(Text(detail, Theme, 12, true)); cards.Children.Add(empty);
        }
        string modelStatus = UsesImageSearch ? "Image model ready" : "Text model ready";
        bool modelReady = UsesImageSearch ? ReadyForImages : ReadyForSearch;
        string readiness = !SearchPending && modelReady ? " · " + modelStatus : "";
        count.Text = (SearchPending ? "Searching · " : "") + (store.State.Paused ? "Paused · " : "") + $"{shown.Count} item{(shown.Count == 1 ? "" : "s")}" + readiness; Highlight();
    }
    private void AddCard(HistoryItem item)
    {
        int index = tiles.Count; var t = Theme;
        var body = new Grid(); foreach (GridLength height in new[] { new GridLength(28), new GridLength(1), new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto }) body.RowDefinitions.Add(new() { Height = height });
        var top = new Grid { Padding = new Thickness(10, 0, 10, 0), ColumnSpacing = 6 }; foreach (GridLength width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto, GridLength.Auto }) top.ColumnDefinitions.Add(new() { Width = width });
        top.Children.Add(Icon(Glyph(item), t.Accent, 11)); var source = Text(Concealed(item) ? "Protected source" : item.Source, t, 11, true); source.MaxLines = 1; source.TextTrimming = TextTrimming.CharacterEllipsis; source.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(source, 1); top.Children.Add(source);
        if (item.Pinned) { var pin = Icon("\uE718", t.Pin, 10); Grid.SetColumn(pin, 2); top.Children.Add(pin); }
        var inspect = IconButton("\uE740", "Inspect clip · Ctrl+Enter", t, () => ShowInspector(item), 9); inspect.Width = 22; inspect.Height = 20; Grid.SetColumn(inspect, 3); top.Children.Add(inspect);
        if (index < 9) { var quick = Text($"Ctrl {index + 1}", t, 9, true); quick.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(quick, 4); top.Children.Add(quick); }
        body.Children.Add(top); var line = new Border { Background = Alpha(t.Primary, .09) }; Grid.SetRow(line, 1); body.Children.Add(line);
        UIElement content = Preview(item, false); Grid.SetRow((FrameworkElement)content, 2); body.Children.Add(content);
        var bottom = new Grid { Padding = new Thickness(10, 6, 10, 6) }; bottom.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); bottom.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        bottom.Children.Add(Text(Measure(item), t, 10, true)); var age = Text(Age(item), t, 10, true); Grid.SetColumn(age, 1); bottom.Children.Add(age); Grid.SetRow(bottom, 4); body.Children.Add(bottom);
        if (TagChips(item) is FrameworkElement chips) { Grid.SetRow(chips, 3); body.Children.Add(chips); }
        var tile = new Border { Width = 220, Height = store.State.PreviewHeight - 48, Child = body, Background = Brush(t.Card), CornerRadius = new CornerRadius(t.Radius), BorderThickness = new Thickness(1), BorderBrush = Brush(t.Border) };
        tile.Shadow = new ThemeShadow();
        WireTile(tile, item, index); tiles.Add(tile); cards.Children.Add(tile);
    }
    private void AddRow(HistoryItem item)
    {
        int index = tiles.Count; var t = Theme;
        var row = new Grid { Padding = new Thickness(12, 8, 12, 8), ColumnSpacing = 10 };
        foreach (GridLength width in new[] { new GridLength(20), new GridLength(1, GridUnitType.Star), GridLength.Auto, new GridLength(78), new GridLength(52) }) row.ColumnDefinitions.Add(new() { Width = width });
        row.Children.Add(Icon(Glyph(item), t.Accent)); var text = Text(Concealed(item) ? "Protected clip" : item.Kind is "Files" ? Path.GetFileName(item.Text.Split('\n')[0]) : item.Kind == "Image" ? "Image" : item.Text.Replace('\r', ' ').Replace('\n', ' '), t, 12.5); text.MaxLines = 1; text.TextTrimming = TextTrimming.CharacterEllipsis; Grid.SetColumn(text, 1); row.Children.Add(text);
        if (item.Pinned) { var pin = Icon("\uE718", t.Pin, 9); Grid.SetColumn(pin, 2); row.Children.Add(pin); }
        var source = Text(Concealed(item) ? "Protected source" : item.Source, t, 11, true); source.MaxLines = 1; source.TextTrimming = TextTrimming.CharacterEllipsis; source.TextAlignment = TextAlignment.Right; Grid.SetColumn(source, 3); row.Children.Add(source); var age = Text(Age(item), t, 11, true); age.MaxLines = 1; age.TextAlignment = TextAlignment.Right; Grid.SetColumn(age, 4); row.Children.Add(age);
        var tile = new Border { Height = 36, BorderThickness = new Thickness(1.5), CornerRadius = new CornerRadius(8), Child = row, HorizontalAlignment = HorizontalAlignment.Stretch };
        WireTile(tile, item, index); tiles.Add(tile); cards.Children.Add(tile);
    }
    private UIElement Preview(HistoryItem item, bool full)
    {
        var t = Theme;
        if (Concealed(item)) return new Border { Child = Text("Protected clip · verify with Windows Hello to reveal", t, 13), Padding = new Thickness(16) };
        if (item.Kind == "Image" && item.Payload is not null)
        {
            var image = new Image { Stretch = Stretch.Uniform }; _ = LoadBitmap(image, item.Payload, item.Format != 0, full ? 0 : 1024); return new Border { Child = image, Padding = new Thickness(full ? 0 : 8) };
        }
        if (item.Kind == "Color")
        {
            string hex = item.Text.Trim(); if (hex.Length == 4) hex = "#" + string.Concat(hex.Skip(1).Select(c => new string(c, 2))); if (hex.Length == 9) hex = "#" + hex[^2..] + hex.Substring(1, 6);
            return new Border { Background = Brush(hex), Child = new Border { Child = Text(item.Text, t, 13), Background = Alpha(t.Card, .75), CornerRadius = new CornerRadius(5), Padding = new Thickness(6), VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center } };
        }
        if (item.Kind == "Files")
        {
            var file = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(10) }; file.Children.Add(Icon("\uE8A5", t.Muted, 34)); var name = Text(Path.GetFileName(item.Text.Split('\n')[0]) + (item.Text.Contains('\n') ? "\n+ more files" : ""), t, 12); name.TextAlignment = TextAlignment.Center; name.MaxLines = 3; file.Children.Add(name); return file;
        }
        var stack = new StackPanel { Spacing = 6, Margin = new Thickness(full ? 16 : 10) };
        if (item.Kind == "Link") stack.Children.Add(Icon("\uE71B", t.Accent, 22));
        var text = Text(item.Text, t, full ? 13 : 12); text.FontFamily = new FontFamily(item.Kind == "Code" ? "Cascadia Mono" : t.Font); text.MaxLines = full ? 0 : item.Kind == "Link" ? 6 : 11; text.TextTrimming = TextTrimming.CharacterEllipsis; if (item.Kind == "Link") text.Foreground = Brush(t.Accent); stack.Children.Add(text);
        return new ScrollViewer { Content = stack, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = full ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled, VerticalScrollMode = full ? ScrollMode.Enabled : ScrollMode.Disabled };
    }
    private void WireTile(Border tile, HistoryItem item, int index)
    {
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(tile, Concealed(item) ? "Protected clip" : $"{item.Kind} from {item.Source}: {item.Text[..Math.Min(item.Text.Length, 120)]}");
        tile.Tapped += (_, e) => { if (FromButton(e.OriginalSource as DependencyObject)) return; e.Handled = true; ++epoch; bool already = selected == index; selected = index; Highlight(); if (already && item.Kind != "Files") QueuePaste(item); };
        tile.PointerEntered += (_, _) => { if (selected != index) tile.BorderBrush = Brush(Theme.Hover); };
        tile.PointerExited += (_, _) => { if (selected != index) tile.BorderBrush = store.State.Layout == "strip" ? Brush(Theme.Border) : Brush("#00000000"); };
        tile.DoubleTapped += (_, e) => { if (item.Kind == "Files" && selected == index && !FromButton(e.OriginalSource as DependencyObject)) { e.Handled = true; OpenFile(item, false); } };
        var menu = new MenuFlyout();
        void Add(string title, Action action) { var entry = new MenuFlyoutItem { Text = title }; entry.Click += (_, _) => action(); menu.Items.Add(entry); }
        Add("Paste", () => QueuePaste(item)); Add("Paste as plain text", () => QueuePaste(item, true)); Add("Copy", () => Copy(item, false)); Add("Copy as plain text", () => Copy(item, true)); Add("Inspect", () => ShowInspector(item)); if (item.Kind == "Image" && !item.AnalysisVetoed) { Add("Find visually similar images", () => StartReferenceImage(item, true)); Add("Search from this image", () => StartReferenceImage(item, false)); } if (item.Kind == "Files") { Add("Index media locally", async () => await IndexMediaAsync(item)); if (item.MediaIndex is not null) Add("Play matching moment", () => ShowMediaMoment(item)); Add("Open first file", () => OpenFile(item, false)); Add("Show in Explorer", () => OpenFile(item, true)); Add("Copy path", () => Copy(item, true)); } Add(item.Pinned ? "Unpin" : "Pin", () => TogglePin(item)); menu.Items.Add(new MenuFlyoutSeparator()); Add("Delete", () => Delete(item)); tile.ContextFlyout = menu;
    }
    private static bool FromButton(DependencyObject? element)
    {
        while (element is not null) { if (element is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase) return true; element = VisualTreeHelper.GetParent(element); } return false;
    }
    private void Highlight()
    {
        bool strip = store.State.Layout == "strip"; var t = Theme;
        for (int i = 0; i < tiles.Count; ++i) { bool active = selected == i; tiles[i].BorderBrush = active ? Brush(t.Accent) : strip ? Brush(t.Border) : Brush("#00000000"); tiles[i].BorderThickness = new Thickness(active ? strip ? t.SelectedWidth : 1.5 : strip ? 1 : 1.5); if (strip) tiles[i].Translation = new System.Numerics.Vector3(0, 0, active ? 16 : 8); tiles[i].Background = strip ? Brush(t.Card) : active ? Alpha(t.Accent, .16) : Brush("#00000000"); }
        if (store.State.Layout == "spotlight")
        {
            var preview = new Grid { Padding = new Thickness(16), RowSpacing = 12 }; preview.RowDefinitions.Add(new() { Height = GridLength.Auto }); preview.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
            if (selected < shown.Count) { var item = shown[selected]; preview.Children.Add(Text(Concealed(item) ? "Protected clip" : $"{item.Source}   ·   {Measure(item)}", t, 12, true)); var body = (FrameworkElement)Preview(item, true); Grid.SetRow(body, 1); preview.Children.Add(body); } previewHost.Child = preview;
        }
    }
    private void RevealSelection()
    {
        if (store.State.Layout == "strip") scroller.ChangeView(Math.Max(0, selected * 234 - scroller.ViewportWidth / 2 + 110), null, null);
        else scroller.ChangeView(null, Math.Max(0, selected * 38 - scroller.ViewportHeight / 2 + 18), null);
    }
    private void Notice(string text)
    {
        var message = new Grid { ColumnSpacing = 12 };
        message.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        message.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        message.Children.Add(Text(text, Theme, 11));
        var close = IconButton("\uE711", "Dismiss notice", Theme, () => { notice.Child = null; notice.Visibility = Visibility.Collapsed; PositionPanel(); }, 10);
        close.Width = 20; close.Height = 20; Grid.SetColumn(close, 1); message.Children.Add(close);
        notice.Child = message; notice.Background = Alpha(Theme.Accent, .10); notice.Visibility = Visibility.Visible; PositionPanel();
    }
    private static string Measure(HistoryItem item) => item.Kind == "Image" ? item.Text : item.Kind == "Files" ? $"{item.Text.Split('\n').Length} file(s)" : item.Kind == "Color" ? item.Text.Trim() : $"{item.Text.Length:N0} characters";
    private static string Age(HistoryItem item) { var age = DateTimeOffset.Now - item.Captured; return age.TotalMinutes < 1 ? $"{Math.Max(0, (int)age.TotalSeconds)} sec" : age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min" : age.TotalDays < 1 ? $"{(int)age.TotalHours} hr" : $"{(int)age.TotalDays} days"; }
    private async Task LoadBrand(Image image)
    {
        try { await LoadBitmap(image, File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Assets", Theme.Dark ? "Brand.Dark.png" : "Brand.Light.png")), false); } catch { }
    }
    private static async Task LoadBitmap(Image image, byte[] payload, bool dib, int decodePixelWidth = 64)
    {
        try
        {
            byte[] bytes = payload;
            if (dib) { int header = BitConverter.ToInt32(payload), extra = header == 40 && BitConverter.ToUInt32(payload, 16) == 3 ? 12 : 0; bytes = new byte[payload.Length + 14]; bytes[0] = 0x42; bytes[1] = 0x4D; BitConverter.GetBytes(bytes.Length).CopyTo(bytes, 2); BitConverter.GetBytes(14 + header + extra).CopyTo(bytes, 10); payload.CopyTo(bytes, 14); }
            // Logos use a small decode. Clipboard thumbnails need physical pixels for
            // high-DPI displays; inspectors leave the original resolution available.
            using var stream = new InMemoryRandomAccessStream(); using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); } stream.Seek(0); var bitmap = new BitmapImage { DecodePixelWidth = decodePixelWidth }; await bitmap.SetSourceAsync(stream); image.Source = bitmap;
        }
        catch { image.Source = null; }
    }
    private async void ShowInspector(HistoryItem item)
    {
        if (locked || closing || settingsOpen || !store.State.Items.Contains(item) || !await RevealAsync(item)) return;
        if (locked || closing || settingsOpen || !store.State.Items.Contains(item) || Concealed(item)) return;
        ++epoch;
        var t = Theme; var window = new Window { Title = "Inspect clip — Cliphoard" }; var body = new Grid { Padding = new Thickness(24), RowSpacing = 16, Background = Brush(t.Bar), RequestedTheme = t.Dark ? ElementTheme.Dark : ElementTheme.Light };
        inspectedItemId = item.Id; window.Closed += (_, _) => { if (inspectedItemId == item.Id) inspectedItemId = null; };
        body.RowDefinitions.Add(new() { Height = GridLength.Auto }); body.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); body.RowDefinitions.Add(new() { Height = GridLength.Auto }); body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        body.Children.Add(Text($"{item.Kind} · {item.Source} · {Measure(item)}\nCopied {item.Captured:g} · Last used {(item.LastUsed ?? item.Captured):g} · {item.UseCount} uses", t, 14, true));
        FrameworkElement preview = item.Kind is "Text" or "Code" or "Link"
            ? new TextBox
            {
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                Text = item.Text,
                IsReadOnly = true,
                Foreground = Brush(t.Primary),
                Background = Brush(t.Card),
                FontFamily = new FontFamily(item.Kind == "Code" ? "Cascadia Mono" : t.Font)
            }
            : (FrameworkElement)Preview(item, true);
        if (item.Kind == "Image" && !string.IsNullOrEmpty(item.OcrText))
        {
            var imageWithText = new Grid { RowSpacing = 10 };
            imageWithText.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
            imageWithText.RowDefinitions.Add(new() { Height = GridLength.Auto });
            imageWithText.Children.Add(preview);
            var recognized = new TextBox { Header = "Recognized text", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Text = item.OcrText, IsReadOnly = true, MaxHeight = 120 };
            Grid.SetRow(recognized, 1); imageWithText.Children.Add(recognized); preview = imageWithText;
        }
        if (item.Kind == "Image" && !item.AnalysisVetoed)
        {
            preview.MaxHeight = 240; var imageDetails = new StackPanel { Spacing = 8 }; imageDetails.Children.Add(preview);
            var recognize = new Button { Content = "Refresh recognized text", IsEnabled = store.State.OcrEnabled };
            recognize.Click += (_, _) => { if (locked || closing || item.AnalysisVetoed || !store.State.Items.Contains(item)) return; item.OcrText = null; InvalidateAnalysis(); store.Save(); window.Close(); AnalyzePendingImages(); };
            imageDetails.Children.Add(recognize); preview = new ScrollViewer { Content = imageDetails };
        }
        if (item.Kind == "Files")
        {
            var document = new StackPanel { Spacing = 8 };
            document.Children.Add(preview);
            if (!string.IsNullOrEmpty(item.DocumentText)) document.Children.Add(new TextBox { Header = item.DocumentTruncated ? "Document snapshot · truncated" : "Document snapshot", Text = item.DocumentText, AcceptsReturn = true, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MinHeight = 80, MaxHeight = 200 });
            var refreshDocument = new Button { Content = "Refresh document snapshot", IsEnabled = store.State.DocumentTextEnabled && !item.AnalysisVetoed };
            refreshDocument.Click += (_, _) => { if (locked || closing || item.AnalysisVetoed || !store.State.Items.Contains(item)) return; item.DocumentText = null; InvalidateAnalysis(); store.Save(); window.Close(); AnalyzePendingDocuments(); };
            document.Children.Add(refreshDocument); preview = new ScrollViewer { Content = document };
            if (MediaFormats.Supports(item.Text.Split('\n')[0].TrimEnd('\r')))
            {
                var mediaActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                var indexMedia = new Button { Content = item.MediaIndex is null ? "Index media locally" : "Refresh media index", IsEnabled = !indexingMedia && !item.AnalysisVetoed };
                indexMedia.Click += async (_, _) => { window.Close(); await IndexMediaAsync(item); }; mediaActions.Children.Add(indexMedia);
                var playMoment = new Button { Content = "Play matching moment", IsEnabled = item.MediaIndex is not null && !item.AnalysisVetoed };
                playMoment.Click += (_, _) => { window.Close(); ShowMediaMoment(item); }; mediaActions.Children.Add(playMoment); document.Children.Add(mediaActions);
            }
        }
        TextBox? transcriptBox = null;
        if (item.Kind == "Files" && MediaFormats.Supports(item.Text.Split('\n')[0].TrimEnd('\r')) && !item.AnalysisVetoed)
        {
            transcriptBox = new TextBox { Header = "Transcript", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Text = item.Transcript ?? "", IsReadOnly = true, MaxHeight = 160 };
            var fileWithTranscript = new Grid { RowSpacing = 10 };
            fileWithTranscript.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
            fileWithTranscript.RowDefinitions.Add(new() { Height = GridLength.Auto });
            fileWithTranscript.Children.Add(preview); Grid.SetRow(transcriptBox, 1); fileWithTranscript.Children.Add(transcriptBox); preview = fileWithTranscript;
        }
        Grid.SetRow(preview, 1);
        body.Children.Add(preview);
        var tagRow = new Grid { ColumnSpacing = 10 }; tagRow.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); tagRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var tagInput = new TextBox { Header = "Your tags", PlaceholderText = "reference, writing, project", Text = string.Join(", ", item.Tags), MaxLength = 850 }; tagRow.Children.Add(tagInput);
        var saveTags = new Button { Content = "Save tags", VerticalAlignment = VerticalAlignment.Bottom }; saveTags.Click += (_, _) => { if (locked || closing || !store.State.Items.Contains(item)) return; ++epoch; item.Tags = ClipboardContent.Tags(tagInput.Text); item.Flags |= ContentSafety.Flags(string.Join('\n', item.Tags)); UpdateAnalysisPolicy(); PrivacyClassificationChanged(item); tagInput.Text = string.Join(", ", item.Tags); store.Save(); Refresh(); if (Concealed(item)) window.Close(); }; Grid.SetColumn(saveTags, 1); tagRow.Children.Add(saveTags); var categories = new StackPanel { Spacing = 8 }; categories.Children.Add(tagRow);
        AddInspectorCategories(categories, item, tagInput, window);
        var tagScroll = new ScrollViewer { Content = categories, MaxHeight = 180, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetRow(tagScroll, 2); body.Children.Add(tagScroll);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        if (item.Kind == "Image" && !string.IsNullOrEmpty(item.OcrText))
        {
            var copyText = new Button { Content = "Copy text" };
            copyText.Click += (_, _) => Copy(new HistoryItem { Id = item.Id, Text = item.OcrText, Flags = item.Flags }, true);
            actions.Children.Add(copyText);
        }
        if (transcriptBox is not null)
        {
            var transcribe = new Button { Content = "Transcribe audio" };
            transcribe.Click += async (_, _) => await TranscribeClipAsync(item, transcriptBox, transcribe, window);
            actions.Children.Add(transcribe);
            var copyTranscript = new Button { Content = "Copy transcript" };
            copyTranscript.Click += (_, _) => { if (!string.IsNullOrEmpty(item.Transcript)) Copy(new HistoryItem { Id = item.Id, Text = item.Transcript, Flags = item.Flags }, true); };
            actions.Children.Add(copyTranscript);
        }
        var copy = new Button { Content = "Copy" }; copy.Click += (_, _) => Copy(item, false); actions.Children.Add(copy); var pin = new Button { Content = item.Pinned ? "Unpin" : "Pin" }; pin.Click += (_, _) => { TogglePin(item); pin.Content = item.Pinned ? "Unpin" : "Pin"; }; actions.Children.Add(pin); var done = new Button { Content = "Done" }; done.Click += (_, _) => window.Close(); actions.Children.Add(done); Grid.SetRow(actions, 3); body.Children.Add(actions); window.Content = body; DesktopVisual.FitWindow(window, 720, 540); DesktopVisual.StyleWindow(window, t); ShowAuxiliary(window);
    }
}
