using Cliphoard.Windows;
using System.Drawing.Imaging;
using System.Security.Cryptography;
using System.Text.Json;

internal static class ClipboardImageChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Clipboard image check {checks} failed."); }
        using var bitmap = new Bitmap(2, 2, PixelFormat.Format32bppArgb);
        for (int y = 0; y < 2; ++y)
        for (int x = 0; x < 2; ++x) bitmap.SetPixel(x, y, Color.FromArgb(128, 255, 0, 0));
        using var png = new MemoryStream(); bitmap.Save(png, ImageFormat.Png);
        var item = new HistoryItem { Kind = "Image", Format = 0, Text = "Synthetic translucent red image", Payload = png.ToArray() };
        byte[] before = SHA256.HashData(item.Payload!);
        byte[] dib = await ImageAnalysis.ClipboardDibAsync(item, default);
        try
        {
            Check(HistoryClipboard.ValidDib(dib));
            Check(dib.Length == 140 && BitConverter.ToInt32(dib, 0) == 124);
            Check(BitConverter.ToInt32(dib, 4) == 2 && BitConverter.ToInt32(dib, 8) == -2);
            Check(BitConverter.ToUInt32(dib, 52) == 0xFF000000 && BitConverter.ToUInt32(dib, 56) == 0x73524742);
            Check(dib.AsSpan(124, 4).SequenceEqual(new byte[] { 0, 0, 255, 128 }));
            using var owner = new Form();
            var clipboard = new HistoryClipboard(owner.Handle);
            Check(clipboard.Write(item, false, dib));
            uint pngFormat = Native.RegisterClipboardFormat("PNG");
            Check(Native.IsClipboardFormatAvailable(pngFormat));
            Check(Native.IsClipboardFormatAvailable(17));
            Check(Native.IsClipboardFormatAvailable(8));
            Check(before.SequenceEqual(SHA256.HashData(item.Payload!)));
            Check(clipboard.Write(item, true, dib));
            Check(!Native.IsClipboardFormatAvailable(pngFormat) && !Native.IsClipboardFormatAvailable(17) && !Native.IsClipboardFormatAvailable(8) && Native.IsClipboardFormatAvailable(13));
        }
        finally { CryptographicOperations.ZeroMemory(dib); }
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        bool refused = false;
        try { await ImageAnalysis.ClipboardDibAsync(item, cancelled.Token); }
        catch (OperationCanceledException) { refused = true; }
        Check(refused);
        item.Payload = item.Payload!.ToArray();
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(item.Payload.AsSpan(16), 8193);
        refused = false;
        try { await ImageAnalysis.ClipboardDibAsync(item, default); }
        catch (IOException) { refused = true; }
        Check(refused);
        Console.WriteLine(JsonSerializer.Serialize(new { clipboard_image_checks = checks, status = "passed", generated_pixels_only = true }));
    }
}
