using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;
internal sealed partial class DesktopSettingsWindow
{
    private void AgentChanged() { if (!closed && section == "Agent notes") Render(); }
    private void AgentNotes(StackPanel body, DesktopTheme theme)
    {
        body.Children.Add(Text("Receive notes from an agent", theme, 17));
        body.Children.Add(new TextBox { Header = "MCP server command", Text = Path.Combine(AppContext.BaseDirectory, "Companion", "Cliphoard.Companion.exe"), IsReadOnly = true });
        body.Children.Add(Text("Add this command to your MCP client with no arguments. Ask the agent to connect only when you want to share an export or receive notes. Disconnecting forgets its temporary shared clips and note keys.", theme, 12, true));
        body.Children.Add(Text("Any process in your Windows account can submit a note to the selected connection folder. Review each note with Ask every time, or grant automatic saves for a connection you enable. Flagged sensitive notes are rejected.", theme, 13, true));
        var permission = new ComboBox { Header = "Permission", ItemsSource = new[] { "Ask every time", "This session", "Full access" }, SelectedIndex = (int)agents.Permission, HorizontalAlignment = HorizontalAlignment.Stretch };
        permission.SelectionChanged += async (_, _) =>
        {
            if (rebuilding || permission.SelectedIndex < 0) return;
            var selected = (AgentPermission)permission.SelectedIndex;
            bool confirmed = selected <= agents.Permission;
            if (!confirmed)
            {
                var confirm = new ContentDialog
                {
                    XamlRoot = root.XamlRoot, RequestedTheme = root.RequestedTheme, Title = selected == AgentPermission.FullAccess ? "Remember automatic agent saves?" : "Allow automatic saves this session?",
                    Content = selected == AgentPermission.FullAccess ? "Eligible new plain-text notes will be saved and pinned automatically. This permission is remembered for connections you explicitly enable. A new Full access connection stays active until you disconnect or quit. An existing timed connection keeps its deadline."
                        : "Eligible new plain-text notes will be saved and pinned automatically for the rest of this 15-minute connection. Disconnecting or expiry restores Ask every time.",
                    PrimaryButtonText = selected == AgentPermission.FullAccess ? "Remember automatic saves" : "Allow for this session", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
                };
                confirmed = await confirm.ShowAsync() == ContentDialogResult.Primary;
            }
            if (closed) return;
            if (!confirmed || !agents.SetPermission(selected, confirmed)) Render();
        };
        body.Children.Add(permission);
        body.Children.Add(Text(agents.Message, theme, 12, true));
        if (agents.Folder is string folder) body.Children.Add(new TextBox { Header = "Connection folder for your MCP companion", Text = folder, IsReadOnly = true, TextWrapping = TextWrapping.Wrap });
        var connect = new Button { Content = agents.Permission == AgentPermission.FullAccess ? "Enable agent connection…" : "Enable 15-minute connection…", IsEnabled = store.Writable && !agents.Working };
        connect.Click += async (_, _) =>
        {
            if (closed || agents.Working || !store.Writable) return;
            suspendCapture(true);
            try
            {
                var picker = new FolderPicker(); picker.FileTypeFilter.Add("*"); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
                var parent = await picker.PickSingleFolderAsync(); if (parent is null || closed) return;
                await agents.EnableAsync(parent.Path);
            }
            catch { if (!closed) { agents.Disconnect(); body.Children.Add(Text("Choose an available local folder to create a private connection.", theme, 12, true)); } }
            finally { if (!closed) suspendCapture(false); }
        };
        body.Children.Add(connect);
        var disconnect = new Button { Content = "Disconnect", IsEnabled = agents.Connected }; disconnect.Click += (_, _) => agents.Disconnect(); body.Children.Add(disconnect);
        var notifications = new ToggleSwitch { Header = "Notify me when an agent requests approval", IsOn = store.State.AgentNotifications };
        notifications.Toggled += (_, _) => { if (rebuilding) return; store.State.AgentNotifications = notifications.IsOn; Commit(); }; body.Children.Add(notifications);
        foreach (AgentPending note in agents.Pending.ToArray())
        {
            var card = new StackPanel { Spacing = 8 };
            card.Children.Add(new TextBox { Header = "Requested note", Text = note.Text, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 160 });
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            string id = note.Id, digest = note.Opened.RequestDigest;
            var approve = new Button { Content = "Save and pin", IsEnabled = !agents.Working }; approve.Click += async (_, _) => await agents.ApproveAsync(id, digest); actions.Children.Add(approve);
            var reject = new Button { Content = "Reject", IsEnabled = !agents.Working }; reject.Click += async (_, _) => await agents.RejectAsync(id, digest); actions.Children.Add(reject);
            card.Children.Add(actions); body.Children.Add(new Border { Child = card, Padding = new Thickness(12), BorderThickness = new Thickness(1), BorderBrush = Alpha(theme.Primary, .15), CornerRadius = new CornerRadius(10) });
        }
    }
}
