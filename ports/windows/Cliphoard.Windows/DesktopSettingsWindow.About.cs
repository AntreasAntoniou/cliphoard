using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;
internal sealed partial class DesktopSettingsWindow
{
    private void About(StackPanel body, DesktopTheme theme)
    {
        body.Children.Add(Text("Cliphoard for Windows", theme, 20));
        body.Children.Add(Text(typeof(HistoryWindow).Assembly.GetName().Version?.ToString() ?? "Local build", theme, 13, true));
        var welcome = new Button { Content = "Welcome to Cliphoard…" }; welcome.Click += async (_, _) => await ShowWelcomeAsync(); body.Children.Add(welcome);
        var automatic = new ToggleSwitch { Header = "Check GitHub for Windows releases once a day", IsOn = store.State.AutomaticReleaseChecks };
        automatic.Toggled += (_, _) => { if (rebuilding) return; store.State.AutomaticReleaseChecks = automatic.IsOn; Commit(); }; body.Children.Add(automatic);
        body.Children.Add(Text("Offline Pro licence", theme, 17));
        var key = new TextBox { Header = "Cliphoard licence key", Text = store.State.LicenceKey, MaxLength = 16384, TextWrapping = TextWrapping.Wrap };
        body.Children.Add(key);
        var status = Text("", theme, 12, true); body.Children.Add(status);
        void ShowStatus() { LicenceEntitlement entitlement = OfflineLicence.Verify(store.State.LicenceKey); status.Text = entitlement.Pro ? "Pro licence verified offline." : entitlement.Reason ?? "No offline Pro licence stored."; }
        var apply = new Button { Content = "Verify and save licence" };
        apply.Click += (_, _) => { LicenceEntitlement entitlement = OfflineLicence.Verify(key.Text); if (!entitlement.Pro) { status.Text = entitlement.Reason ?? "Enter a signed Cliphoard key."; return; } store.State.LicenceKey = key.Text.Trim(); Commit(); ShowStatus(); }; body.Children.Add(apply);
        var remove = new Button { Content = "Remove stored licence" }; remove.Click += (_, _) => { store.State.LicenceKey = ""; key.Text = ""; Commit(); ShowStatus(); }; body.Children.Add(remove);
        ShowStatus();
        body.Children.Add(Text("Windows releases", theme, 17));
        var updateStatus = Text("Checks public release metadata. Opening a release page lets you choose an installer.", theme, 12, true); body.Children.Add(updateStatus);
        var releases = new Button { Content = "Check for a Windows update" }; body.Children.Add(releases);
        var open = new Button { Content = "Open release page", IsEnabled = false }; body.Children.Add(open);
        WindowsRelease? available = null;
        open.Click += (_, _) => { if (available is not null) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(available.Page.AbsoluteUri) { UseShellExecute = true }); };
        releases.Click += async (_, _) =>
        {
            releases.IsEnabled = false;
            try
            {
                available = await WindowsReleases.CheckAsync(settingsLifetime.Token);
                if (closed) return;
                Version installed = typeof(HistoryWindow).Assembly.GetName().Version ?? new Version(0, 0, 0, 0);
                updateStatus.Text = available is null ? "The public feed has no qualified installer for this Windows architecture." : available.Version > installed ? $"Cliphoard {available.Version} is available." : "This build is current with the qualified Windows release feed.";
                open.IsEnabled = available is not null;
            }
            catch { if (!closed) updateStatus.Text = "Release metadata could not be checked. Try again when online."; }
            finally { if (!closed) releases.IsEnabled = true; }
        };
    }
}
