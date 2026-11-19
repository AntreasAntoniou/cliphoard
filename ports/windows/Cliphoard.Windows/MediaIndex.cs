using System.Buffers.Binary;
namespace Cliphoard.Windows;
internal sealed record MediaMoment(double Start, double End, string Modality, byte[] Vector, string? Text = null);
internal sealed record MediaIndex(string Path, long Length, long Modified, string ContentHash, string Model, string Preset, string Speech, string SpeechModel, double Duration, bool Video, bool Audio, double Coverage, MediaMoment[] Moments)
{
    public string FileIdentity { get; init; } = "";
    internal static string Signature => "gemma-media-v2-" + GemmaAssets.Model.Sha256 + GemmaAssets.Runtime.Sha256;
    internal static byte[] Pack(float[] vector)
    {
        if (vector.Length != 768 || vector.Any(value => !float.IsFinite(value) || Math.Abs(value) > 1.001)) throw new IOException("Invalid media vector.");
        byte[] bytes = new byte[1536];
        for (int index = 0; index < vector.Length; ++index) BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(index * 2), BitConverter.HalfToInt16Bits((Half)vector[index]));
        return bytes;
    }
    internal static float[] Unpack(byte[] bytes)
    {
        if (bytes.Length != 1536) throw new IOException("Invalid cached media vector.");
        float[] vector = new float[768]; double norm = 0;
        for (int index = 0; index < vector.Length; ++index) { float value = (float)BitConverter.Int16BitsToHalf(BinaryPrimitives.ReadInt16LittleEndian(bytes.AsSpan(index * 2))); if (!float.IsFinite(value)) throw new IOException("Invalid cached media vector."); vector[index] = value; norm += (double)value * value; }
        if (norm <= 0) throw new IOException("Empty cached media vector.");
        double scale = Math.Sqrt(norm); for (int index = 0; index < vector.Length; ++index) vector[index] = (float)(vector[index] / scale); return vector;
    }
    internal void Validate()
    {
        if (FileIdentity.Length != 24 || !FileIdentity.All(Uri.IsHexDigit)) throw new IOException("Invalid cached file identity.");
        if (Path.Length > 32768 || Length is < 1 or > 2147483648L || ContentHash.Length != 64 || !ContentHash.All(Uri.IsHexDigit) || Model.Length > 200 || Preset is not ("lightweight" or "balanced" or "detailed") || Speech is not ("off" or "sampled" or "full") || !ModelCatalog.Speech.ContainsKey(SpeechModel) || !double.IsFinite(Duration) || Duration is <= 0 or > 21600 || !double.IsFinite(Coverage) || Coverage is < 0 or > 1 || Moments is null || Moments.Length > 1480) throw new IOException("Invalid media index.");
        foreach (MediaMoment moment in Moments)
        {
            if (!double.IsFinite(moment.Start) || !double.IsFinite(moment.End) || moment.Start < 0 || moment.End < moment.Start || moment.End > Duration || moment.Modality is not ("video" or "audio" or "speech") || moment.Text?.Length > 65536) throw new IOException("Invalid media moment.");
            float[] vector = Unpack(moment.Vector); Array.Clear(vector);
        }
        if (Moments.Sum(moment => moment.Text?.Length ?? 0) > 200000) throw new IOException("Speech index exceeds its text bound.");
    }
    internal bool MatchesSettings(HistoryState state) => Model == Signature && Preset == state.MediaPreset && Speech == state.MediaSpeechCoverage && SpeechModel == state.SpeechModel;
    internal bool FileUnchanged()
    {
        try { using var file = LocalFileLease.Open(Path, 2L * 1024 * 1024 * 1024); return file.Length == Length && File.GetLastWriteTimeUtc(file.SafeFileHandle).Ticks == Modified && LocalFileLease.Identity(file) == FileIdentity; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { return false; }
    }
}
internal sealed record MediaMatch(string Id, double Start, double End, double Score, string Source, string? Passage);
