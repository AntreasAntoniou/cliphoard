using Cliphoard.Windows;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Drawing.Imaging;

internal static class ParityChecks
{
    private static JsonDocument Fixture(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures." + name + ".json") ?? throw new IOException("Missing fixture " + name);
        return JsonDocument.Parse(stream);
    }
    internal static async Task ArchiveAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Mac archive check {checks} failed."); }
        const string passphrase = "synthetic café 2026";
        using var fixture = Fixture("MacArchive");
        byte[] archive = Convert.FromBase64String(fixture.RootElement.GetProperty("archive").GetString()!);
        Check(Convert.ToHexString(SHA256.HashData(archive)).Equals(fixture.RootElement.GetProperty("sha256").GetString(), StringComparison.OrdinalIgnoreCase));
        HistoryState state = MacHistoryArchive.Open(archive, passphrase.Normalize(NormalizationForm.FormD));
        Check(state.Items.Count == 1);
        var item = state.Items.Single();
        Check(item.Text == "[CLIPHOARD_SYNTHETIC_V1] Café\nSecond line 中文" && item.Pinned && item.Flags == 8 && !item.AnalysisVetoed);
        Check(item.Tags.SequenceEqual(new[] { "synthetic", "café" }) && item.MacRecords.Single().Type == 4);
        Check(item.Captured == new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero).AddSeconds(815000000.125));
        foreach (int position in new[] { 0, 8, 10, 11, 12, 16, 32, 36, 40, 44, 48, 1072, 1088, 1092, 1093, archive.Length - 1 })
        {
            byte[] damaged = archive.ToArray(); damaged[position] ^= 0x80;
            bool refused = false; try { MacHistoryArchive.Open(damaged, passphrase); } catch { refused = true; }
            Check(refused);
        }
        foreach (int length in new[] { 0, 47, 1087, 1088, 1090, archive.Length - 1 })
        {
            bool refused = false; try { MacHistoryArchive.Open(archive[..length], passphrase); } catch { refused = true; } Check(refused);
        }
        bool trailing = false; try { MacHistoryArchive.Open(archive.Concat(new byte[] { 0 }).ToArray(), passphrase); } catch { trailing = true; } Check(trailing);
        bool wrong = false; try { MacHistoryArchive.Open(archive, "wrong synthetic password"); } catch (CryptographicException) { wrong = true; } Check(wrong);
        byte[] exported = await MacHistoryArchive.SealAsync(state, passphrase);
        var roundtrip = MacHistoryArchive.Open(exported, passphrase);
        Check(roundtrip.Items[0].Text == item.Text && roundtrip.Items[0].MacRecords.Count == 1);
        using (var metadata = JsonDocument.Parse(roundtrip.Items[0].MacMetadata!)) Check(metadata.RootElement.GetProperty("useCount").GetInt32() == 7 && metadata.RootElement.GetProperty("lastUsedAt").GetDouble() == 815000100.5 && metadata.RootElement.GetProperty("shape").GetString() == "note");
        Directory.CreateDirectory(@"C:\CliphoardDev\evidence");
        File.WriteAllBytes(@"C:\CliphoardDev\evidence\windows-mac-roundtrip.cliphoard", exported);
        var many = new HistoryState { Limit = 500, Items = Enumerable.Range(0, 24).Select(i => new HistoryItem { Text = i + new string('x', 60000) }).ToList() };
        byte[] multichunk = await MacHistoryArchive.SealAsync(many, passphrase);
        Check(MacHistoryArchive.Open(multichunk, passphrase).Items.Count == 24 && multichunk.Length > 1048576);
        byte[] truncated = multichunk[..(1088 + 1048576 + 21)];
        bool boundary = false; try { MacHistoryArchive.Open(truncated, passphrase); } catch { boundary = true; } Check(boundary);
        using var bitmap = new Bitmap(50, 30);
        using (var graphics = Graphics.FromImage(bitmap)) graphics.Clear(Color.MediumSlateBlue);
        using var png = new MemoryStream(); bitmap.Save(png, ImageFormat.Png);
        var mixed = new HistoryState { Items = new()
        {
            new() { Kind = "Image", Format = 0, Payload = png.ToArray(), OcrText = "Synthetic OCR image", Tags = new() { "image" } },
            new() { Kind = "Code", Text = "const synthetic = true;", RichText = Encoding.ASCII.GetBytes("{\\rtf1 synthetic}") },
            new() { Kind = "Color", Text = "#123456" },
            new() { Kind = "Text", Text = "sk-" + new string('A', 24), Flags = 1 }
        } };
        var converted = MacHistoryArchive.Open(await MacHistoryArchive.SealAsync(mixed, passphrase), passphrase);
        Check(converted.Items.Single(i => i.Kind == "Image").Payload!.SequenceEqual(png.ToArray()));
        Check(converted.Items.Single(i => i.Kind == "Image").OcrText == "Synthetic OCR image");
        Check(converted.Items.Single(i => i.Kind == "Code").RichText!.SequenceEqual(mixed.Items[1].RichText!));
        Check(converted.Items.Single(i => i.Kind == "Color").Text == "#123456");
        Check(converted.Items.Single(i => i.Flags == 1).AnalysisVetoed && converted.Items.Single(i => i.Flags == 1).SearchText == "");
        byte[] dib = new byte[40 + 50 * 30 * 4];
        BitConverter.GetBytes(40).CopyTo(dib, 0); BitConverter.GetBytes(50).CopyTo(dib, 4); BitConverter.GetBytes(30).CopyTo(dib, 8);
        BitConverter.GetBytes((short)1).CopyTo(dib, 12); BitConverter.GetBytes((short)32).CopyTo(dib, 14);
        for (int pixel = 40; pixel < dib.Length; pixel += 4) { dib[pixel] = 128; dib[pixel + 1] = 64; dib[pixel + 2] = 200; }
        var legacy = new HistoryItem { Kind = "Image", Format = 8, Payload = dib, Text = "50 × 30 pixels" };
        var encoded = MacHistoryArchive.Open(await MacHistoryArchive.SealAsync(new HistoryState { Items = new() { legacy } }, passphrase), passphrase).Items.Single();
        Check(encoded.Format == 0 && encoded.Payload is not null);
        await ImageAnalysis.AssignArchiveIdentitiesAsync(new[] { legacy, encoded });
        Check(HistoryStore.SameContent(legacy, encoded) && legacy.Format == 8 && legacy.Payload.SequenceEqual(dib));
        string directory = Path.Combine(Path.GetTempPath(), "Cliphoard-mac-merge-" + Guid.NewGuid().ToString("N"));
        try { var store = new HistoryStore(directory); store.Add(legacy); Check(store.Import(new[] { encoded }, false) == 0 && store.State.Items.Count == 1); }
        finally { Directory.Delete(directory, true); }
        bool shortGraphemes = false;
        try { await MacHistoryArchive.SealAsync(state, string.Concat(Enumerable.Repeat("e\u0301", 11))); } catch (ArgumentException) { shortGraphemes = true; }
        Check(shortGraphemes);
        Check(ContentSafety.Flags("-----BEGIN PRIVATE KEY-----") == 1);
        Check(ContentSafety.Flags("ghp_" + new string('A', 24)) == 1);
        Check(ContentSafety.Flags("ask-me-later") == 0 && ContentSafety.Flags("[CLIPHOARD_SYNTHETIC_V1] Ordinary sentence.") == 0);
        Console.WriteLine(JsonSerializer.Serialize(new { mac_archive_checks = checks, status = "passed", generated_data_only = true }));
    }
    internal static async Task SemanticAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Semantic check {checks} failed."); }
        using var engine = new SemanticEngine();
        await engine.PrepareAsync(true, CancellationToken.None);
        using var golden = Fixture("Semantic");
        var tokenizer = new WordPiece(File.ReadAllLines(Path.Combine(SemanticEngine.CacheDirectory, "vocab.txt")));
        double minimumCosine = 1;
        foreach (var sample in golden.RootElement.GetProperty("samples").EnumerateArray())
        {
            string text = sample.GetProperty("text").GetString()!;
            Check(tokenizer.Encode(text).SequenceEqual(sample.GetProperty("tokens").EnumerateArray().Select(v => v.GetInt64())));
            var vector = await engine.EmbedAsync(text);
            var expected = sample.GetProperty("vector").EnumerateArray().Select(v => v.GetSingle()).ToArray();
            double cosine = SemanticEngine.Dot(vector, expected);
            minimumCosine = Math.Min(cosine, minimumCosine);
            Check(vector.Length == 384 && cosine > .99999 && vector.All(float.IsFinite));
        }
        var ranking = await engine.RankAsync("Where can I get something to eat?", new[] { ("meal", "The restaurant serves delicious meals."), ("compiler", "A compiler reports a syntax error.") }, CancellationToken.None);
        Check(ranking["meal"] > ranking["compiler"] + .2);
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        bool refused = false; try { await engine.EmbedAsync("generated cancelled", cancelled.Token); } catch (OperationCanceledException) { refused = true; } Check(refused);
        Check(tokenizer.Encode(string.Join(' ', Enumerable.Repeat("hello", 1000))).Length == 256);
        await engine.ClearAsync();
        Console.WriteLine(JsonSerializer.Serialize(new { semantic_checks = checks, minimum_cosine = minimumCosine, status = "passed", model = SemanticEngine.Signature }));
    }
    internal static async Task OcrAsync()
    {
        using var bitmap = new Bitmap(1000, 200);
        using (var graphics = Graphics.FromImage(bitmap))
        using (var font = new Font("Arial", 42))
        {
            graphics.Clear(Color.White); graphics.DrawString("SYNTHETIC CLIPBOARD 2026", font, Brushes.Black, 24, 45);
        }
        using var png = new MemoryStream(); bitmap.Save(png, ImageFormat.Png);
        var item = new HistoryItem { Kind = "Image", Format = 0, Payload = png.ToArray() };
        string recognized = await ImageAnalysis.RecognizeAsync(item, CancellationToken.None);
        if (!recognized.Contains("SYNTHETIC", StringComparison.OrdinalIgnoreCase) || !recognized.Contains("2026")) throw new Exception("Generated OCR phrase was not recognized.");
        var protectedItem = new HistoryItem { Kind = "Image", Format = 0, Payload = png.ToArray(), Flags = 1 };
        bool refused = false; try { await ImageAnalysis.RecognizeAsync(protectedItem, CancellationToken.None); } catch (IOException) { refused = true; }
        if (!refused) throw new Exception("Protected clip reached OCR.");
        using var large = new Bitmap(8192, 350);
        using (var graphics = Graphics.FromImage(large))
        using (var font = new Font("Arial", 96))
        {
            graphics.Clear(Color.White); graphics.DrawString("SYNTHETIC CLIPBOARD 2026", font, Brushes.Black, 100, 100);
        }
        using var largePng = new MemoryStream(); large.Save(largePng, ImageFormat.Png);
        string scaled = await ImageAnalysis.RecognizeAsync(new HistoryItem { Kind = "Image", Format = 0, Payload = largePng.ToArray() }, CancellationToken.None);
        if (!scaled.Contains("SYNTHETIC", StringComparison.OrdinalIgnoreCase)) throw new Exception("Large generated image was not recognized after scaling.");
        string temporary = Path.Combine(Path.GetTempPath(), "cliphoard-model-refusal-" + Guid.NewGuid().ToString("N"));
        try
        {
            File.WriteAllBytes(temporary, new byte[32]);
            bool corrupt = false;
            try { SemanticEngine.ReadVerified(temporary, 32, new string('1', 64)); } catch (IOException) { corrupt = true; }
            if (!corrupt) throw new Exception("Corrupt model was accepted.");
        }
        finally { File.Delete(temporary); }
        Console.WriteLine(JsonSerializer.Serialize(new { ocr_checks = 5, status = "passed", text_length = recognized.Length, protected_refused = refused }));
    }
}
