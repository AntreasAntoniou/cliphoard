namespace Cliphoard.Windows;

/// This decision is checked after every asynchronous selection response and before
/// any clipboard mutation. Native foreground/process validation still happens at paste.
internal static class SelectionPolicy
{
    // Synchronous admission: no clipboard callback runs until focus is restored
    // and the target and response epoch have both been checked again.
    internal static bool TryWrite(Func<bool> ready, Action hide, Func<bool> restore,
        Func<bool> current, Func<bool> write)
    {
        if (!ready()) return false;
        hide();
        return restore() && ready() && current() && write();
    }

    internal static bool IsCurrent(long requestedEpoch, long currentEpoch, bool locked, bool closing,
        object? capturedTarget, object? currentTarget) => !locked && !closing
        && requestedEpoch == currentEpoch && ReferenceEquals(capturedTarget, currentTarget);
}
