using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static Cliphoard.Windows.DesktopVisual;

namespace Cliphoard.Windows;

internal sealed partial class HistoryWindow
{
    private readonly HashSet<AutomaticTag> facetFilters = new();
    private readonly HashSet<string> userTagFilters = new(StringComparer.OrdinalIgnoreCase);
    private static readonly (long Bit, string Name)[] FlagLabels =
    {
        (1, "secret"), (2, "secret-entropy"), (4, "financial"), (8, "contact"), (16, "sensitive identity"), (32, "one-time code"), (64, "quarantined"), (128, "NSFW")
    };
    private bool MatchesAdvanced(HistoryItem item)
    {
        if (userTagFilters.Count > 0 && !item.Tags.Any(userTagFilters.Contains)) return false;
        foreach (var group in facetFilters.GroupBy(tag => tag.Axis))
        {
            bool Match(AutomaticTag tag) => tag.Axis switch
            {
                "Sensitivity" => FlagLabels.Any(flag => flag.Name == tag.Name && (item.Flags & flag.Bit) != 0),
                "Shape" => item.Shape == tag.Name,
                "Status" => ContentShape.Lifecycle(item, DateTimeOffset.Now) == tag.Name,
                "Source" => item.Source == tag.Name,
                _ => automaticTags.GetValueOrDefault(item.Id, Array.Empty<AutomaticTag>()).Contains(tag)
            };
            if (!group.Any(Match)) return false;
        }
        return true;
    }
    private void ToggleFacet(AutomaticTag tag)
    {
        if (!facetFilters.Remove(tag)) facetFilters.Add(tag);
        ++epoch; selected = -1; BuildChrome(); Refresh();
    }
    private void AddFacetMenus(MenuFlyout menu)
    {
        var visible = store.State.Items.Where(item => !Concealed(item)).ToArray();
        var values = new List<AutomaticTag>();
        values.AddRange(FlagLabels.Where(flag => store.State.Items.Any(item => (item.Flags & flag.Bit) != 0)).Select(flag => new AutomaticTag("Sensitivity", flag.Name)));
        values.AddRange(visible.Where(item => item.Shape is not null).Select(item => new AutomaticTag("Shape", item.Shape!)));
        values.AddRange(visible.Select(item => ContentShape.Lifecycle(item, DateTimeOffset.Now)).OfType<string>().Select(status => new AutomaticTag("Status", status)));
        values.AddRange(visible.Select(item => new AutomaticTag("Source", item.Source)));
        values.AddRange(visible.SelectMany(item => automaticTags.GetValueOrDefault(item.Id, Array.Empty<AutomaticTag>())));
        foreach (var group in values.Distinct().GroupBy(tag => tag.Axis))
        {
            var submenu = new MenuFlyoutSubItem { Text = group.Key.Length == 0 ? "Topics" : group.Key };
            foreach (AutomaticTag tag in group.OrderBy(tag => tag.Name, StringComparer.Ordinal))
            {
                var option = new ToggleMenuFlyoutItem { Text = tag.Name, IsChecked = facetFilters.Contains(tag) };
                option.Click += (_, _) => ToggleFacet(tag); submenu.Items.Add(option);
            }
            menu.Items.Add(submenu);
        }
        var users = new MenuFlyoutSubItem { Text = "Your tags" };
        foreach (string tag in visible.SelectMany(item => item.Tags).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase))
        {
            var option = new ToggleMenuFlyoutItem { Text = "#" + tag, IsChecked = userTagFilters.Contains(tag) };
            option.Click += (_, _) => { if (!userTagFilters.Remove(tag)) userTagFilters.Add(tag); ++epoch; selected = -1; BuildChrome(); Refresh(); };
            users.Items.Add(option);
        }
        menu.Items.Add(users);
    }
    private FrameworkElement? TagChips(HistoryItem item)
    {
        var labels = FlagLabels.Where(flag => (item.Flags & flag.Bit) != 0).Select(flag => new AutomaticTag("Sensitivity", flag.Name)).ToList();
        if (!Concealed(item))
        {
            labels.AddRange(automaticTags.GetValueOrDefault(item.Id, Array.Empty<AutomaticTag>()));
            if (item.Shape is string shape) labels.Add(new("Shape", shape));
            if (ContentShape.Lifecycle(item, DateTimeOffset.Now) is string status) labels.Add(new("Status", status));
            labels.AddRange(item.Tags.Select(tag => new AutomaticTag("User", tag)));
        }
        if (labels.Count == 0) return null;
        var rows = new StackPanel { Spacing = 2, Margin = new Thickness(10, 3, 10, 0) };
        foreach (AutomaticTag tag in labels.Take(3))
        {
            var label = Text((tag.Axis == "User" ? "#" : "") + tag.Name, Theme, 9, true);
            label.MaxLines = 1; label.TextTrimming = TextTrimming.CharacterEllipsis;
            var button = new Button { Content = label, Padding = new Thickness(6, 1, 6, 1), Background = Brush(Theme.Tag), BorderThickness = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Left, MaxWidth = 192, CornerRadius = new CornerRadius(8) };
            ToolTipService.SetToolTip(button, tag.ToString());
            button.Click += (_, _) => { if (tag.Axis == "User") { if (!userTagFilters.Remove(tag.Name)) userTagFilters.Add(tag.Name); ++epoch; BuildChrome(); Refresh(); } else ToggleFacet(tag); };
            rows.Children.Add(button);
        }
        return rows;
    }
    private void AddInspectorCategories(StackPanel details, HistoryItem item, TextBox tagInput, Window inspector)
    {
        AutomaticTag[] labels = automaticTags.GetValueOrDefault(item.Id, Array.Empty<AutomaticTag>());
        if (labels.Length > 0) details.Children.Add(Text(string.Join(" · ", labels.Select(label => label.ToString())), Theme, 12, true));
        foreach (string suggestion in suggestedTags.GetValueOrDefault(item.Id, Array.Empty<string>()))
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var apply = new Button { Content = "Add #" + suggestion };
            var dismiss = new Button { Content = "Dismiss" };
            apply.Click += (_, _) =>
            {
                if (locked || closing || !store.State.Items.Contains(item)) return;
                item.Tags = ClipboardContent.Tags(string.Join(',', item.Tags.Append(suggestion)));
                item.Flags |= ContentSafety.Flags(string.Join('\n', item.Tags));
                UpdateAnalysisPolicy(); PrivacyClassificationChanged(item);
                tagInput.Text = string.Join(", ", item.Tags); ++epoch; store.Save(); rankedKey = ""; Refresh();
                apply.IsEnabled = dismiss.IsEnabled = false;
                if (Concealed(item)) inspector.Close();
            };
            dismiss.Click += (_, _) => { if (locked || closing || !store.State.Items.Contains(item)) return; if (!item.DismissedSuggestions.Contains(suggestion)) item.DismissedSuggestions.Add(suggestion); store.Save(); apply.IsEnabled = dismiss.IsEnabled = false; };
            row.Children.Add(apply); row.Children.Add(dismiss); details.Children.Add(row);
        }
    }
}
