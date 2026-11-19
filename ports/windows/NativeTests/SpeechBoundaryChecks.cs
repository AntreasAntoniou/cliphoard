using System.Reflection;
using System.Text.Json;
using Cliphoard.Windows;
internal static class SpeechBoundaryChecks
{
    internal static async Task RunAsync()
    {
        using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.SyntheticSpeech.wav") ?? throw new IOException("Audio fixture missing.");
        using var buffer = new MemoryStream(); source.CopyTo(buffer); byte[] good = buffer.ToArray();
        int checks = 0;
        if (SpeechModel.ReadWave(good).Length < 1600) throw new Exception("Valid synthetic WAV was refused.");
        ++checks;
        foreach (byte[] bad in new[] { Array.Empty<byte>(), good[..43], good[..^1], good.Concat(new byte[1]).ToArray() })
        {
            try { SpeechModel.ReadWave(bad); throw new Exception("Malformed WAV was accepted."); }
            catch (IOException) { ++checks; }
        }
        foreach (int offset in new[] { 0, 4, 8 })
        {
            byte[] bad = good.ToArray(); bad[offset] ^= 128;
            try { SpeechModel.ReadWave(bad); throw new Exception("Corrupt WAV framing was accepted."); }
            catch (IOException) { ++checks; }
        }
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        try { await SpeechModel.TranscribeAsync("small", new float[1600], cancellation.Token); throw new Exception("Cancelled speech was admitted."); }
        catch (OperationCanceledException) { ++checks; }
        string passage = new string('x', 999) + "🌩" + new string('y', 1001);
        string[] chunks = SpeechModel.PassageChunks(passage).ToArray();
        if (string.Concat(chunks) != passage || chunks.Any(chunk => System.Text.Encoding.UTF8.GetByteCount(chunk) > 1000) || chunks.Length != 3) throw new Exception("Speech passage chunking changed Unicode content or exceeded the Mac byte bound.");
        ++checks;
        Console.WriteLine(JsonSerializer.Serialize(new { speech_boundary_checks = checks, status = "passed" }));
    }
}
