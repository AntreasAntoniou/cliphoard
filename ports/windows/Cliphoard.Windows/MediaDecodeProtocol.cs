namespace Cliphoard.Windows;
internal sealed record MediaDecodeRequest(string Operation, string Path = "", double Start = 0, double End = 0, bool FullSpeech = false);
internal sealed record MediaMetadata(double Duration, bool Video, bool Audio, uint Width, uint Height, string Hash, string Identity);
internal sealed record MediaDecodeResponse(bool Success, MediaMetadata? Metadata = null, byte[]? Bytes = null, double Start = 0, double End = 0);
