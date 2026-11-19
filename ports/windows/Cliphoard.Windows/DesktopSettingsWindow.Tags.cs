using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static Cliphoard.Windows.DesktopVisual;

namespace Cliphoard.Windows;

internal sealed partial class DesktopSettingsWindow
{
    private void Tags(StackPanel body, DesktopTheme theme)
    {
        var custom = new ToggleSwitch { Header = "Use a custom automatic-tag vocabulary", IsOn = store.State.CustomBasket };
        custom.Toggled += (_, _) => { if (rebuilding) return; store.State.CustomBasket = custom.IsOn; Commit(); };
        body.Children.Add(custom);
        foreach (TagBasket basket in TagCatalog.BuiltIn.Where(basket => basket.Id != "general"))
        {
            var choice = new CheckBox { Content = basket.Name, IsChecked = store.State.TagOverlays.Contains(basket.Id) };
            choice.Click += (_, _) =>
            {
                if (choice.IsChecked == true) { if (!store.State.TagOverlays.Contains(basket.Id)) store.State.TagOverlays.Add(basket.Id); }
                else store.State.TagOverlays.Remove(basket.Id);
                Commit();
            };
            body.Children.Add(choice);
        }
        var confidence = new Slider { Header = "Automatic assignment confidence", Minimum = .05, Maximum = .95, StepFrequency = .01, Value = store.State.TagThreshold };
        confidence.ValueChanged += (_, _) => { if (rebuilding) return; store.State.TagThreshold = confidence.Value; Commit(); };
        body.Children.Add(confidence);
        var vocabulary = new TextBox { Header = "Custom vocabulary · one label per line", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Text = string.Join('\n', store.State.CustomTagNames), MaxLength = 65536, MinHeight = 100 };
        body.Children.Add(vocabulary);
        var status = Text("General uses factual chips. Specialist baskets add concrete categories from your selected local model.", theme, 12, true);
        var apply = new Button { Content = "Apply custom vocabulary" };
        apply.Click += (_, _) =>
        {
            string[] names = vocabulary.Text.Split(new[] { '\n', '\r', ',' }, StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).Distinct(StringComparer.Ordinal).ToArray();
            if (names.Length > 2000 || names.Any(name => name.Length > 80)) { status.Text = "Use up to 2,000 labels of at most 80 characters each."; return; }
            store.State.CustomTagNames = names.ToList(); Commit(); status.Text = "Vocabulary saved. Categories are rebuilt from local vectors.";
        };
        body.Children.Add(apply); body.Children.Add(status);
    }
}
