namespace Cliphoard.Windows;
internal sealed record MediaSampleWindow(double Start, double End, double[] Frames);
internal sealed record MediaSamplingPlan(double RequestedCount, double Interval, MediaSampleWindow[] Segments, double SampledDuration, double Coverage)
{
    internal static MediaSamplingPlan Make(double duration, string preset, bool video)
    {
        if (!double.IsFinite(duration) || duration < 0 || preset is not ("lightweight" or "balanced" or "detailed")) throw new IOException("Invalid media sampling input.");
        if (duration == 0) return new(0, 0, Array.Empty<MediaSampleWindow>(), 0, 0);
        double window = video ? preset == "lightweight" ? 2 : 3 : preset == "lightweight" ? 3 : preset == "balanced" ? 10 : 30;
        double cadence = preset == "lightweight" ? 60 : video && preset == "detailed" ? 10 : 30;
        int frameCount = video ? preset == "lightweight" ? 2 : 3 : 0;
        double requested = Math.Max(1, Math.Ceiling(duration / cadence));
        if (!double.IsFinite(requested)) throw new IOException("Unrepresentable media timeline.");
        bool capped = requested > 120; int count = capped ? 120 : (int)requested;
        var segments = new List<MediaSampleWindow>(); double sampled = 0, previous = 0;
        for (int index = 0; index < count; ++index)
        {
            double bucketStart = capped ? duration * ((double)index / count) : index * cadence;
            double bucketEnd = capped ? index == count - 1 ? duration : duration * ((double)(index + 1) / count) : Math.Min(duration, bucketStart + cadence);
            double width = Math.Min(window, bucketEnd - bucketStart), start = bucketStart + (bucketEnd - bucketStart - width) / 2, end = Math.Min(bucketEnd, start + width);
            if (end - start > window) end = Math.BitDecrement(end);
            if (!double.IsFinite(start) || !double.IsFinite(end) || start < previous || start < 0 || end <= start || end > duration || end - start > window) throw new IOException("Unrepresentable media segment.");
            var frames = new List<double>();
            for (int frame = 0; frame < frameCount; ++frame)
            {
                double timestamp = Math.Min(Math.BitDecrement(end), Math.Max(start, start + (end - start) * ((frame + .5) / frameCount)));
                if (!double.IsFinite(timestamp) || timestamp < start || timestamp >= end) throw new IOException("Unrepresentable frame time.");
                if (frames.LastOrDefault(-1) != timestamp) frames.Add(timestamp);
            }
            segments.Add(new(start, end, frames.ToArray())); sampled += end - start; previous = end;
        }
        return new(requested, capped ? duration / count : Math.Min(cadence, duration), segments.ToArray(), sampled, Math.Min(1, sampled / duration));
    }
}
