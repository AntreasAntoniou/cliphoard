using Cliphoard.Windows;
using System.Runtime.InteropServices;
using System.Text.Json;

internal static class Program
{
    [STAThread] static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.SequenceEqual(new[] { "--prepare-preview-quality" })) { InteractiveFixtures.PreparePreviewQuality(); return; }
        if (args.SequenceEqual(new[] { "--copy-sound-checks" })) { CopySoundChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--brand-checks" })) { BrandChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--workflow-checks" })) { WorkflowBenchmark.Run(); return; }
        if (args.SequenceEqual(new[] { "--prepare-search-evaluation-profile" })) { SearchEvaluation.PrepareProfile(); return; }
        if (args.SequenceEqual(new[] { "--search-evaluation-text" })) { SearchEvaluation.TextAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--search-evaluation-images" })) { SearchEvaluation.ImagesAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--clipboard-formats" })) { Console.WriteLine(JsonSerializer.Serialize(new { png = Native.IsClipboardFormatAvailable(Native.RegisterClipboardFormat("PNG")), dib = Native.IsClipboardFormatAvailable(8), dibv5 = Native.IsClipboardFormatAvailable(17), unicode = Native.IsClipboardFormatAvailable(13), ansi = Native.IsClipboardFormatAvailable(1), sequence = Native.GetClipboardSequenceNumber() })); return; }
        if (args.SequenceEqual(new[] { "--clipboard-image-checks" })) { ClipboardImageChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--forget-image-checks" })) { ForgetImageChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--capture-suspension-checks" })) { CaptureSuspensionChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--interactive-companion-reader" })) { InteractiveCompanionChecks.RunAsync(false).GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--interactive-companion-writer" })) { InteractiveCompanionChecks.RunAsync(true).GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--streaming-archive-checks" })) { StreamingArchiveChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--prepare-interactive-assets" })) { InteractiveFixtures.PrepareAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--interactive-fail-writes" })) { InteractiveFixtures.Fault(true); return; }
        if (args.SequenceEqual(new[] { "--interactive-restore-writes" })) { InteractiveFixtures.Fault(false); return; }
        if (args.SequenceEqual(new[] { "--inspect-interactive-profile" })) { InteractiveFixtures.Inspect(); return; }
        if (args.SequenceEqual(new[] { "--media-index-checks" })) { MediaIndexChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--media-decode-checks" })) { MediaDecodeChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--manager-import-checks" })) { ManagerImportChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--companion-checks" })) { CompanionChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--agent-writer-checks" })) { AgentWriterChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--agent-controller-checks" })) { AgentControllerChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--suspension-checks" })) { SuspensionChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--agent-directory-checks" })) { AgentDirectoryChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--agent-protocol-checks" })) { AgentProtocolChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--distribution-checks" })) { DistributionChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--perceptual-checks" })) { PerceptualChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--storage-parity-checks" })) { StorageParityChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--embedding-cache-checks" })) { EmbeddingCacheChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--screening-checks" })) { ScreeningChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--document-checks" })) { DocumentChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--tag-parity-checks" })) { TagParityChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--detector-parity-checks" })) { DetectorParityChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--parity-policy-checks" })) { ParityPolicyChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--hashing-checks" })) { HashingChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--model-switch-checks" })) { ModelSwitchChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--speech-boundary-checks" })) { SpeechBoundaryChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--worker-parent-fixture" })) { WorkerLifetimeChecks.ParentFixtureAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--worker-lifetime-checks" })) { WorkerLifetimeChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--speech-checks" })) { SpeechChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--gemma-checks" })) { GemmaChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--openvision-checks" })) { OpenVisionChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--ogma-checks" })) { OgmaChecks.RunAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--mac-archive-checks" })) { ParityChecks.ArchiveAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--semantic-checks" })) { ParityChecks.SemanticAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--ocr-checks" })) { ParityChecks.OcrAsync().GetAwaiter().GetResult(); return; }
        if (args.SequenceEqual(new[] { "--archive-checks" })) { ArchiveChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--feature-checks" })) { FeatureChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--theme-checks" })) { ThemeChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--history-checks" })) { HistoryChecks.Run(); return; }
        if (args.SequenceEqual(new[] { "--normal-editor" })) { Application.Run(new NormalEditor()); return; }
        if (args.SequenceEqual(new[] { "--numeric-reuse" })) { RemainingQualification.NumericReuse(); return; }
        if (args.SequenceEqual(new[] { "--sequence" })) { Console.WriteLine(Native.GetClipboardSequenceNumber()); return; }
        if (args.SequenceEqual(new[] { "--integrity" })) { Console.WriteLine(TokenLevel.Current()); return; }
        if (args.SequenceEqual(new[] { "--control" })) { Application.Run(new BoundaryController()); return; }
        if (args.SequenceEqual(new[] { "--elevated-editor" })) { if (TokenLevel.Current() < 0x3000) throw new Exception("Elevated target requires UAC"); Application.Run(new Editor(true)); return; }
        if (args.SequenceEqual(new[] { "--editor" })) { Application.Run(new Editor()); return; }
        // A misspelled suite must never fall through to interactive input tests.
        if (args.Length != 0) { Console.Error.WriteLine("Unknown native fixture option."); Environment.Exit(78); return; }
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Native fixture check {checks} failed"); }
        using var first = new Form();
        nint original = first.Handle;
        using var stamp = WindowStamp.Create(original);
        Check(stamp is not null && stamp.Valid);
        first.Dispose();
        Check(!stamp!.Valid);
        using var replacement = new Form();
        nint next = replacement.Handle;
        Check(!stamp.Valid);
        using var newer = WindowStamp.Create(next);
        Check(newer is not null && newer.Valid);
        newer!.Dispose(); Check(!newer.Valid);
        // Actual collision uses the same Win32 API and modifiers, not a posted WM_HOTKEY.
        Check(Native.RegisterHotKey(next, 71, 0x4007, 0x56));
        Check(!Native.RegisterHotKey(0, 72, 0x4007, 0x56));
        Check(Marshal.GetLastWin32Error() == 1409);
        Check(Native.UnregisterHotKey(next, 71));
        Check(Native.RegisterHotKey(0, 72, 0x4007, 0x56));
        Check(Native.UnregisterHotKey(0, 72));
        Check(Marshal.SizeOf<Native.Input>() == 40);
        Console.WriteLine(JsonSerializer.Serialize(new { native_checks = checks, status = "passed", same_numeric_hwnd = original == next }));
    }
}
internal sealed partial class Editor : Form
{
    private readonly FixtureTextBox editor = new() { Multiline = true, Dock = DockStyle.Fill, Font = new Font("Consolas", 14) };
    private readonly Label status = new() { Dock = DockStyle.Bottom, Height = 70 };
    private int changes;
    private bool clipboardChangedWithFocus;
    private bool probing;
    private uint changedSequence;
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.AddClipboardFormatListener(Handle); }
    protected override void OnHandleDestroyed(EventArgs e) { Native.RemoveClipboardFormatListener(Handle); base.OnHandleDestroyed(e); }
    protected override void WndProc(ref Message message)
    {
        if (message.Msg == Native.WM_CLIPBOARDUPDATE) { clipboardChangedWithFocus = Native.GetForegroundWindow() == Handle && editor.Focused; changedSequence = Native.GetClipboardSequenceNumber(); Save(); }
        base.WndProc(ref message);
    }
    private readonly bool elevated;
    private string Evidence => elevated ? @"C:\CliphoardDev\evidence\editor-high-receipt.json" : @"C:\CliphoardDev\evidence\editor-receipt.json";
    internal Editor(bool elevated = false)
    {
        this.elevated = elevated;
        Text = elevated ? "Cliphoard SYNTHETIC elevated editor" : "Cliphoard SYNTHETIC editor"; Width = 1000; Height = 450; StartPosition = FormStartPosition.CenterScreen;
        var clear = new Button { Text = "Clear synthetic editor", Dock = DockStyle.Top, Height = 40 };
        clear.Click += (_, _) => { editor.Clear(); editor.Focus(); Save(); };
        var partial = new Button { Text = "Run native partial-input cleanup tests", Dock = DockStyle.Top, Height = 40 };
        partial.Enabled = !elevated;
        partial.Click += async (_, _) => await TestPartialInput();
        Controls.Add(editor); Controls.Add(clear); Controls.Add(partial); Controls.Add(status);
        if (elevated)
        {
            var blocked = new Button { Text = "Run bounded guest input-block probe (at most 500ms wait)", Dock = DockStyle.Top, Height = 40 };
            blocked.Click += async (_, _) => await RunBlockedProbe();
            Controls.Add(blocked);
        }
        editor.TextChanged += (_, _) => { ++changes; Save(); };
        Shown += (_, _) => { editor.Focus(); Save(); };
    }
    private async Task TestPartialInput()
    {
        if (probing) return;
        probing = true;
        try
        {
        // Let the initiating Space key-up finish before focusing the editor.
        await Task.Delay(150);
        var receipts = new List<object>();
        foreach (uint prefix in new uint[] { 0, 1, 2, 3 })
        {
            Clipboard.SetText("[CLIPHOARD_SYNTHETIC_V1] Partial-input probe");
            editor.Clear(); editor.Focus();
            int batches = 0;
            var result = PasteInputPolicy.Submit(() => Native.GetForegroundWindow() == Handle && editor.Focused,
                keys =>
                {
                    var actual = ++batches == 1 ? keys.Take((int)prefix).ToArray() : keys;
                    if (actual.Length == 0) return 0;
                    var inputs = actual.Select(key => new Native.Input { Type = 1, Data = new Native.InputUnion {
                        Keyboard = new Native.KeyboardInput { Key = key.Key, Flags = key.Up ? 2u : 0u }
                    }}).ToArray();
                    return Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.Input>());
                }, _ => false);
            await Task.Delay(100);
            bool released = (Native.GetAsyncKeyState(PasteInputPolicy.Control) & 0x8000) == 0 && (Native.GetAsyncKeyState(PasteInputPolicy.V) & 0x8000) == 0;
            receipts.Add(new { prefix, result = result.ToString(), released, characters = editor.TextLength });
        }
        File.WriteAllText(@"C:\CliphoardDev\evidence\partial-input-native.json", JsonSerializer.Serialize(receipts));
        editor.Clear(); editor.Focus(); Save();
        }
        finally { probing = false; }
    }
    private void Save()
    {
        string text = editor.Text;
        bool synthetic = text.Length == 0 || text.StartsWith("[CLIPHOARD_SYNTHETIC_V1] ", StringComparison.Ordinal);
        status.Text = $"Synthetic editor: characters={text.Length}; paste messages={editor.Pastes}; changes={changes}; focused={editor.Focused}";
        // Only the test's own generated output is recorded, never arbitrary clipboard text.
        File.WriteAllText(Evidence, JsonSerializer.Serialize(new { pid = Environment.ProcessId, session = System.Diagnostics.Process.GetCurrentProcess().SessionId, hwnd = Handle.ToInt64(), integrity = TokenLevel.Current(), synthetic, text = synthetic ? text : null, characters = text.Length, paste_messages = editor.Pastes, changes, focused = editor.Focused, foreground = Native.GetForegroundWindow() == Handle, sequence = Native.GetClipboardSequenceNumber(), clipboard_changed_with_focus = clipboardChangedWithFocus, changed_sequence = changedSequence }));
    }
    private sealed class FixtureTextBox : TextBox
    {
        internal int Pastes;
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x302) ++Pastes;
            base.WndProc(ref message);
        }
    }
}
