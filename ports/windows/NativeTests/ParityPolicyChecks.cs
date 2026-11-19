using Cliphoard.Windows;
using System.Text.Json;

internal static class ParityPolicyChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool condition) { ++checks; if (!condition) throw new Exception($"Parity policy check {checks} failed."); }
        var state = new SensitiveRevealState();
        var item = new HistoryItem { Text = "Synthetic protected content", Flags = 1 };
        var request = state.Begin(item);
        Check(!state.Permits(item, 1000));
        Check(state.Complete(request, item, true, 1000));
        Check(state.Permits(item, 1000));
        Check(state.Permits(item, 60999));
        Check(!state.Permits(item, 61000));
        Check(state.Expire(61000) && state.Count == 0);
        request = state.Begin(item);
        item.Text += " changed";
        Check(!state.Complete(request, item, true, 1000));
        request = state.Begin(item);
        state.Clear();
        Check(!state.Complete(request, item, true, 1000));
        request = state.Begin(item);
        var replacement = state.Begin(item);
        Check(!state.Complete(request, item, true, 1000));
        Check(state.Complete(replacement, item, true, 1000));
        item.Tags.Add("changed");
        Check(!state.Permits(item, 1001));
        Check(!state.Permits(new HistoryItem { Text = item.Text }, 1001));
        Check(ContentSafety.RequiresAuthentication(new HistoryItem { Text = "Synthetic rich clip", RichText = new byte[] { 1 } }));
        Check(ContentSafety.RequiresAuthentication(new HistoryItem { Text = "Synthetic HTML clip", Html = new byte[] { 1 } }));
        var ordinaryRich = new HistoryItem { Text = "Synthetic rich note", RichText = System.Text.Encoding.ASCII.GetBytes(@"{\rtf1\ansi Synthetic \b rich\b0 note}") };
        Check(!ContentSafety.RequiresAuthentication(ordinaryRich) && !ordinaryRich.AnalysisVetoed);
        ordinaryRich.Html = FeatureChecks.MakeHtml("<p>Synthetic <strong>rich</strong> note</p>");
        Check(!ContentSafety.RequiresAuthentication(ordinaryRich) && !ordinaryRich.AnalysisVetoed);
        var markedRich = new HistoryItem { Text = "[CLIPHOARD_SYNTHETIC_V1] Rich note", RichText = System.Text.Encoding.ASCII.GetBytes(@"{\rtf1\ansi [CLIPHOARD_SYNTHETIC_V1] \b Rich note\b0}"), Html = FeatureChecks.MakeHtml("<p>[CLIPHOARD_SYNTHETIC_V1] <strong>Rich note</strong></p>") };
        Check(!ContentSafety.RequiresAuthentication(markedRich) && !markedRich.AnalysisVetoed);
        string syntheticKey = "sk-" + new string('A', 24);
        var alternateSecret = new HistoryItem { Text = "Synthetic safe caption", RichText = System.Text.Encoding.ASCII.GetBytes(@"{\rtf1\ansi {\info {\comment " + syntheticKey + "}}Synthetic safe caption}") };
        Check(ContentSafety.RequiresAuthentication(alternateSecret) && alternateSecret.AnalysisVetoed);
        var escapedSecret = new HistoryItem { Text = "Synthetic safe caption", RichText = System.Text.Encoding.ASCII.GetBytes(@"{\rtf1\ansi {\*\comment " + string.Concat(syntheticKey.Select(character => "\\'" + ((int)character).ToString("x2"))) + "}Synthetic safe caption}") };
        Check(ContentSafety.RequiresAuthentication(escapedSecret) && escapedSecret.AnalysisVetoed);
        var hiddenHtml = new HistoryItem { Text = "Synthetic safe caption", Html = FeatureChecks.MakeHtml("<p>Synthetic safe caption</p><script>" + syntheticKey + "</script>") };
        Check(ContentSafety.RequiresAuthentication(hiddenHtml) && hiddenHtml.AnalysisVetoed);
        hiddenHtml.Html = FeatureChecks.MakeHtml("<p>Synthetic safe caption</p><span data-synthetic=\"" + string.Concat(syntheticKey.Select(character => "&#" + (int)character + ";")) + "\"></span>");
        Check(ContentSafety.RequiresAuthentication(hiddenHtml) && hiddenHtml.AnalysisVetoed);
        var mutableRich = new HistoryItem { Text = "Synthetic caption", RichText = System.Text.Encoding.ASCII.GetBytes(@"{\rtf1\ansi " + new string(' ', 100) + "}") };
        Check(!ContentSafety.RequiresAuthentication(mutableRich));
        System.Text.Encoding.ASCII.GetBytes(syntheticKey).CopyTo(mutableRich.RichText, 20);
        Check(ContentSafety.RequiresAuthentication(mutableRich) && mutableRich.AnalysisVetoed);
        Check(ContentSafety.RequiresAuthentication(new HistoryItem { Text = "Synthetic caption", RichText = System.Text.Encoding.ASCII.GetBytes(@"{\rtf1\ansi {\object unsupported}Synthetic caption}") }));
        Check(!ContentSafety.RequiresAuthentication(new HistoryItem { Text = "Synthetic ordinary note" }));
        Check(ContentSafety.RequiresAuthentication(new HistoryItem { Text = "Synthetic", Tags = new() { "-----BEGIN PRIVATE KEY-----" } }));
        float[] Axis(int dimension) { var vector = new float[768]; vector[dimension] = 1; return vector; }
        float[] query = Axis(0), image = Axis(0), background = Axis(1);
        Check(GemmaPictureRelevance.Score(query, image, new[] { background }) == 1);
        Check(GemmaPictureRelevance.Score(query, image, new[] { query }) is null);
        Check(GemmaPictureRelevance.Score(query, image, Array.Empty<float[]>()) is null);
        Check(GemmaPictureRelevance.Score(new float[3], image, new[] { background }) is null);
        Check(GemmaPictureRelevance.Score(new float[768], image, new[] { background }) is null);
        background[2] = float.NaN;
        Check(GemmaPictureRelevance.Score(query, image, new[] { background }) is null);
        var search = new SearchInputState();
        search.Edit("Synthetic pending query"); Check(search.Pending && search.Submitted == "");
        search.Composing = true; Check(!search.Submit());
        search.Composing = false; Check(search.Submit() && !search.Pending);
        Check(!search.Submit());
        search.Edit("different"); search.Reset(""); Check(!search.Pending && search.Submitted == "");
        var parsed = TimeQuery.Parse("restaurant when:2026-11-01..2026-11-16");
        Check(parsed.Text == "restaurant" && parsed.Scope?.Name == "Custom range");
        var now = new DateTimeOffset(2026, 11, 16, 12, 0, 0, TimeSpan.Zero);
        Check(parsed.Scope!.Contains(now, now));
        Check(!parsed.Scope.Contains(now.AddDays(1), now));
        Check(!parsed.Scope.Contains(now.AddMonths(-1), now));
        Check(TimeQuery.Parse("when:yesterday food").Text == "food");
        Check(TimeQuery.Parse("when:yesterday").Scope!.Contains(now.AddDays(-1), now));
        Check(!TimeQuery.Parse("when:7d").Scope!.Contains(now.AddDays(-7).AddSeconds(-1), now));
        Check(!TimeQuery.Parse("when:7d").Scope!.Contains(now.AddSeconds(1), now));
        Check(TimeQuery.Parse("when:invalid ordinary").Scope is null);
        HistoryItem highFlags = JsonSerializer.Deserialize<HistoryItem>("{\"Flags\":18446744073709551615}")!;
        Check(highFlags.Flags == -1 && ContentSafety.RequiresAuthentication(highFlags));
        Check(JsonSerializer.Serialize(highFlags).Contains("18446744073709551615", StringComparison.Ordinal));
        Check(ClipFlagsConverter.FromNode(System.Text.Json.Nodes.JsonNode.Parse("9223372036854775808")) == long.MinValue);
        Console.WriteLine(JsonSerializer.Serialize(new { parity_policy_checks = checks, status = "passed" }));
    }
}
