namespace Cliphoard.Windows;

/// Wait only for physical modifier release, bounded and invalidated by any newer UI intent.
internal static class DeferredPastePolicy
{
    internal static async Task<bool> WaitForReleaseAsync(Func<bool> held, Func<bool> current,
        Func<Task>? wait = null)
    {
        wait ??= () => Task.Delay(15);
        for (int attempt = 0; attempt < 28; ++attempt)
        {
            if (!current()) return false;
            if (!held()) return true;
            await wait();
        }
        return current() && !held();
    }
}
