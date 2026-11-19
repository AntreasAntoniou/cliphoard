using System.Buffers.Binary;
namespace Cliphoard.Windows;

internal static class WavePcm
{
    internal static byte[] Write(ReadOnlySpan<float> samples)
    {
        if (samples.Length is < 1600 or > 16000 * 600) throw new IOException("Audio exceeds the PCM duration bound.");
        byte[] bytes = new byte[44 + samples.Length * 2];
        "RIFF"u8.CopyTo(bytes); BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(4), bytes.Length - 8); "WAVEfmt "u8.CopyTo(bytes.AsSpan(8));
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(16), 16); BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(20), 1); BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(22), 1);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(24), 16000); BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(28), 32000); BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(32), 2); BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(34), 16);
        "data"u8.CopyTo(bytes.AsSpan(36)); BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(40), samples.Length * 2);
        for (int index = 0; index < samples.Length; ++index)
        {
            if (!float.IsFinite(samples[index]) || samples[index] is < -1 or > 1) throw new IOException("Invalid PCM sample.");
            short value = (short)Math.Clamp(Math.Round(samples[index] * 32768), short.MinValue, short.MaxValue); BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(44 + index * 2), value);
        }
        return bytes;
    }
    internal static float[] Read(byte[] bytes, int minimumSamples = 1600)
    {
        if (bytes.Length is < 44 or > 20000000 || !bytes.AsSpan(0, 4).SequenceEqual("RIFF"u8) || !bytes.AsSpan(8, 4).SequenceEqual("WAVE"u8) || BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(4)) != bytes.Length - 8)
            throw new IOException("Use a bounded PCM WAV audio file.");
        bool format = false;
        ReadOnlySpan<byte> audio = default;
        int offset = 12;
        while (offset < bytes.Length)
        {
            if (bytes.Length - offset < 8) throw new IOException("Truncated WAV chunk.");
            int count = BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(offset + 4));
            if (count < 0 || count > bytes.Length - offset - 8) throw new IOException("Invalid WAV chunk length.");
            var body = bytes.AsSpan(offset + 8, count);
            if (bytes.AsSpan(offset, 4).SequenceEqual("fmt "u8))
            {
                if (format || count < 16 || BinaryPrimitives.ReadUInt16LittleEndian(body) != 1 || BinaryPrimitives.ReadUInt16LittleEndian(body[2..]) != 1 || BinaryPrimitives.ReadUInt32LittleEndian(body[4..]) != 16000 || BinaryPrimitives.ReadUInt32LittleEndian(body[8..]) != 32000 || BinaryPrimitives.ReadUInt16LittleEndian(body[12..]) != 2 || BinaryPrimitives.ReadUInt16LittleEndian(body[14..]) != 16)
                    throw new IOException("Use PCM16 mono WAV at 16 kHz.");
                format = true;
            }
            if (bytes.AsSpan(offset, 4).SequenceEqual("data"u8))
            {
                if (!audio.IsEmpty || count % 2 != 0) throw new IOException("Invalid WAV audio chunk.");
                audio = body;
            }
            offset = checked(offset + 8 + count + count % 2);
        }
        if (minimumSamples is < 1 or > 16000 * 600 || !format || audio.Length < minimumSamples * 2 || audio.Length > 16000 * 600 * 2 || offset != bytes.Length) throw new IOException("WAV audio exceeds the supported duration.");
        var samples = new float[audio.Length / 2];
        for (int index = 0; index < samples.Length; ++index) samples[index] = BinaryPrimitives.ReadInt16LittleEndian(audio[(index * 2)..]) / 32768f;
        return samples;
    }
}
