using Cliphoard.Windows;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

internal static class RemainingQualification
{
    [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindow(uint ex, string cls, string title, uint style, int x, int y, int w, int h, nint parent, nint menu, nint instance, nint data);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyWindow(nint window);
    internal static void NumericReuse()
    {
        nint Make() => CreateWindow(0, "STATIC", "", 0, 0, 0, 1, 1, -3, 0, 0, 0);
        nint original = Make();
        if (original == 0) throw new Exception("Hidden fixture window creation failed");
        var stale = WindowStamp.Create(original) ?? throw new Exception("Stamp unavailable");
        if (!DestroyWindow(original) || stale.Valid) throw new Exception("Destroyed target retained authority");
        var clock = Stopwatch.StartNew();
        int iterations = 0;
        bool reused = false, staleRefused = false, newerSurvived = false;
        while (++iterations <= 2_000_000 && clock.Elapsed < TimeSpan.FromSeconds(45))
        {
            nint window = Make();
            if (window == 0) throw new Exception("Bounded reuse fixture creation failed");
            if (window == original)
            {
                reused = true;
                staleRefused = !stale.Valid;
                using var fresh = WindowStamp.Create(window) ?? throw new Exception("Fresh stamp unavailable");
                stale.Dispose();
                newerSurvived = fresh.Valid;
                fresh.Dispose();
                DestroyWindow(window);
                break;
            }
            DestroyWindow(window);
        }
        stale.Dispose();
        var result = new { numeric_reuse = reused, original_hwnd = original.ToInt64(), iterations, elapsed_ms = clock.ElapsedMilliseconds,
            same_process = true, stale_refused = staleRefused, fresh_stamp_survived_stale_disposal = newerSurvived };
        string json = JsonSerializer.Serialize(result);
        File.WriteAllText(@"C:\CliphoardDev\evidence\numeric-hwnd-reuse.json", json);
        Console.WriteLine(json);
        if (reused && (!staleRefused || !newerSurvived)) throw new Exception("Reused HWND inherited stale authority");
    }
}
