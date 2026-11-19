using Microsoft.UI.Xaml;
using System.Net.Http;
namespace Cliphoard.Windows;
internal sealed partial class HistoryWindow
{
    private readonly DispatcherTimer releasePoll = new() { Interval = TimeSpan.FromMinutes(1) };
    private bool checkingRelease;
    private void InitializeReleaseChecks()
    {
        releasePoll.Tick += async (_, _) => await CheckScheduledReleaseAsync(); releasePoll.Start();
    }
    private async Task CheckScheduledReleaseAsync()
    {
        if (checkingRelease || locked || closing || !store.Writable || !store.State.AutomaticReleaseChecks) return;
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (now - store.State.LastReleaseCheck < 86400) return;
        checkingRelease = true; store.State.LastReleaseCheck = now; store.Save();
        try
        {
            WindowsRelease? release = await WindowsReleases.CheckAsync(analysisLifetime.Token);
            if (!locked && !closing && store.State.AutomaticReleaseChecks && release is not null && release.Version > (GetType().Assembly.GetName().Version ?? new Version(0, 0, 0, 0))) Notice($"Cliphoard {release.Version} is available. Open About in Settings to view the Windows release.");
        }
        catch (Exception error) when (error is OperationCanceledException or HttpRequestException or IOException or System.Text.Json.JsonException or InvalidOperationException) { }
        finally { checkingRelease = false; }
    }
}
