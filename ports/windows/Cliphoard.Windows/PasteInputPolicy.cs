namespace Cliphoard.Windows;

internal readonly record struct PasteKey(ushort Key, bool Up);
internal enum PasteSubmission { Refused, Submitted, PartialCleaned, PartialUnresolved }
internal static class PasteInputPolicy
{
    internal const ushort Control = 0xA2, V = 0x56; // Own only LEFT Ctrl, never generic/right Ctrl.
    internal static readonly PasteKey[] Chord = { new(Control, false), new(V, false), new(V, true), new(Control, true) };
    internal static PasteSubmission Submit(Func<bool> admitted, Func<PasteKey[], uint> send, Func<ushort, bool> externallyHeld)
    {
        if (!admitted()) return PasteSubmission.Refused;
        uint sent = send(Chord);
        if (sent == 4) return PasteSubmission.Submitted;
        if (sent > 4) return PasteSubmission.PartialUnresolved;
        // Only unmatched key-downs in the accepted prefix are ours to release.
        var releases = new List<PasteKey>();
        if (sent == 2 && !externallyHeld(V)) releases.Add(new(V, true));
        if (sent is >= 1 and <= 3 && !externallyHeld(Control)) releases.Add(new(Control, true));
        return releases.Count == 0 || send(releases.ToArray()) == releases.Count
            ? PasteSubmission.PartialCleaned : PasteSubmission.PartialUnresolved;
    }
}
