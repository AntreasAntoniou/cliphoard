using Microsoft.UI.Xaml;
using Microsoft.UI.Windowing;
using System.Text;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using System.Text.Json;
using Windows.System;
namespace Cliphoard.Windows;

public sealed partial class MainWindow : Window
{
    private FixtureEngine? engine;
    private FixtureClipboard? clipboard;
    private NativeWindowAdapter? native;
    private PasteTarget? target;
    private PasteInput? pasteInput;
    private bool locked, closing, handingOff;
    private int nextSelectionDelay;
    private long searchRevision, panelEpoch;
    private sealed record Row(string Id, string Text, bool Pinned);
    private List<Row> displayedRows = new();
    public MainWindow() { InitializeComponent(); Root.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnKeyDown), true); }
    internal async void InitializeFixture()
    {
        try
        {
            nint hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
            engine = new FixtureEngine(); clipboard = new FixtureClipboard(hwnd); native = new NativeWindowAdapter(hwnd);
            pasteInput = new PasteInput();
            native.ClipboardChanged += OnClipboardUpdate;
            native.Shortcut += ShowPanel;
            native.SessionRevoked += LockFromSession;
            Activated += (_, e) => { if (e.WindowActivationState == WindowActivationState.Deactivated) { if (!handingOff) ++panelEpoch; if (!closing) AppWindow.Hide(); } };
            Closed += OnClosed;
            if (AppWindow.Presenter is OverlappedPresenter presenter)
            {
                presenter.SetBorderAndTitleBar(false, false); presenter.IsResizable = false;
                presenter.IsMinimizable = false; presenter.IsMaximizable = false;
            }
            native.PositionAtBottom(AppWindow);
            await engine.CallAsync(new { op = "hello" });
            await RefreshAsync();
            Status.Text = "Synthetic fixture ready. Ctrl+Alt+Shift+B (VM alternative) or Ctrl+Alt+Shift+V; no-repeat; deliveries=0.";
            FixtureAudit.Record("ready", new { pid = Environment.ProcessId, locked, epoch = panelEpoch });
        }
        catch { Status.Text = $"Fixture unavailable. Hotkey registration error={NativeWindowAdapter.RegistrationError}. Production IPC remains disabled."; await StopEngineAsync(); }
    }
    private void ShowPanel()
    {
        ++panelEpoch;
        if (locked || native is null) return;
        target?.Dispose(); target = PasteTarget.Capture(WinRT.Interop.WindowNative.GetWindowHandle(this));
        try { native.PositionAtBottom(AppWindow); AppWindow.Show(); Activate();
            nint own = WinRT.Interop.WindowNative.GetWindowHandle(this);
            if (!Native.SetForegroundWindow(own) || Native.GetForegroundWindow() != own)
            {
                ++panelEpoch; AppWindow.Hide(); target?.Dispose(); target = null; return;
            }
            Query.Focus(FocusState.Programmatic);
            Status.Text = $"{native.LastShortcut}; deliveries={native.ShortcutDeliveries}; foreground={Native.GetForegroundWindow() == WinRT.Interop.WindowNative.GetWindowHandle(this)}."; }
        catch { Status.Text = "Panel unavailable."; }
    }
    private async Task RefreshAsync()
    {
        if (engine is null || locked) return;
        if (Encoding.UTF8.GetByteCount(Query.Text) > 512) { Status.Text = "Search is limited to512 UTF8 bytes."; return; }
        long revision = ++searchRevision;
        JsonElement result = await engine.CallAsync(new { op = "search", query = Query.Text, limit = 20 });
        if (revision != searchRevision || locked) return;
        // Avoid reflection binding to a private CLR record across the WinRT boundary.
        displayedRows = result.GetProperty("items").EnumerateArray()
            .Select(i => new Row(i.GetProperty("id").GetString()!, i.GetProperty("text").GetString()!, i.GetProperty("pinned").GetBoolean())).ToList();
        History.ItemsSource = displayedRows.Select(row => row.Text).ToList();
    }
    private async void OnSeed(object sender, RoutedEventArgs args)
    {
        if (engine is null || locked) return;
        try { foreach (string text in new[] { "A synthetic blue square", "A synthetic rust compiler note", "A synthetic café example" }) await engine.CallAsync(new { op = "captureSyntheticText", text = FixtureEngine.Prefix + text }); await RefreshAsync(); }
        catch { Status.Text = "Fixture request failed."; }
    }
    private void OnClipboardFixture(object sender, RoutedEventArgs args)
    {
        if (locked || clipboard is null) return;
        Status.Text = clipboard.WriteSynthetic(FixtureEngine.Prefix + "Native clipboard fixture", false)
            ? "Wrote an explicit marked synthetic clipboard fixture." : "Clipboard busy; fixture was not written.";
    }
    private async void OnClipboardUpdate()
    {
        if (engine is null || clipboard is null || locked) return;
        try { string? text = clipboard.ReadMarkedUpdate(); if (text is null) return; await engine.CallAsync(new { op = "captureSyntheticText", text }); await RefreshAsync(); }
        catch { Status.Text = "Marked fixture capture failed."; }
    }
    private async void OnSearch(object sender, TextChangedEventArgs args)
    {
        ++panelEpoch;
        try { await RefreshAsync(); } catch { Status.Text = "Fixture search failed."; }
    }
    private async void OnSelect(object sender, ItemClickEventArgs args)
    {
        int index = History.Items.IndexOf(args.ClickedItem);
        if (index >= 0 && index < displayedRows.Count) await SelectAsync(displayedRows[index]);
    }
    private async void OnPasteSelected(object sender, RoutedEventArgs args)
    {
        int index = History.SelectedIndex;
        if (index >= 0 && index < displayedRows.Count) await SelectAsync(displayedRows[index]);
    }
    private async Task SelectAsync(Row row)
    {
        if (engine is null || clipboard is null || locked) return;
        long requestedEpoch = ++panelEpoch;
        PasteTarget? selectedTarget = target;
        FixtureAudit.Record("selection-start", new { epoch = requestedEpoch, sequence = Native.GetClipboardSequenceNumber() });
        try
        {
            int delay = nextSelectionDelay; nextSelectionDelay = 0;
            if (delay != 0) await Task.Delay(delay);
            if (!SelectionPolicy.IsCurrent(requestedEpoch, panelEpoch, locked, closing, selectedTarget, target))
            {
                FixtureAudit.Record("stale-selection-refused", new { requestedEpoch, epoch = panelEpoch, locked, sequence = Native.GetClipboardSequenceNumber() }); return;
            }
            JsonElement result = await engine.CallAsync(new { op = "select", itemId = row.Id });
            if (!SelectionPolicy.IsCurrent(requestedEpoch, panelEpoch, locked, closing, selectedTarget, target)
                || !result.GetProperty("synthetic").GetBoolean()) return;
            string text = result.GetProperty("text").GetString()!;
            // Finish admission before mutating even the marked fixture clipboard.
            if (selectedTarget is null || pasteInput is null || !pasteInput.Available || !selectedTarget.CanPaste()) { Status.Text = "Selection refused: target/input unavailable or modifiers held."; return; }
            handingOff = true;
            try
            {
                bool copied = SelectionPolicy.TryWrite(selectedTarget.CanPaste, AppWindow.Hide,
                    selectedTarget.RestoreFocus,
                    () => selectedTarget.IsVerifiedForeground() && SelectionPolicy.IsCurrent(requestedEpoch, panelEpoch, locked, closing, selectedTarget, target),
                    () => clipboard.WriteSynthetic(text, true));
                if (!copied) { Status.Text = "Selection refused: focus, target, epoch or clipboard unavailable."; return; }
                PasteSubmission submission = selectedTarget.PasteOnlyIfVerifiedForeground(pasteInput);
                Status.Text = submission == PasteSubmission.Submitted ? "Synthetic text copied; one paste input submitted."
                    : $"Synthetic text copied; paste result={submission}. Partial input disables automatic paste until restart.";
            }
            finally
            {
                handingOff = false; ++panelEpoch;
                if (ReferenceEquals(target, selectedTarget)) { target?.Dispose(); target = null; }
            }
        }
        catch { Status.Text = "Fixture selection failed."; }
    }
    private async void OnClear(object sender, RoutedEventArgs args)
    {
        ++panelEpoch;
        if (engine is null || locked) return;
        try { await engine.CallAsync(new { op = "clearSynthetic" }); await RefreshAsync(); } catch { Status.Text = "Clear refused."; }
    }
    private async void OnLock(object sender, RoutedEventArgs args) => await LockAsync();
    private async void LockFromSession(uint reason, uint session)
    {
        FixtureAudit.Record("session-event", new { reason, session, locked, epoch = panelEpoch, sequence = Native.GetClipboardSequenceNumber() });
        await LockAsync();
    }
    private async Task LockAsync()
    {
        if (locked) return;
        locked = true; ++panelEpoch; ++searchRevision; History.ItemsSource = null; Query.Text = ""; AppWindow.Hide();
        target?.Dispose(); target = null;
        try
        {
            if (engine is not null)
            {
                JsonElement result = await engine.CallAsync(new { op = "lock" });
                FixtureAudit.Record("purged", new { locked, epoch = panelEpoch, count = result.GetProperty("count").GetInt32(), sequence = Native.GetClipboardSequenceNumber() });
            }
        }
        catch { await StopEngineAsync(); }
        Status.Text = "Locked and volatile fixture history purged. Restart fixture to resume.";
    }
    private async void OnKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.F6 || args.Key == VirtualKey.F8) { nextSelectionDelay = args.Key == VirtualKey.F6 ? 1000 : 5000; args.Handled = true; Status.Text = $"Next synthetic selection waits {nextSelectionDelay} ms for stale-response qualification."; return; }
        // ListView can commit through ItemClick while marking Enter handled.
        // Do not start a second selection or consume a test delay twice.
        if (args.Key == VirtualKey.Enter && !args.Handled && History.SelectedIndex >= 0 && History.SelectedIndex < displayedRows.Count)
        {
            args.Handled = true; await SelectAsync(displayedRows[History.SelectedIndex]); return;
        }
        if (args.Key != VirtualKey.Escape) return;
        ++panelEpoch; args.Handled = true; AppWindow.Hide(); target?.RestoreFocus(); target?.Dispose(); target = null;
    }
    private async void OnClosed(object sender, WindowEventArgs args) { closing = true; ++panelEpoch; native?.Dispose(); target?.Dispose(); pasteInput?.Dispose(); await StopEngineAsync(); }
    private async Task StopEngineAsync() { FixtureEngine? old = engine; engine = null; if (old is not null) await old.DisposeAsync(); }
}
