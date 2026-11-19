using Cliphoard.Windows;
object original = new(), replacement = new();
int checks = 0;
void Check(bool condition) { ++checks; if (!condition) throw new Exception("Synthetic selection policy failed"); }
Check(SelectionPolicy.IsCurrent(4, 4, false, false, original, original));
foreach (long afterDismissal in new long[] { 5, 6, 7, 8 }) Check(!SelectionPolicy.IsCurrent(4, afterDismissal, false, false, original, original));
Check(!SelectionPolicy.IsCurrent(4, 4, false, false, original, replacement));
Check(!SelectionPolicy.IsCurrent(4, 4, true, false, original, original));
Check(!SelectionPolicy.IsCurrent(4, 4, false, true, original, original));
Check(SelectionPolicy.IsCurrent(4, 4, false, false, null, null)); // Epoch identity alone does not authorize a clipboard write.
Console.WriteLine($"{{\"synthetic_checks\":{checks},\"status\":\"passed\"}}");

// Exercise side-effect ordering and every failure boundary using synthetic callbacks.
foreach (int failure in new[] { -1, 0, 1, 2, 3, 4 })
{
    var calls = new List<string>();
    int readyCalls = 0;
    bool wrote = false;
    bool result = SelectionPolicy.TryWrite(
        () => { calls.Add("ready"); return failure != (readyCalls++ == 0 ? 0 : 2); },
        () => calls.Add("hide"),
        () => { calls.Add("focus"); return failure != 1; },
        () => { calls.Add("epoch"); return failure != 3; },
        () => { calls.Add("write"); wrote = true; return failure != 4; });
    Check(result == (failure == -1));
    Check(wrote == (failure == -1 || failure == 4));
    if (wrote) Check(string.Join(",", calls) == "ready,hide,focus,ready,epoch,write");
}
Console.WriteLine($"{{\"selection_and_handoff_checks\":{checks},\"status\":\"passed\"}}");

// Every possible partial prefix, external ownership combination, and cleanup failure.
for (uint prefix = 0; prefix <= 4; ++prefix)
foreach (bool ctrlHeld in new[] { false, true })
foreach (bool vHeld in new[] { false, true })
foreach (bool cleanupWorks in new[] { false, true })
{
    var batches = new List<PasteKey[]>();
    var result = PasteInputPolicy.Submit(() => true,
        keys => { batches.Add(keys.ToArray()); return batches.Count == 1 ? prefix : cleanupWorks ? (uint)keys.Length : 0; },
        key => key == PasteInputPolicy.Control ? ctrlHeld : vHeld);
    Check(batches[0].SequenceEqual(PasteInputPolicy.Chord));
    if (prefix == 4) { Check(result == PasteSubmission.Submitted && batches.Count == 1); continue; }
    var expected = new List<PasteKey>();
    if (prefix == 2 && !vHeld) expected.Add(new(PasteInputPolicy.V, true));
    if (prefix >= 1 && prefix <= 3 && !ctrlHeld) expected.Add(new(PasteInputPolicy.Control, true));
    Check(batches.Count == (expected.Count == 0 ? 1 : 2));
    if (expected.Count != 0) Check(batches[1].SequenceEqual(expected));
    Check(result == (expected.Count == 0 || cleanupWorks ? PasteSubmission.PartialCleaned : PasteSubmission.PartialUnresolved));
}
Check(PasteInputPolicy.Submit(() => false, _ => throw new Exception("Refused admission sent input"), _ => false) == PasteSubmission.Refused);
Console.WriteLine($"{{\"total_policy_checks\":{checks},\"status\":\"passed\"}}");

// Real quick-paste waits may race new keyboard, mouse, capture or dismissal intents.
int deferredChecks = 0;
void DeferredCheck(bool condition) { ++deferredChecks; if (!condition) throw new Exception("Deferred paste policy failed"); }
foreach (int releaseAfter in new[] { 0, 1, 27, 28, 29 })
{
    int waits = 0;
    bool ready = await DeferredPastePolicy.WaitForReleaseAsync(() => waits < releaseAfter, () => true,
        () => { ++waits; return Task.CompletedTask; });
    DeferredCheck(ready == (releaseAfter <= 28));
    DeferredCheck(waits == Math.Min(releaseAfter, 28));
}
foreach (int revokedAfter in new[] { 0, 1, 14, 27, 28 })
{
    int waits = 0;
    bool ready = await DeferredPastePolicy.WaitForReleaseAsync(() => waits < 28, () => waits < revokedAfter,
        () => { ++waits; return Task.CompletedTask; });
    DeferredCheck(!ready);
    DeferredCheck(waits == revokedAfter);
}
int heldCalls = 0;
DeferredCheck(!await DeferredPastePolicy.WaitForReleaseAsync(() => { ++heldCalls; return false; }, () => false));
DeferredCheck(heldCalls == 0);
Console.WriteLine($"{{\"deferred_paste_checks\":{deferredChecks},\"status\":\"passed\"}}");
