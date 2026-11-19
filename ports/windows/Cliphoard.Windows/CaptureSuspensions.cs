namespace Cliphoard.Windows;

/// UI-thread accounting gives each native prompt owner an independent pause lifetime.
internal sealed class CaptureSuspensions
{
    private int count;
    internal bool Active => count != 0;
    internal event Action? Changed;
    internal Owner CreateOwner() => new(this);
    internal sealed class Owner(CaptureSuspensions parent) : IDisposable
    {
        private int count;
        private bool disposed;
        internal void Set(bool paused)
        {
            if (disposed || !paused && count == 0) return;
            if (paused) { count = checked(count + 1); parent.count = checked(parent.count + 1); }
            else { --count; --parent.count; }
            parent.Changed?.Invoke();
        }
        public void Dispose()
        {
            if (disposed) return; disposed = true; parent.count -= count; count = 0; parent.Changed?.Invoke();
        }
    }
}
