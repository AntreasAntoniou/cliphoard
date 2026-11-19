using Microsoft.UI.Xaml.Controls;

namespace Cliphoard.Windows;

internal sealed partial class HistoryWindow
{
    private readonly Microsoft.UI.Xaml.DispatcherTimer sessionResume = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private uint resumeReason, resumeSession;
    private bool confirmingQuit, quitConfirmed;
    private void RequestQuit()
    {
        if (closing) return;
        if (!store.UnsavedChanges || quitConfirmed) { Close(); return; }
        auxiliary?.Close();
        PresentPanel(false, false);
        _ = ConfirmUnsavedQuitAsync();
    }
    private void InitializeRecovery()
    {
        sessionResume.Tick += (_, _) => ResumeSessionWhenReady();
        Closed += (_, _) => sessionResume.Stop();
        store.PersistenceFailed += message => DispatcherQueue.TryEnqueue(() => { if (!closing) Notice(message); });
        AppWindow.Closing += (sender, args) =>
        {
            if (!store.UnsavedChanges || quitConfirmed) return;
            args.Cancel = true;
            _ = ConfirmUnsavedQuitAsync();
        };
    }
    private void ResumeSessionWhenReady()
    {
        if (!locked || closing) { sessionResume.Stop(); return; }
        // A reconnect notification can precede return to the interactive desktop.
        if (!Native.GetCursorPos(out _)) return;
        try { PositionPanel(); }
        catch (Exception error) when (error is IOException or System.Runtime.InteropServices.COMException) { return; }
        sessionResume.Stop();
        try
        {
            store.Load(); locked = false; clipboard?.Baseline(); ApplyAppearance(); AnalysisSettingsChanged();
            if (store.Error is not null) Notice(store.Error);
            store.RecordDiagnostic(DiagnosticKind.SessionResumed);
        }
        catch (Exception error)
        {
            RecordSyntheticSessionFailure(error);
            if (locked) store.Suspend();
            Notice(locked ? "Saved history could not be reopened." : "History restored. Local analysis could not restart. Reopen Settings to retry.");
        }
        RecordSyntheticSession(resumeReason, resumeSession);
    }
    private async Task ConfirmUnsavedQuitAsync()
    {
        if (confirmingQuit || closing) return;
        confirmingQuit = true;
        bool suspended = captureSuspended;
        bool handoff = handingOff;
        captureSuspended = true; handingOff = true; clipboard?.Baseline(); ++epoch;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = root.XamlRoot, RequestedTheme = root.RequestedTheme,
                Title = "Quit with unsaved clipboard changes?",
                Content = "History storage is unavailable. Changes from this session are held in memory and will be lost when Cliphoard closes. Cancel and copy anything you need into another application before quitting. Your previous saved history is preserved.",
                PrimaryButtonText = "Quit anyway", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || closing) return;
            quitConfirmed = true; Close();
        }
        finally
        {
            confirmingQuit = false;
            if (!closing) { captureSuspended = suspended; handingOff = handoff; clipboard?.Baseline(); }
        }
    }
}
