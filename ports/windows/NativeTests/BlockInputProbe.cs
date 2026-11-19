using Cliphoard.Windows;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

internal sealed partial class Editor
{
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool BlockInput(bool block);
    private async Task RunBlockedProbe()
    {
        if (!elevated || probing) return;
        probing = true;
        try
        {
            await Task.Delay(200); // Finish the initiating click/key before sampling held keys.
            editor.Clear(); editor.Focus();
            Clipboard.SetText("[CLIPHOARD_SYNTHETIC_V1] Bounded blocked-input probe");
            uint sequence = Native.GetClipboardSequenceNumber();
            nint own = Handle;
            using var input = new PasteInput();
            using var ready = new ManualResetEventSlim();
            using var go = new ManualResetEventSlim();
            using var done = new ManualResetEventSlim();
            int active = 0;
            PasteSubmission result = PasteSubmission.Refused;
            PasteSubmission? second = null;
            int firstBatches = 0;
            var worker = new Thread(() =>
            {
                ready.Set(); go.Wait();
                try
                {
                    result = input.Submit(() => Volatile.Read(ref active) == 1 && Native.GetForegroundWindow() == own
                        && new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C, 0x56 }.All(k => (Native.GetAsyncKeyState(k) & 0x8000) == 0));
                    firstBatches = input.NativeBatches;
                    if (input.LastNativeCount < input.LastRequestedCount) second = input.Submit(() => true);
                }
                finally { done.Set(); }
            }) { IsBackground = true, Name = "Owned SendInput blocked-thread probe" };
            worker.Start();
            if (!ready.Wait(2000)) throw new Exception("Worker did not become ready");
            bool granted = false, released = false, completed;
            var clock = Stopwatch.StartNew();
            try
            {
                granted = BlockInput(true); // This UI thread alone owns the block.
                Volatile.Write(ref active, granted ? 1 : 0);
                go.Set();
                completed = done.Wait(500); // Hard bounded wait, not an input-block retry loop.
            }
            finally
            {
                Volatile.Write(ref active, 0);
                if (granted) released = BlockInput(false); // Same thread, always finally.
                go.Set();
            }
            long blockedMs = clock.ElapsedMilliseconds;
            bool joined = worker.Join(1000);
            await Task.Delay(100);
            var receipt = new { integrity = TokenLevel.Current(), block_granted = granted, block_released = released,
                bounded_wait_ms = 500, elapsed_block_scope_ms = blockedMs, completed, worker_joined = joined,
                requested = input.LastRequestedCount, returned = input.LastNativeCount, win32_error = input.LastNativeError,
                result = result.ToString(), automatic_input_disabled = !input.Available, native_batches = input.NativeBatches,
                second_result = second?.ToString(), no_second_native_call = input.NativeBatches == firstBatches,
                characters = editor.TextLength, paste_messages = editor.Pastes,
                clipboard_sequence_before_input = sequence, clipboard_sequence_after_input = Native.GetClipboardSequenceNumber(),
                control_released = (Native.GetAsyncKeyState(0xA2) & 0x8000) == 0, v_released = (Native.GetAsyncKeyState(0x56) & 0x8000) == 0 };
            string json = JsonSerializer.Serialize(receipt);
            File.WriteAllText(@"C:\CliphoardDev\evidence\actual-short-blocked-thread.json", json);
            status.Text = json;
        }
        finally { probing = false; }
    }
}
