namespace Cliphoard.Windows;

// A property belongs to a window incarnation, not a numeric HWND. No pointer or
// payload is placed in the other process; UIPI failure denies the target.
internal sealed class WindowStamp : IDisposable
{
    private readonly nint hwnd;
    private readonly string name = "Cliphoard.Target." + Guid.NewGuid().ToString("N");
    private bool disposed;
    private WindowStamp(nint hwnd) { this.hwnd = hwnd; }
    internal static WindowStamp? Create(nint hwnd)
    {
        var stamp = new WindowStamp(hwnd);
        return Native.SetProp(hwnd, stamp.name, 1) && stamp.Valid ? stamp : null;
    }
    internal bool Valid => !disposed && Native.IsWindow(hwnd) && Native.GetProp(hwnd, name) == 1;
    public void Dispose()
    {
        if (Valid) Native.RemoveProp(hwnd, name);
        disposed = true;
    }
}
