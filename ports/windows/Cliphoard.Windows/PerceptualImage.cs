namespace Cliphoard.Windows;
internal static class PerceptualImage
{
    internal static async Task<float[]> FeatureAsync(HistoryItem item, CancellationToken cancellation)
    {
        float[] pixels = await OpenVisionModel.PixelsAsync(item, cancellation);
        try
        {
            var feature = new float[16 * 16 * 3 + 1]; feature[^1] = .01f;
            for (int channel = 0; channel < 3; ++channel)
                for (int y = 0; y < 16; ++y)
                    for (int x = 0; x < 16; ++x)
                    {
                        cancellation.ThrowIfCancellationRequested();
                        double sum = 0;
                        for (int dy = 0; dy < 14; ++dy)
                            for (int dx = 0; dx < 14; ++dx) sum += pixels[channel * 224 * 224 + (y * 14 + dy) * 224 + x * 14 + dx];
                        feature[channel * 256 + y * 16 + x] = (float)(sum / 196);
                    }
            double norm = Math.Sqrt(feature.Sum(value => (double)value * value));
            return feature.Select(value => (float)(value / norm)).ToArray();
        }
        finally { Array.Clear(pixels); }
    }
}
