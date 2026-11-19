using System.Text.Json;
using System.Runtime.InteropServices;

internal static class BrandChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool condition, string scenario) { ++checks; if (!condition) throw new Exception("Transparent brand check failed in " + scenario); }
        var brightness = new Dictionary<string, double>();
        foreach (string theme in new[] { "Light", "Dark" })
        {
            using var image = new Bitmap(Path.Combine(AppContext.BaseDirectory, "Assets", "Brand." + theme + ".png"));
            Check(image.Width == image.Height && image.Width >= 256, theme + " image dimensions");
            Check(image.GetPixel(0, 0).A == 0 && image.GetPixel(image.Width - 1, image.Height - 1).A == 0, theme + " image corners");
            int clear = 0, opaque = 0;
            long total = 0;
            for (int y = 0; y < image.Height; y += 4)
            for (int x = 0; x < image.Width; x += 4)
            {
                Color pixel = image.GetPixel(x, y);
                if (pixel.A == 0) clear++;
                if (pixel.A >= 250) { opaque++; total += pixel.R + pixel.G + pixel.B; }
            }
            Check(clear > opaque / 3 && opaque > image.Width * image.Height / 160, theme + " transparent silhouette");
            brightness[theme] = total / (double)opaque / 3;
            foreach (int size in new[] { 16, 24, 32, 48, 64, 128, 256 })
            {
                nint handle = LoadImage(0, Path.Combine(AppContext.BaseDirectory, "Assets", "Cliphoard." + theme + ".ico"), 1, size, size, 0x10);
                Check(handle != 0, theme + " native icon load " + size);
                try
                {
                    using var icon = Icon.FromHandle(handle);
                    using var bitmap = icon.ToBitmap();
                    Check(bitmap.Width == size && bitmap.Height == size, theme + " native frame size " + size);
                    Check(bitmap.GetPixel(0, 0).A == 0 && bitmap.GetPixel(size - 1, size - 1).A == 0, theme + " native frame transparency " + size);
                }
                finally { DestroyIcon(handle); }
            }
        }
        Check(Math.Abs(brightness["Dark"] - brightness["Light"]) < 1, "approved teal artwork stays consistent across themes");
        Console.WriteLine(JsonSerializer.Serialize(new { brand_checks = checks, status = "passed", transparent_theme_variants = 2 }));
    }
    [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode)]
    private static extern nint LoadImage(nint instance, string path, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint icon);
}
