using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI.ViewManagement;
namespace Cliphoard.Windows;

/// Per-user clipboard state and native paste admission stay independent of presentation.
internal sealed partial class HistoryWindow : Window
{
    private readonly HistoryStore store;
    private readonly UISettings appearance = new();
    private NativeWindowAdapter? native;
    private TrayIcon? tray;
    private HistoryClipboard? clipboard;
    private PasteInput? input;
    private PasteTarget? target;
    private Window? auxiliary;
    private nint hwnd;
    private readonly CaptureSuspensions capturePauses = new();
    private bool CaptureBlocked => captureSuspended || capturePauses.Active;
    private bool locked, closing, handingOff, settingsOpen, captureSuspended;
    private long epoch;
    private readonly DispatcherTimer retry = new() { Interval = TimeSpan.FromMilliseconds(80) };
    private int retries;
    private DesktopTheme Theme => DesktopThemes.Resolve(store.State.Theme, SystemDark);
    private bool SystemDark { get { var bg = appearance.GetColorValue(UIColorType.Background); return bg.R + bg.G + bg.B < 384; } }
    internal HistoryWindow(HistoryStore? history = null)
    {
        store = history ?? new(); indexes = new(Path.Combine(store.DirectoryPath, "indexes"));
        semantic = new(indexes);
        agents = new((id, text) => !locked && !closing && store.SaveAgentNote(id, text), () => !locked && !closing, mode => { store.State.AgentPermission = mode == AgentPermission.FullAccess ? "fullAccess" : "askEveryTime"; store.Save(); }, store.State.AgentPermission == "fullAccess");
        Title = "Cliphoard"; Content = root;
        BuildChrome();
        revealExpiry.Tick += (_, _) =>
        {
            if (revealed.Count == 0) { revealExpiry.Stop(); return; }
            if (!revealed.Expire(Environment.TickCount64) && store.State.Items.Any(item => revealed.Permits(item, Environment.TickCount64))) return;
            revealed.Clear();
            revealExpiry.Stop(); ++epoch;
            if (auxiliary is not DesktopSettingsWindow) auxiliary?.Close();
            Refresh();
        };
        appearance.ColorValuesChanged += AppearanceChanged;
        retry.Tick += (_, _) => { if (--retries <= 0) retry.Stop(); Capture(); };
        Closed += (_, _) => { closing = true; releasePoll.Stop(); agentPoll.Stop(); agents.Dispose(); ClearReferenceImage(); protectionPoll.Stop(); searchDelay.Stop(); revealExpiry.Stop(); revealed.Clear(); InvalidateAnalysis(true); _ = ClearImagesAsync(); _ = ClearScreeningAsync(); _ = Task.Run(semantic.Dispose); ++epoch; retry.Stop(); auxiliary?.Close(); appearance.ColorValuesChanged -= AppearanceChanged; native?.Dispose(); tray?.Dispose(); input?.Dispose(); target?.Dispose(); };
        Activated += (_, e) => { if (e.WindowActivationState == WindowActivationState.Deactivated && !handingOff && !settingsOpen && !closing) Dismiss(false); };
    }
    internal void Initialize(bool background = false)
    {
        try
        {
            hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
            InitializeRecovery(); InitializeScreening();
            capturePauses.Changed += () => { ++epoch; clipboard?.Baseline(); };
            AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Cliphoard.ico"));
            if (AppWindow.Presenter is OverlappedPresenter p) { p.SetBorderAndTitleBar(false, false); p.IsResizable = p.IsMaximizable = p.IsMinimizable = false; }
            AppWindow.IsShownInSwitchers = false;
            int rounded = 1; DwmSetWindowAttribute(hwnd, 33, ref rounded, 4);
            native = new(hwnd); clipboard = new(hwnd, () => store.State.ExcludedApps); input = new(); tray = new(hwnd);
            native.WorkAreaChanged += () => DispatcherQueue.TryEnqueue(() =>
            {
                if (locked || closing) return;
                try { PositionPanel(); }
                catch (Exception error) when (error is IOException or System.Runtime.InteropServices.COMException) { }
            });
            native.Shortcut += () => { if (AppWindow.IsVisible && !settingsOpen) Dismiss(true); else ShowPanel(); };
            native.ClipboardChanged += () => { retries = 3; Capture(); retry.Start(); };
            native.TrayAction += action => { if (action == 0x202) ShowPanel(); else if (action == 0x205) { int choice = tray.Menu(); if (choice == 1) ShowPanel(); else if (choice == 2) TogglePause(); else if (choice == 3) { ShowPanel(); ShowSettings(); } else if (choice == 4) RequestQuit(); } };
            native.SessionChanged += Session;
            InitializeAgents(); InitializeReleaseChecks(); ApplyAppearance(); AnalysisSettingsChanged(); if (background) AppWindow.Hide(); else ShowPanel();
            if (store.Error is not null) Notice(store.Error);
            if (!background && !store.State.OnboardingCompleted && store.State.Items.Count == 0) DispatcherQueue.TryEnqueue(() => ShowSettings(true));
        }
        catch { Notice("Cliphoard could not start. Close any other Windows Cliphoard instance and relaunch."); }
    }
    internal void ShowPanel() => PresentPanel(true);
    private void PresentPanel(bool captureTarget, bool resetSearch = true)
    {
        if (locked || closing || native is null) return;
        ++epoch;
        Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out uint pid);
        if (captureTarget && pid != (uint)Environment.ProcessId) { target?.Dispose(); target = PasteTarget.Capture(hwnd); }
        PositionPanel(true); AppWindow.Show(store.State.TakeFocusOnSummon);
        if (store.State.TakeFocusOnSummon)
        {
            Activate();
            if (!Native.SetForegroundWindow(hwnd) || Native.GetForegroundWindow() != hwnd) { Dismiss(false); return; }
        }
        if (resetSearch) { ClearReferenceImage(); searchInput.Reset(""); search.Text = ""; selected = -1; }
        Refresh();
        if (resetSearch) scroller.ChangeView(0, 0, null, true); else RevealSelection();
        if (store.State.TakeFocusOnSummon) search.Focus(FocusState.Programmatic);
        store.RecordDiagnostic(DiagnosticKind.PanelShown);
    }
    private void PositionPanel(bool chooseMonitor = false)
    {
        if (hwnd == 0 || native is null) return;
        double scale = GetDpiForWindow(hwnd) / 96.0;
        int height = Math.Max(320, store.State.PreviewHeight + (store.State.Layout == "strip" ? -48 : 0) + 28 + 56 + 34 + (notice.Visibility == Visibility.Visible ? 32 : 0));
        native.PositionAtBottom(AppWindow, int.MaxValue, (int)Math.Ceiling(height * scale), chooseMonitor);
        if (auxiliary is not null) Native.SetWindowPos(WinRT.Interop.WindowNative.GetWindowHandle(auxiliary), -1, 0, 0, 0, 0, 0x13);
    }
    private void Dismiss(bool restore)
    {
        ++epoch;
        searchDelay.Stop(); searchInput.Reset(search.Text);
        revealExpiry.Stop();
        bool concealAgain = revealed.Count > 0;
        revealed.Clear(); AppWindow.Hide();
        if (concealAgain && !closing) Refresh();
        if (restore) target?.RestoreFocus(); target?.Dispose(); target = null;
    }
    partial void RecordSyntheticSession(uint reason, uint session);
    partial void RecordSyntheticSessionFailure(Exception error);
    partial void RecordSyntheticPaste(bool copied, bool restored, bool ready, bool current, bool written, long requested, long actual);
    private void Session(uint reason, uint session)
    {
        if (session != (uint)System.Diagnostics.Process.GetCurrentProcess().SessionId) return;
        if (reason is 2 or 4 or 6 or 7)
        {
            sessionResume.Stop();
            store.RecordDiagnostic(DiagnosticKind.SessionSuspended);
            searchDelay.Stop(); searchInput.Reset("");
            locked = true; agents.Disconnect(); ClearReferenceImage(); InvalidateAnalysis(true); _ = ClearImagesAsync(); _ = ClearScreeningAsync(); _ = semantic.ClearAsync(); retry.Stop(); Dismiss(false); auxiliary?.Close(); store.Suspend(); cards.Children.Clear(); shown.Clear(); tiles.Clear(); previewHost.Child = null; search.Text = "";
        }
        else if (locked && reason is 1 or 3 or 8)
        {
            resumeReason = reason; resumeSession = session; sessionResume.Start(); ResumeSessionWhenReady();
        }
        RecordSyntheticSession(reason, session);
    }
    private void Capture()
    {
        if (locked || closing || store.State.Paused || CaptureBlocked || verifyingReveal || clipboard is null) return;
        try { HistoryItem? item = clipboard.ReadUpdate(); if (item is null) return; ++epoch; store.Add(item); UpdateAnalysisPolicy(); if (item.AnalysisVetoed) PrivacyClassificationChanged(item); AnalyzePendingImages(); AnalyzePendingDocuments(); ScreenPendingContent(); if (store.State.SoundEnabled) CaptureSound(); selected = -1; Refresh(); int index = shown.FindIndex(i => i.Id == item.Id); if (index >= 0) { selected = index; Highlight(); RevealSelection(); } } catch { Notice("That clipboard format could not be captured."); }
    }
    [System.Runtime.InteropServices.DllImport("winmm.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern bool PlaySound(string sound, nint module, uint flags);
    private void CaptureSound() => PreviewCaptureSound(store.State.SoundName);
    internal static void PreviewCaptureSound(string name)
    {
        if (!HistoryState.CaptureSounds.ContainsKey(name)) return;
        bool bundled = name.StartsWith("copy-", StringComparison.Ordinal);
        string source = bundled ? Path.Combine(AppContext.BaseDirectory, "Assets", "Sounds", name + ".wav") : name;
        // Filename and alias modes remain separate. Never play a fallback beep.
        PlaySound(source, 0, (bundled ? 0x20000u : 0x10000u) | 0x1 | 0x2 | 0x10);
    }
    private void TogglePause()
    {
        if (locked || closing) return;
        ++epoch; store.State.Paused = !store.State.Paused; clipboard?.Baseline(); store.Save(); BuildChrome(); Refresh();
    }
    private async void Copy(HistoryItem item, bool plain)
    {
        if (locked || CaptureBlocked || verifyingReveal || clipboard is null || !await RevealAsync(item) || Concealed(item)) return;
        if (locked || closing || CaptureBlocked) return;
        long requested = ++epoch;
        string fingerprint = SensitiveRevealState.Fingerprint(item);
        byte[]? bitmap = null;
        try
        {
            if (!plain && item.Format == 0) bitmap = await ImageAnalysis.ClipboardDibAsync(item, modelLifetime.Token);
            if (locked || closing || CaptureBlocked || epoch != requested || fingerprint != SensitiveRevealState.Fingerprint(item) || Concealed(item)) return;
            bool copied = clipboard.Write(item, plain, bitmap);
            if (copied) store.MarkUsed(item);
            Notice(copied ? "Copied to clipboard" : "Clipboard is busy. Try again.");
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing) Notice("Could not copy this clip."); }
        finally { if (bitmap is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(bitmap); }
    }
    private async void QueuePaste(HistoryItem item, bool plain = false)
    {
        if (SearchPending) return;
        if (locked || closing || settingsOpen || CaptureBlocked || verifyingReveal || !await RevealAsync(item)) return;
        if (locked || closing || settingsOpen || CaptureBlocked) return;
        long requested = ++epoch; PasteTarget? prior = target;
        // A later navigation, capture, filter, auxiliary window or dismissal revokes this intent.
        bool ready = await DeferredPastePolicy.WaitForReleaseAsync(ModifiersHeld,
            () => SelectionPolicy.IsCurrent(requested, epoch, locked, closing, prior, target)
                && !CaptureBlocked && store.State.Items.Contains(item) && !Concealed(item));
        if (!ready) return;
        byte[]? bitmap = null;
        string fingerprint = SensitiveRevealState.Fingerprint(item);
        try
        {
            if (!plain && item.Format == 0) bitmap = await ImageAnalysis.ClipboardDibAsync(item, modelLifetime.Token);
            if (!SelectionPolicy.IsCurrent(requested, epoch, locked, closing, prior, target) || CaptureBlocked || !store.State.Items.Contains(item) || Concealed(item) || fingerprint != SensitiveRevealState.Fingerprint(item)) return;
            Paste(item, plain, bitmap);
        }
        catch (OperationCanceledException) { }
        catch { if (!locked && !closing && epoch == requested) Notice("The image could not be prepared for native paste. Try Copy again."); }
        finally { if (bitmap is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(bitmap); }
    }
    private static bool ModifiersHeld() => new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (Native.GetAsyncKeyState(key) & 0x8000) != 0);
    private void Paste(HistoryItem item, bool plain = false, byte[]? bitmap = null)
    {
        if (locked || closing || CaptureBlocked || clipboard is null || Concealed(item)) return;
        long requested = ++epoch; PasteTarget? prior = target;
        if (prior is null || input is null || !input.Available || !prior.CanPaste()) { Notice("Paste target unavailable. Use Ctrl+C to copy, then paste in your app."); return; }
        handingOff = true;
        try
        {
            bool restored = false, ready = false, current = false, written = false;
            bool copied = SelectionPolicy.TryWrite(() => ready = prior.CanPaste(), AppWindow.Hide, () => restored = prior.RestoreFocus(),
                () => current = prior.IsVerifiedForeground() && requested == epoch && !locked && !closing && !CaptureBlocked && ReferenceEquals(prior, target), () => written = !CaptureBlocked && !Concealed(item) && clipboard.Write(item, plain, bitmap));
            RecordSyntheticPaste(copied, restored, ready, current, written, requested, epoch);
            if (!copied) { ShowPanel(); Notice("Paste could not complete. Check the original window and try Copy instead."); return; }
            store.MarkUsed(item);
            var result = prior.PasteOnlyIfVerifiedForeground(input);
            store.RecordDiagnostic(result == PasteSubmission.Submitted ? DiagnosticKind.PasteSubmitted : DiagnosticKind.PasteRefused);
            if (result != PasteSubmission.Submitted) { ShowPanel(); Notice("Clip copied. Automatic paste is unavailable; paste manually in your app."); }
        }
        catch { ShowPanel(); Notice("Paste could not complete. Try Copy instead."); }
        finally { bool concealAgain = revealed.Count > 0; revealed.Clear(); if (concealAgain && !closing) Refresh(); handingOff = false; ++epoch; if (ReferenceEquals(target, prior)) { target.Dispose(); target = null; } }
    }
    private void TogglePin(HistoryItem item)
    {
        if (locked || closing) return;
        ++epoch;
        item.Pinned = !item.Pinned; store.Reorder(); store.Save(); Refresh();
    }
    private void Delete(HistoryItem item) { if (locked || closing) return; if (indexingMedia) InvalidateAnalysis(); ++epoch; store.State.Items.Remove(item); store.Save(); PruneIndexes(); Refresh(); }
    private void Key(object sender, KeyRoutedEventArgs e)
    {
        bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0, shift = (Native.GetAsyncKeyState(0x10) & 0x8000) != 0;
        if (settingsOpen || searchInput.Composing) return;
        if (e.Key == VirtualKey.Escape) { e.Handled = true; Dismiss(true); return; }
        if (ctrl && (int)e.Key == 0xBC) { e.Handled = true; ShowSettings(); return; }
        if (ctrl && e.Key == VirtualKey.Q) { e.Handled = true; RequestQuit(); return; }
        if (e.Key == VirtualKey.Enter && e.KeyStatus.WasKeyDown) { e.Handled = true; return; }
        if (e.Key == VirtualKey.Enter && !ctrl && searchInput.Pending) { SubmitSearch(); e.Handled = true; return; }
        if (e.Key == VirtualKey.Enter && SearchPending) { e.Handled = true; return; }
        if (shown.Count == 0) return;
        HistoryItem item = shown[selected];
        if (e.Key == VirtualKey.Application || shift && e.Key == VirtualKey.F10)
        {
            e.Handled = true;
            if (selected < tiles.Count) tiles[selected].ContextFlyout?.ShowAt(tiles[selected]);
            return;
        }
        if (ctrl && e.Key >= VirtualKey.Number1 && e.Key <= VirtualKey.Number9) { e.Handled = true; int index = (int)e.Key - (int)VirtualKey.Number1; if (index < shown.Count) QueuePaste(shown[index], shift); return; }
        if (e.Key == VirtualKey.Enter && !e.Handled) { e.Handled = true; if (ctrl) ShowInspector(item); else QueuePaste(item, shift); return; }
        if (ctrl && e.Key == VirtualKey.O && item.Kind == "Files") { e.Handled = true; OpenFile(item, false); return; }
        if (ctrl && e.Key == VirtualKey.P) { e.Handled = true; TogglePin(item); return; }
        if (ctrl && e.Key == VirtualKey.Back) { e.Handled = true; Delete(item); return; }
        if (ctrl && e.Key == VirtualKey.C && search.SelectionLength == 0) { e.Handled = true; Copy(item, shift); return; }
        bool arrow = store.State.Layout == "strip" ? e.Key is VirtualKey.Left or VirtualKey.Right : e.Key is VirtualKey.Up or VirtualKey.Down;
        if (arrow && (search.Text.Length == 0 || search.FocusState == FocusState.Unfocused || store.State.Layout != "strip"))
        {
            e.Handled = true; ++epoch; selected = Math.Clamp(selected + (e.Key is VirtualKey.Right or VirtualKey.Down ? 1 : -1), 0, shown.Count - 1); Highlight(); RevealSelection();
        }
    }
    private async void OpenFile(HistoryItem item, bool reveal)
    {
        if (locked || closing || CaptureBlocked || item.Kind != "Files" || !await RevealAsync(item)) return;
        if (locked || closing || CaptureBlocked || Concealed(item) || !store.State.Items.Contains(item)) return;
        string path = item.Text.Split('\n')[0].TrimEnd('\r');
        // File verbs are explicit user gestures, never capture-time probes. Keep them local.
        if (path.Length < 3 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\' || !Path.IsPathFullyQualified(path)) { Notice("Open is available for local files. Copy path works for other locations."); return; }
        if (!File.Exists(path) && !Directory.Exists(path)) { Notice("This file is no longer available. You can still copy its path."); return; }
        try
        {
            if (reveal)
            {
                var explorer = new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe")) { UseShellExecute = false };
                explorer.ArgumentList.Add("/select,"); explorer.ArgumentList.Add(path); System.Diagnostics.Process.Start(explorer);
            }
            else System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true, Verb = "open" });
            store.MarkUsed(item); Dismiss(false);
        }
        catch { Notice("Windows could not open this file. You can still copy its path."); }
    }
    private void ShowSettings() => ShowSettings(false);
    private void ShowSettings(bool welcome, string? initialSection = null)
    {
        if (verifyingReveal) return;
        if (settingsOpen || locked) { auxiliary?.Activate(); return; }
        ++epoch; settingsOpen = true;
        bool wasPaused = store.State.Paused;
        var prompts = capturePauses.CreateOwner();
        var window = new DesktopSettingsWindow(store, () => { if (locked || closing) return; ++epoch; PruneIndexes(); AnalysisSettingsChanged(); if (wasPaused != store.State.Paused) { clipboard?.Baseline(); wasPaused = store.State.Paused; } ApplyAppearance(); }, RequestQuit, prompts.Set, () => PrepareSearchAsync(true), () => PrepareImagesAsync(true), () => PrepareSpeechAsync(true), PrepareMediaSettingsAsync, paused => { indexingPaused = paused; searchCancellation.Cancel(); searching = false; rankedKey = ""; if (!paused) { Refresh(); Notice("Semantic indexing resumed."); } }, ForgetIndexesAsync, ForgetImageUnderstandingAsync, agents, () => InvalidateAnalysis(true), welcome, initialSection, indexingPaused);
        window.Closed += (_, _) => prompts.Dispose();
        ShowAuxiliary(window);
    }
    private void ShowAuxiliary(Window window)
    {
        settingsOpen = true; auxiliary = window;
        window.Closed += (_, _) => { auxiliary = null; settingsOpen = false; if (!locked && !closing) PresentPanel(false, false); };
        window.Activate();
        if (window.AppWindow.Presenter is OverlappedPresenter p) p.IsAlwaysOnTop = true;
    }
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint window, uint attribute, ref int value, int size);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
}
