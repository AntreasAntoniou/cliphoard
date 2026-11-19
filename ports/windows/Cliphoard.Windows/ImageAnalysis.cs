using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace Cliphoard.Windows;

internal static class ImageAnalysis
{
    internal static byte[] EncodedImage(HistoryItem item)
    {
        byte[] payload = item.Payload ?? throw new IOException("Image payload is missing.");
        if (item.Format == 0)
        {
            if (!ClipboardContent.IsPng(payload)) throw new IOException("Invalid PNG image.");
            return payload;
        }
        if (item.Format is not (8 or 17) || !HistoryClipboard.ValidDib(payload)) throw new IOException("Invalid bitmap image.");
        int header = BitConverter.ToInt32(payload);
        int masks = header == 40 && BitConverter.ToUInt32(payload, 16) == 3 ? 12 : 0;
        var bytes = new byte[payload.Length + 14];
        bytes[0] = 0x42; bytes[1] = 0x4d;
        BitConverter.GetBytes(bytes.Length).CopyTo(bytes, 2);
        BitConverter.GetBytes(14 + header + masks).CopyTo(bytes, 10);
        payload.CopyTo(bytes, 14);
        return bytes;
    }
    private static async Task<SoftwareBitmap> DecodeAsync(HistoryItem item, CancellationToken cancellation, uint maximumDimension = 8192, BitmapAlphaMode alpha = BitmapAlphaMode.Premultiplied, long maximumPixels = 16777216)
        => await DecodeEncodedAsync(EncodedImage(item), cancellation, maximumDimension, alpha, maximumPixels);
    private static async Task<SoftwareBitmap> DecodeEncodedAsync(byte[] bytes, CancellationToken cancellation, uint maximumDimension, BitmapAlphaMode alpha = BitmapAlphaMode.Premultiplied, long maximumPixels = 16777216)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
        {
            if (bytes.Length is 0 or > 8 * 1024 * 1024) throw new IOException("Image exceeds the encoded image limit.");
            writer.WriteBytes(bytes);
            await writer.StoreAsync().AsTask(cancellation);
        }
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(cancellation);
        if (decoder.PixelWidth is 0 or > 8192 || decoder.PixelHeight is 0 or > 8192 || (long)decoder.PixelWidth * decoder.PixelHeight > maximumPixels) throw new IOException("Image dimensions exceed the capture limit.");
        double scale = Math.Min(1, maximumDimension / (double)Math.Max(decoder.PixelWidth, decoder.PixelHeight));
        var transform = new BitmapTransform
        {
            ScaledWidth = Math.Max(1, (uint)(decoder.PixelWidth * scale)),
            ScaledHeight = Math.Max(1, (uint)(decoder.PixelHeight * scale)),
            InterpolationMode = BitmapInterpolationMode.Fant
        };
        return await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, alpha, transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb).AsTask(cancellation);
    }
    internal static async Task<byte[]> ClipboardDibAsync(HistoryItem item, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        // Clipboard conversion retains the existing 8192-by-8192 payload contract.
        // Model and OCR decoding keep their separate sixteen-megapixel limit.
        using var bitmap = await DecodeAsync(item, cancellation, alpha: BitmapAlphaMode.Straight, maximumPixels: 8192L * 8192);
        int pixelBytes = checked(bitmap.PixelWidth * bitmap.PixelHeight * 4);
        var buffer = new global::Windows.Storage.Streams.Buffer((uint)pixelBytes) { Length = (uint)pixelBytes };
        bitmap.CopyToBuffer(buffer);
        using var reader = DataReader.FromBuffer(buffer);
        byte[] pixels = new byte[pixelBytes], result = new byte[checked(124 + pixelBytes)];
        try
        {
            reader.ReadBytes(pixels);
            BitConverter.GetBytes(124).CopyTo(result, 0);
            BitConverter.GetBytes(bitmap.PixelWidth).CopyTo(result, 4);
            BitConverter.GetBytes(-bitmap.PixelHeight).CopyTo(result, 8);
            BitConverter.GetBytes((ushort)1).CopyTo(result, 12);
            BitConverter.GetBytes((ushort)32).CopyTo(result, 14);
            BitConverter.GetBytes(3).CopyTo(result, 16);
            BitConverter.GetBytes(pixelBytes).CopyTo(result, 20);
            BitConverter.GetBytes(0x00FF0000u).CopyTo(result, 40);
            BitConverter.GetBytes(0x0000FF00u).CopyTo(result, 44);
            BitConverter.GetBytes(0x000000FFu).CopyTo(result, 48);
            BitConverter.GetBytes(0xFF000000u).CopyTo(result, 52);
            BitConverter.GetBytes(0x73524742u).CopyTo(result, 56);
            BitConverter.GetBytes(4).CopyTo(result, 108);
            pixels.CopyTo(result, 124);
            cancellation.ThrowIfCancellationRequested();
            return result;
        }
        catch { System.Security.Cryptography.CryptographicOperations.ZeroMemory(result); throw; }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(pixels); }
    }
    internal static async Task<byte[]> PngAsync(HistoryItem item, CancellationToken cancellation = default)
    {
        if (item.Format == 0) return EncodedImage(item).ToArray();
        using var bitmap = await DecodeAsync(item, cancellation);
        return await EncodePngAsync(bitmap, cancellation);
    }
    internal static async Task<byte[]> NormalizeReferenceAsync(byte[] encoded, CancellationToken cancellation)
        => await NormalizeImageAsync(encoded, cancellation, 1024);
    internal static async Task<byte[]> NormalizeImageAsync(byte[] encoded, CancellationToken cancellation, uint maximumDimension = 8192)
    {
        using var bitmap = await DecodeEncodedAsync(encoded, cancellation, maximumDimension);
        return await EncodePngAsync(bitmap, cancellation);
    }
    private static async Task<byte[]> EncodePngAsync(SoftwareBitmap bitmap, CancellationToken cancellation)
    {
        using var output = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output).AsTask(cancellation);
        encoder.SetSoftwareBitmap(bitmap);
        await encoder.FlushAsync().AsTask(cancellation);
        if (output.Size > 8 * 1024 * 1024) throw new IOException("PNG exceeds the archive image limit.");
        using var reader = new DataReader(output.GetInputStreamAt(0));
        await reader.LoadAsync((uint)output.Size).AsTask(cancellation);
        var bytes = new byte[(int)output.Size]; reader.ReadBytes(bytes);
        return bytes;
    }
    internal static async Task AssignArchiveIdentitiesAsync(IEnumerable<HistoryItem> items, CancellationToken cancellation = default)
    {
        foreach (HistoryItem item in items.Where(item => item.Kind == "Image"))
        {
            cancellation.ThrowIfCancellationRequested();
            if (item.ArchiveFingerprint is not null) continue;
            byte[] png = await PngAsync(item, cancellation);
            try { item.ArchiveFingerprint = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(png)); }
            finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(png); }
        }
    }
    internal static async Task<string> RecognizeAsync(HistoryItem item, CancellationToken cancellation)
    {
        if (item.Kind != "Image" || item.AnalysisVetoed) throw new IOException("This clip is excluded from analysis.");
        var engine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine is null) throw new InvalidOperationException("No OCR recognizer is available for the Windows profile languages.");
        using var bitmap = await DecodeAsync(item, cancellation, OcrEngine.MaxImageDimension);
        if (bitmap.PixelWidth > OcrEngine.MaxImageDimension || bitmap.PixelHeight > OcrEngine.MaxImageDimension) throw new IOException("Image exceeds the Windows OCR limit.");
        var result = await engine.RecognizeAsync(bitmap).AsTask(cancellation);
        cancellation.ThrowIfCancellationRequested();
        string text = string.Join(Environment.NewLine, result.Lines.Select(line => line.Text));
        return text.Length <= 65536 ? text : text[..65536];
    }
}
