using Microsoft.UI.Xaml;
using Windows.Security.Credentials.UI;
namespace Cliphoard.Windows;

internal sealed partial class HistoryWindow
{
    private readonly SensitiveRevealState revealed = new();
    private readonly DispatcherTimer revealExpiry = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool verifyingReveal;
    private bool Concealed(HistoryItem item) => NsfwPolicy.RequiresAuthentication(item, NsfwActive) && !revealed.Permits(item, Environment.TickCount64);
    private async Task<bool> RevealAsync(HistoryItem item)
    {
        if (!Concealed(item)) return true;
        if (verifyingReveal || locked || closing || CaptureBlocked) return false;
        verifyingReveal = true; handingOff = true;
        long request = ++epoch;
        var permission = revealed.Begin(item);
        try
        {
            clipboard?.Baseline();
            if (await UserConsentVerifier.CheckAvailabilityAsync() != UserConsentVerifierAvailability.Available)
            {
                Notice("Windows Hello verification is unavailable. This protected clip remains concealed."); return false;
            }
            var result = await UserConsentVerifierInterop.RequestVerificationForWindowAsync(hwnd, "Reveal a protected Cliphoard clip");
            if (result != UserConsentVerificationResult.Verified || locked || closing || epoch != request || !store.State.Items.Contains(item)) return false;
            if (!revealed.Complete(permission, item, true, Environment.TickCount64)) return false;
            revealExpiry.Start(); Refresh(); Activate();
            return true;
        }
        catch { if (!locked && !closing) Notice("Windows could not verify your identity. The clip remains concealed."); return false; }
        finally { verifyingReveal = false; handingOff = false; clipboard?.Baseline(); }
    }
}
