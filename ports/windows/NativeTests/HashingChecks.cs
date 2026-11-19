using System.Reflection;
using System.Text.Json;
using Cliphoard.Windows;
internal static class HashingChecks
{
    internal static void Run()
    {
        using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.Hashing.json") ?? throw new IOException("Hashing references are missing.");
        using var json = JsonDocument.Parse(source);
        int checks = 0;
        foreach (var sample in json.RootElement.GetProperty("samples").EnumerateArray())
        {
            float[] actual = HashingModel.Embed(sample.GetProperty("text").GetString()!);
            float[] expected = sample.GetProperty("vector").EnumerateArray().Select(value => value.GetSingle()).ToArray();
            if (actual.Length != 256 || actual.Zip(expected, (first, second) => Math.Abs(first - second)).Any(difference => difference > 2e-7)) throw new Exception("Built-in matching differs from the shipping Mac fallback.");
            ++checks;
        }
        if (HashingModel.Fnv1a("hello") != 0xa430d84680aabd0b) throw new Exception("Stable hashing changed.");
        ++checks;
        Console.WriteLine(JsonSerializer.Serialize(new { hashing_checks = checks, status = "passed", reference = "shipping Swift source" }));
    }
}
