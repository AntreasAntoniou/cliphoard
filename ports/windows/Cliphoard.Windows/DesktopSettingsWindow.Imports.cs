using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;
internal sealed partial class DesktopSettingsWindow
{
    private void ManagerImports(StackPanel body, DesktopTheme theme)
    {
        body.Children.Add(new Border { Height = 12 }); body.Children.Add(Text("Import from another clipboard manager", theme, 17));
        body.Children.Add(Text("Choose a copied Mac store from Paste, Maccy, Alfred or Flycut. Quit the source app before copying its database and any matching -wal file. Flycut must flush its store on quit. Previewing preserves the source and your current history.", theme, 13, true));
        var source = new ComboBox { Header = "Source format", ItemsSource = new[] { "Paste", "Maccy", "Alfred · documented schema", "Flycut", "Inspect an unknown SQLite store" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch }; body.Children.Add(source);
        var choose = new Button { Content = "Choose store and preview…", IsEnabled = store.Writable && !archiveBusy }; body.Children.Add(choose);
        var status = Text("The Windows adapters follow the macOS source schemas. Only synthetic stores have been qualified on Windows.", theme, 12, true); body.Children.Add(status);
        choose.Click += async (_, _) =>
        {
            if (archiveBusy || closed || !store.Writable) return;
            archiveBusy = true; choose.IsEnabled = false; suspendCapture(true);
            try
            {
                string adapter = new[] { "paste", "maccy", "alfred", "flycut", "probe" }[source.SelectedIndex];
                var picker = new FileOpenPicker(); foreach (string extension in new[] { ".sqlite", ".db", ".alfdb", ".plist" }) picker.FileTypeFilter.Add(extension);
                WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
                var file = await picker.PickSingleFileAsync(); if (file is null || closed) return;
                status.Text = "Reading a private snapshot…";
                ManagerPreview preview = await ManagerImportClient.PreviewAsync(adapter, file.Path, settingsLifetime.Token); if (closed) return;
                if (adapter == "probe") { status.Text = preview.Tables.Length == 0 ? "No user tables found." : "Tables found · " + string.Join(", ", preview.Tables); return; }
                await ImageAnalysis.AssignArchiveIdentitiesAsync(store.State.Items.Concat(preview.Items), settingsLifetime.Token); if (closed) return;
                int unique = HistoryStore.NewContentCount(store.State.Items, preview.Items);
                var summary = new StackPanel { Spacing = 12 };
                summary.Children.Add(Text($"{preview.Items.Length:N0} supported clips, {unique:N0} new, {preview.Skipped:N0} skipped representations. Saved creation dates and provenance are preserved. Unsupported representations are skipped.", theme, 13));
                foreach (HistoryItem item in preview.Items.Take(5)) summary.Children.Add(Text(item.Flags != 0 ? "Protected content · preview hidden" : item.Kind + " · " + item.Text[..Math.Min(item.Text.Length, 120)], theme, 12, true));
                var documented = new CheckBox { Content = "I reviewed the preview and accept the documented Alfred schema", IsChecked = false, Visibility = adapter == "alfred" ? Visibility.Visible : Visibility.Collapsed }; summary.Children.Add(documented);
                var expand = new CheckBox { Content = "Set history to Unlimited for this import", Visibility = store.State.Limit != 0 && store.State.Items.Count(item => !item.Pinned) + unique > store.State.Limit ? Visibility.Visible : Visibility.Collapsed }; summary.Children.Add(expand);
                var confirm = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Import this preview?", Content = summary, PrimaryButtonText = "Import", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = adapter != "alfred" && unique != 0 };
                documented.Click += (_, _) => confirm.IsPrimaryButtonEnabled = documented.IsChecked == true && unique != 0;
                if (await confirm.ShowAsync() != ContentDialogResult.Primary || closed) return;
                int previous = store.State.Limit;
                if (expand.IsChecked == true) store.State.Limit = 0;
                try { int added = store.Import(preview.Items, false); changed(); status.Text = $"Imported {added:N0} new clips."; }
                catch { store.State.Limit = previous; throw; }
            }
            catch (OperationCanceledException) { if (!closed) status.Text = "Import preview cancelled."; }
            catch { if (!closed) status.Text = "The store could not be imported. Check its schema, local access, size and history limit. Saved history was preserved."; }
            finally { archiveBusy = false; if (!closed) { choose.IsEnabled = store.Writable; suspendCapture(false); } }
        };
    }
}
