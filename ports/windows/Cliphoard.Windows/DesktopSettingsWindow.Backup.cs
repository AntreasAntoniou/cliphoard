using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Security.Cryptography;
using System.Text;
using Windows.Storage.Pickers;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;
internal sealed partial class DesktopSettingsWindow
{
    private bool archiveBusy;
    private void Backup(StackPanel body, DesktopTheme t)
    {
        body.Children.Add(Text("Encrypted backup", t, 17));
        body.Children.Add(Text("Save clips, images, labels and pins in the shared Mac/Windows .cliphoard format. A passphrase protects the archive. Legacy .cliphoard-win backups can also be imported.", t, 13, true));
        var status = Text(store.Writable ? "Capture pauses while an archive prompt is open." : "Saved history is unavailable. Backup and import are disabled to preserve the original file.", t, 12, true);
        var export = new Button { Content = "Export encrypted history…", IsEnabled = store.Writable && !archiveBusy };
        var import = new Button { Content = "Import history…", IsEnabled = store.Writable && !archiveBusy };
        async Task Run(bool writing)
        {
            if (archiveBusy || closed || !store.Writable) return;
            archiveBusy = true; export.IsEnabled = import.IsEnabled = false; suspendCapture(true);
            PasswordBox? first = null, confirmation = null;
            MacArchiveStage? stagedArchive = null;
            try
            {
                string path;
                byte[]? archiveBytes = null;
                if (writing)
                {
                    var picker = new FileSavePicker { SuggestedFileName = "Cliphoard Windows " + DateTime.Now.ToString("yyyy-MM-dd") };
                    picker.FileTypeChoices.Add("Encrypted Cliphoard history (Mac and Windows)", new List<string> { ".cliphoard" }); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
                    var file = await picker.PickSaveFileAsync(); if (file is null || closed) return; path = file.Path;
                }
                else
                {
                    var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(".cliphoard"); picker.FileTypeFilter.Add(".cliphoard-win"); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
                    var file = await picker.PickSingleFileAsync(); if (file is null || closed) return; path = file.Path;
                    using var input = LocalFileLease.Open(path, long.MaxValue);
                    byte[] magic = new byte[8]; input.ReadExactly(magic);
                    if (!magic.AsSpan().SequenceEqual("CLIPHRD1"u8)) archiveBytes = PortableHistory.ReadBounded(path);
                }
                first = new PasswordBox { Header = "Passphrase", MaxLength = 1024, PasswordRevealMode = PasswordRevealMode.Hidden };
                var prompt = new StackPanel { Spacing = 14 }; prompt.Children.Add(first);
                var strength = Text("", t, 12, true); prompt.Children.Add(strength);
                if (writing) { confirmation = new PasswordBox { Header = "Confirm passphrase", MaxLength = 1024, PasswordRevealMode = PasswordRevealMode.Hidden }; prompt.Children.Add(confirmation); }
                if (writing)
                {
                    var generate = new Button { Content = "Generate a strong passphrase" };
                    generate.Click += (_, _) => { string generated = ArchivePassphrase.Generate(); first.Password = generated; if (confirmation is not null) confirmation.Password = generated; };
                    prompt.Children.Add(generate);
                }
                var showPassphrase = new CheckBox { Content = "Show passphrase" };
                showPassphrase.Click += (_, _) =>
                {
                    first.PasswordRevealMode = showPassphrase.IsChecked == true ? PasswordRevealMode.Visible : PasswordRevealMode.Hidden;
                    if (confirmation is not null) confirmation.PasswordRevealMode = first.PasswordRevealMode;
                };
                prompt.Children.Add(showPassphrase);
                prompt.Children.Add(Text("Use at least 12 characters. Capture is paused. Nothing is sent online.", t, 12, true));
                var dialog = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.RequestedTheme, Background = Brush(t.Card), Foreground = Brush(t.Primary), Title = writing ? "Protect your backup" : "Unlock backup", Content = prompt, PrimaryButtonText = writing ? "Export" : "Unlock", CloseButtonText = "Cancel", IsPrimaryButtonEnabled = false };
                bool legacy = archiveBytes is not null && archiveBytes.AsSpan().StartsWith("CLPHWIN1"u8);
                void Validate()
                {
                    strength.Text = "Passphrase · " + ArchivePassphrase.StrengthLabel(ArchivePassphrase.Strength(first.Password)) + (writing && confirmation?.Password.Length > 0 && first.Password != confirmation.Password ? " · confirmation differs" : "");
                    int characters = legacy ? first.Password.EnumerateRunes().Count() : new System.Globalization.StringInfo(first.Password).LengthInTextElements;
                    dialog.IsPrimaryButtonEnabled = characters >= 12 && (!writing || first.Password == confirmation?.Password);
                }
                first.PasswordChanged += (_, _) => Validate(); if (confirmation is not null) confirmation.PasswordChanged += (_, _) => Validate();
                if (await dialog.ShowAsync() != ContentDialogResult.Primary || closed) return;
                string passphrase = first.Password; first.Password = ""; if (confirmation is not null) confirmation.Password = "";
                status.Text = writing ? "Encrypting history…" : "Authenticating archive…";
                if (writing)
                {
                    HistoryState snapshot = MacHistoryArchive.Snapshot(store.State);
                    await Task.Run(() => MacHistoryArchive.SealFileAsync(snapshot, passphrase, path, settingsLifetime.Token, temporary =>
                    {
                        lock (archivePublishGate)
                        {
                            if (closed) throw new OperationCanceledException();
                            if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Archive destination is a link.");
                            File.Move(temporary, path, true);
                        }
                    }), settingsLifetime.Token);
                    status.Text = "Encrypted backup saved.";
                }
                else
                {
                    HistoryState staged;
                    if (archiveBytes is null)
                    {
                        var progress = new Progress<int>(count => { if (!closed && count % 100 == 0) status.Text = $"Authenticating archive · {count:N0} clips"; });
                        stagedArchive = await Task.Run(() => MacHistoryArchive.OpenFile(path, passphrase, settingsLifetime.Token, progress), settingsLifetime.Token);
                        staged = stagedArchive.State;
                    }
                    else staged = await Task.Run(() => PortableHistory.Open(archiveBytes, passphrase), settingsLifetime.Token);
                    if (closed) return;
                    status.Text = "Comparing image contents…";
                    var currentItems = store.State.Items.ToArray();
                    await Task.Run(() => ImageAnalysis.AssignArchiveIdentitiesAsync(currentItems.Concat(staged.Items)));
                    if (closed) return;
                    int unique = HistoryStore.NewContentCount(store.State.Items, staged.Items);
                    var expand = new CheckBox { Content = "Set history to Unlimited for this import", IsChecked = false, Visibility = store.State.Limit != 0 && store.State.Items.Count(item => !item.Pinned) + staged.Items.Count(item => !item.Pinned) > store.State.Limit ? Visibility.Visible : Visibility.Collapsed };
                    var summary = new StackPanel { Spacing = 12 }; summary.Children.Add(Text($"{staged.Items.Count} clips authenticated; {unique} are new. Existing clips and settings stay. The entire import must fit your selected history limit.", t, 13)); summary.Children.Add(expand);
                    var confirm = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.RequestedTheme, Background = Brush(t.Card), Foreground = Brush(t.Primary), Title = "Import this history?", Content = summary, PrimaryButtonText = "Import", CloseButtonText = "Cancel" };
                    if (await confirm.ShowAsync() != ContentDialogResult.Primary || closed) return;
                    int previousLimit = store.State.Limit;
                    if (expand.IsChecked == true) store.State.Limit = 0;
                    try { int added = store.Import(staged.Items, false); changed(); status.Text = $"Imported {added} new clips. Existing duplicates were kept."; }
                    catch { store.State.Limit = previousLimit; throw; }
                }
            }
            catch (OperationCanceledException) { status.Text = "Archive operation cancelled."; }
            catch (AuthenticationTagMismatchException) { status.Text = "Wrong passphrase or damaged archive. Nothing was imported."; }
            catch (Exception error) when (error is IOException or ArgumentException or CryptographicException or System.Text.Json.JsonException) { status.Text = "Archive operation refused. Check the passphrase, file, available space and history limits. Existing saved history was preserved."; }
            catch { status.Text = "Windows could not complete the archive operation. Existing history was preserved."; }
            finally { stagedArchive?.Dispose(); if (first is not null) first.Password = ""; if (confirmation is not null) confirmation.Password = ""; archiveBusy = false; suspendCapture(false); if (!closed) export.IsEnabled = import.IsEnabled = store.Writable; }
        }
        export.Click += async (_, _) => await Run(true); import.Click += async (_, _) => await Run(false); body.Children.Add(export); body.Children.Add(import); body.Children.Add(status);
        ManagerImports(body, t);
    }
}
