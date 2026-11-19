using System.Reflection;
using System.Text.Json;
using Cliphoard.Windows;
internal static class SpeechChecks
{
    internal static async Task RunAsync()
    {
        using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.SyntheticSpeech.wav") ?? throw new IOException("Synthetic audio is missing.");
        using var bytes = new MemoryStream(); resource.CopyTo(bytes);
        float[] samples = SpeechModel.ReadWave(bytes.ToArray());
        int checks = 0;
        foreach (string model in new[] { "small", "largeV3", "turbo" })
        {
            await SpeechModel.EnsureAsync(model, false, CancellationToken.None, new Progress<string>(message => Console.WriteLine(message)));
            string transcript = await SpeechModel.TranscribeAsync(model, samples, CancellationToken.None);
            string lower = transcript.ToLowerInvariant();
            if (!lower.Contains("restaurant") || !lower.Contains("delicious") || !lower.Contains("meals")) throw new Exception("Synthetic speech phrase was not recognized.");
            ++checks;
            Console.WriteLine(JsonSerializer.Serialize(new { model, transcript_characters = transcript.Length, synthetic_phrase_recognized = true }));
        }
        Console.WriteLine(JsonSerializer.Serialize(new { speech_models = checks, status = "passed", generated_audio_only = true }));
    }
}
