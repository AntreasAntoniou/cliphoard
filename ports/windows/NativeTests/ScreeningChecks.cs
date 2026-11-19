using Cliphoard.Windows;
using System.Text.Json;
internal static class ScreeningChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Screening check {checks} failed"); }
        Check(NsfwPolicy.Labelled(new HistoryItem { Text = "synthetic nsfw label" }));
        Check(!NsfwPolicy.Labelled(new HistoryItem { Text = "Essex Scunthorpe" }));
        Check(NsfwPolicy.Labelled(new HistoryItem { Text = "C:\\synthetic\\%70orn\\fixture.png" }));
        var exempt = new HistoryItem { Text = "synthetic nsfw label", Tags = new() { "nsfw-exempt" }, Flags = 128 };
        Check(!NsfwPolicy.Labelled(exempt) && !NsfwPolicy.RequiresAuthentication(exempt, true));
        exempt.Flags |= 1; Check(NsfwPolicy.RequiresAuthentication(exempt, true));
        Check(!NsfwPolicy.RequiresAuthentication(new HistoryItem { Flags = 128 }, false));
        Check(NsfwPolicy.RequiresAuthentication(new HistoryItem { Flags = 128 }, true));
        Check(NsfwPolicy.PossibleMatch(new[] { 1f, 0f }, new[] { new[] { 1f, 0f } }, new[] { new[] { 0f, 1f } }));
        Check(!NsfwPolicy.PossibleMatch(new[] { 1f, 0f }, new[] { new[] { 1f, 0f } }, new[] { new[] { 1f, 0f } }));
        Check(!NsfwPolicy.PossibleMatch(new[] { float.NaN }, new[] { new[] { 1f } }, new[] { new[] { 0f } }));
        Check(!NsfwPolicy.PossibleMatch(new[] { 0f }, new[] { new[] { 1f } }, new[] { new[] { 1f } }));
        using (var engine = new SemanticEngine())
        {
            await engine.PrepareAsync(false, default);
            var positive = new List<float[]>(); var negative = new List<float[]>();
            foreach (string text in NsfwPolicy.Positive) positive.Add(await engine.EmbedAsync(text));
            foreach (string text in NsfwPolicy.Negative) negative.Add(await engine.EmbedAsync(text));
            Check(!NsfwPolicy.PossibleMatch(await engine.EmbedAsync("programming source code and software documentation"), positive, negative));
            Check(NsfwPolicy.PossibleMatch(await engine.EmbedAsync(NsfwPolicy.Positive[0]), positive, negative));
        }
        string first = ArchivePassphrase.Generate(), second = ArchivePassphrase.Generate();
        Check(first != second && first.Length == 29 && first.Split('-').All(group => group.Length == 5 && group.All(character => "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".Contains(character))));
        Console.WriteLine(JsonSerializer.Serialize(new { screening_checks = checks, focus_state = FocusProtection.Read(), status = "passed" }));
    }
}
