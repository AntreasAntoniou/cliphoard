using System.Runtime.InteropServices;
namespace Cliphoard.Windows;

// Tracks ownership of just the two injected keys, never text or other key codes.
// A dedicated hook thread stays responsive during SendInput on the UI thread.
internal sealed class PasteInput : IDisposable
{
    private readonly Thread thread;
    private readonly ManualResetEventSlim ready = new(false);
    private readonly Native.KeyboardHook callback;
    private readonly nuint marker = (nuint)Random.Shared.NextInt64(1, long.MaxValue);
    private nint hook;
    private uint threadId;
    private int controlHeld, vHeld;
    private bool disabled;
    internal int NativeBatches { get; private set; }
    internal uint LastRequestedCount { get; private set; }
    internal uint LastNativeCount { get; private set; }
    internal int LastNativeError { get; private set; }
    internal PasteInput()
    {
        callback = Observe;
        thread = new Thread(Run) { IsBackground = true, Name = "Cliphoard paste key ownership" };
        thread.Start();
        if (!ready.Wait(TimeSpan.FromSeconds(2))) disabled = true;
    }
    private void Run()
    {
        threadId = Native.GetCurrentThreadId();
        controlHeld = (Native.GetAsyncKeyState(PasteInputPolicy.Control) & 0x8000) != 0 ? 1 : 0;
        vHeld = (Native.GetAsyncKeyState(PasteInputPolicy.V) & 0x8000) != 0 ? 1 : 0;
        hook = Native.SetWindowsHookEx(13, callback, Native.GetModuleHandle(null), 0);
        ready.Set();
        if (hook == 0) return;
        while (Native.GetMessage(out _, 0, 0, 0) > 0) { }
        Native.UnhookWindowsHookEx(hook); hook = 0;
    }
    private nint Observe(int code, nuint message, nint data)
    {
        if (code >= 0)
        {
            var key = Marshal.PtrToStructure<Native.KeyboardHookData>(data);
            if ((key.Flags & 0x10) == 0 || key.Extra != marker)
            {
                int down = (key.Flags & 0x80) == 0 ? 1 : 0;
                if (key.Key == PasteInputPolicy.Control) Volatile.Write(ref controlHeld, down);
                else if (key.Key == PasteInputPolicy.V) Volatile.Write(ref vHeld, down);
            }
        }
        return Native.CallNextHookEx(0, code, message, data);
    }
    internal bool Available => !disabled && hook != 0 && thread.IsAlive;
    private bool Held(ushort key) => (key == PasteInputPolicy.Control ? Volatile.Read(ref controlHeld) : Volatile.Read(ref vHeld)) != 0;
    internal PasteSubmission Submit(Func<bool> admitted)
    {
        if (!Available) return PasteSubmission.Refused;
        var result = PasteInputPolicy.Submit(() => Available && !Held(PasteInputPolicy.Control) && !Held(PasteInputPolicy.V) && admitted(), Send, Held);
        // Never retry a chord: even a partial batch could have caused one insertion.
        if (result is PasteSubmission.PartialCleaned or PasteSubmission.PartialUnresolved) disabled = true;
        return result;
    }
    private uint Send(PasteKey[] keys)
    {
        var inputs = keys.Select(key => new Native.Input { Type = 1, Data = new Native.InputUnion {
            Keyboard = new Native.KeyboardInput { Key = key.Key, Flags = key.Up ? 2u : 0u, Extra = marker }
        }}).ToArray();
        ++NativeBatches; LastRequestedCount = (uint)inputs.Length;
        LastNativeCount = Native.SendInput(LastRequestedCount, inputs, Marshal.SizeOf<Native.Input>());
        LastNativeError = Marshal.GetLastWin32Error();
        return LastNativeCount;
    }
    public void Dispose()
    {
        disabled = true;
        if (thread.IsAlive) { Native.PostThreadMessage(threadId, 0x0012, 0, 0); thread.Join(1000); }
    }
}
