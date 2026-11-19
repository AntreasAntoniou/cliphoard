using Cliphoard.Windows;
using System.Runtime.InteropServices;
using System.Text.Json;

internal static class IsolatedDesktopProbe
{
    [DllImport("user32.dll", EntryPoint = "CreateDesktopW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint CreateDesktop(string name, nint device, nint mode, uint flags, uint access, nint security);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetThreadDesktop(nint desktop);
    [DllImport("user32.dll")] private static extern nint GetThreadDesktop(uint thread);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseDesktop(nint desktop);
    internal static Task<string> Run(Func<bool> ownerStillForeground)
    {
        var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var worker = new Thread(() =>
        {
            nint original = GetThreadDesktop(Native.GetCurrentThreadId()), isolated = 0;
            bool created = false, switched = false, restored = false, closed = false;
            uint requested = 0, returned = 0; int error = 0, batches = 0;
            bool disabled = false, noSecond = false; PasteSubmission result = PasteSubmission.Refused; PasteSubmission? second = null;
            string? failure = null;
            try
            {
                // Rights only on this disposable desktop. No SWITCHDESKTOP right or API.
                isolated = CreateDesktop("CliphoardSynthetic." + Guid.NewGuid().ToString("N"), 0, 0, 0, 0x008B, 0);
                created = isolated != 0;
                if (!created) throw new Exception("Private desktop unavailable");
                switched = SetThreadDesktop(isolated);
                if (!switched) throw new Exception("Worker desktop assignment refused");
                using var input = new PasteInput();
                result = input.Submit(ownerStillForeground);
                requested = input.LastRequestedCount; returned = input.LastNativeCount; error = input.LastNativeError;
                batches = input.NativeBatches; disabled = !input.Available;
                if (returned < requested) second = input.Submit(() => true);
                noSecond = batches == input.NativeBatches;
            }
            catch (Exception e) { failure = e.GetType().Name; }
            finally
            {
                restored = SetThreadDesktop(original);
                if (isolated != 0) closed = CloseDesktop(isolated);
            }
            try
            {
            string json = JsonSerializer.Serialize(new { integrity = TokenLevel.Current(), created, worker_switched = switched, visible_desktop_switched = false,
                restored, closed, requested, returned, win32_error = error, result = result.ToString(), automatic_input_disabled = disabled,
                native_batches = batches, second_result = second?.ToString(), no_second_native_call = noSecond, failure });
            File.WriteAllText(@"C:\CliphoardDev\evidence\actual-short-isolated-desktop.json", json);
            completion.SetResult(json);
            }
            catch (Exception e) { completion.TrySetException(e); }
        }) { IsBackground = true, Name = "Owned non-input desktop probe" };
        worker.Start();
        return completion.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }
}
