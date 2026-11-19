using Cliphoard.Windows;
using System.Reflection;
using System.Text.Json;
internal static class PerceptualChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Perceptual image check {checks} failed"); }
        var images = new List<HistoryItem>();
        foreach (string color in new[] { "Red", "Blue" })
        {
            using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.Synthetic" + color + ".png")!;
            using var bytes = new MemoryStream(); source.CopyTo(bytes);
            images.Add(new() { Kind = "Image", Format = 0, Payload = bytes.ToArray() });
        }
        float[] red = await PerceptualImage.FeatureAsync(images[0], default), blue = await PerceptualImage.FeatureAsync(images[1], default);
        Check(red.Length == 769 && red.All(float.IsFinite));
        Check(Math.Abs(SemanticEngine.Dot(red, red) - 1) < .00001);
        Check(SemanticEngine.Dot(red, blue) < .01);
        float[] duplicate = await PerceptualImage.FeatureAsync(images[0], default); Check(red.SequenceEqual(duplicate));
        using (var bitmap = new Bitmap(24, 16))
        {
            using (var graphics = Graphics.FromImage(bitmap)) graphics.Clear(Color.Red);
            foreach (var format in new[] { System.Drawing.Imaging.ImageFormat.Jpeg, System.Drawing.Imaging.ImageFormat.Bmp, System.Drawing.Imaging.ImageFormat.Gif, System.Drawing.Imaging.ImageFormat.Tiff })
            {
                using var encoded = new MemoryStream(); bitmap.Save(encoded, format);
                byte[] png = await ImageAnalysis.NormalizeReferenceAsync(encoded.ToArray(), default);
                Check(ClipboardContent.IsPng(png));
            }
        }
        images[0].Flags = 1;
        try { await PerceptualImage.FeatureAsync(images[0], default); Check(false); } catch (IOException) { Check(true); }
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        try { await PerceptualImage.FeatureAsync(images[1], cancellation.Token); Check(false); } catch (OperationCanceledException) { Check(true); }
        Console.WriteLine(JsonSerializer.Serialize(new { perceptual_image_checks = checks, status = "passed", generated_data_only = true }));
    }
}
