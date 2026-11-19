using Cliphoard.Windows;
using System.Text.Json;
internal static class CaptureSuspensionChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Capture suspension check {checks} failed"); }
        var pauses = new CaptureSuspensions(); Check(!pauses.Active);
        var first = pauses.CreateOwner(); var second = pauses.CreateOwner();
        first.Set(true); first.Set(true); second.Set(true); Check(pauses.Active);
        first.Set(false); Check(pauses.Active); first.Dispose(); Check(pauses.Active);
        first.Set(false); first.Set(true); Check(pauses.Active);
        second.Set(false); Check(!pauses.Active); second.Set(false); Check(!pauses.Active);
        second.Dispose(); second.Dispose(); Check(!pauses.Active);
        var third = pauses.CreateOwner(); third.Set(true); third.Set(true); third.Dispose(); Check(!pauses.Active);
        Console.WriteLine(JsonSerializer.Serialize(new { capture_suspension_checks = checks, status = "passed" }));
    }
}
