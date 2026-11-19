using System.Reflection;
using System.Text.Json;
using Cliphoard.Windows;

internal static class DetectorParityChecks
{
    internal static void Run()
    {
        using var fixture = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.Detectors.json") ?? throw new IOException("Detector references missing.");
        using var json = JsonDocument.Parse(fixture);
        int checks = 0;
        foreach (var sample in json.RootElement.GetProperty("samples").EnumerateArray())
        {
            string text = sample.GetProperty("text").GetString()!;
            // Generate fake vendor-token material at runtime rather than storing
            // a key-shaped literal in source or the embedded golden fixture.
            if (text == "__CLIPHOARD_SYNTHETIC_STRIPE_LIVE__")
                text = "sk_" + "live_" + new string('A', 24);
            string? source = sample.TryGetProperty("source", out var origin) ? origin.GetString() : null;
            long expected = sample.GetProperty("flags").GetInt64();
            long actual = ContentSafety.Flags(text, source);
            ++checks;
            if (actual != expected) throw new Exception($"Synthetic detector golden {checks} failed: expected flags {expected}, actual {actual}.");
        }
        CheckShape("{\"synthetic\":true}", "json");
        CheckShape("ordinary synthetic prose", null);
        CheckShape("# heading example", null);
        CheckShape("# docker ps", "command");
        CheckShape("git status", "command");
        CheckShape("key: value\nother: synthetic", "yaml");
        CheckShape("/synthetic/report.txt", "path");
        CheckShape("#aabbcc", "color");
        void CheckShape(string text, string? expected)
        {
            ++checks;
            if (ContentShape.Of(text) != expected) throw new Exception("Synthetic structural-shape check failed.");
        }
        Console.WriteLine(JsonSerializer.Serialize(new { detector_parity_checks = checks, status = "passed", reference = "shipping Mac Detectors.swift" }));
    }
}
