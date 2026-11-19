using Microsoft.UI.Xaml.Controls;
namespace Cliphoard.Windows;
internal sealed partial class DesktopSettingsWindow
{
    private void AddDocumentSettings(StackPanel body)
    {
        var documents = new ToggleSwitch { Header = "Extract text from copied local documents", IsOn = store.State.DocumentTextEnabled };
        documents.Toggled += (_, _) => { if (rebuilding) return; store.State.DocumentTextEnabled = documents.IsOn; Commit(); };
        body.Children.Add(documents);
        var pdf = new ToggleSwitch { Header = "Include PDF documents", IsOn = store.State.PdfTextEnabled };
        pdf.Toggled += (_, _) => { if (rebuilding) return; store.State.PdfTextEnabled = pdf.IsOn; Commit(); };
        body.Children.Add(pdf);
        var rtf = new ToggleSwitch { Header = "Include rich-text documents", IsOn = store.State.RichTextEnabled };
        rtf.Toggled += (_, _) => { if (rebuilding) return; store.State.RichTextEnabled = rtf.IsOn; Commit(); };
        body.Children.Add(rtf);
        var tags = new ToggleSwitch { Header = "Use document text for automatic categories", IsOn = store.State.DocumentTagsEnabled };
        tags.Toggled += (_, _) => { if (rebuilding) return; store.State.DocumentTagsEnabled = tags.IsOn; Commit(); };
        body.Children.Add(tags);
    }
}
