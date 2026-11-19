using System.Runtime.InteropServices;
using System.Text;
namespace Cliphoard.Windows;

/// This adapter never requests Unicode clipboard content until its private run marker matches.
/// Only explicitly synthetic UI actions write this marker. No real capture path exists.
internal sealed class FixtureClipboard
{
    private readonly nint hwnd;
    private readonly uint markerFormat = Native.RegisterClipboardFormat("Cliphoard.SyntheticFixture.v1");
    private readonly string marker = Guid.NewGuid().ToString("N");
    private uint ownSequence;
    internal FixtureClipboard(nint hwnd) { this.hwnd = hwnd; if (markerFormat == 0) throw new IOException("Fixture marker unavailable"); }
    internal string? ReadMarkedUpdate()
    {
        uint sequence = Native.GetClipboardSequenceNumber();
        if (sequence == ownSequence || !Native.IsClipboardFormatAvailable(markerFormat)) return null;
        if (!Native.OpenClipboard(hwnd)) return null;
        try
        {
            if (ReadUnicode(markerFormat, 128) != marker) return null;
            if (!Native.IsClipboardFormatAvailable(Native.CF_UNICODETEXT)) return null;
            string? text = ReadUnicode(Native.CF_UNICODETEXT, 16_386);
            if (Native.GetClipboardSequenceNumber() != sequence || text is null || !text.StartsWith(FixtureEngine.Prefix, StringComparison.Ordinal)
                || Encoding.UTF8.GetByteCount(text) > 8192) return null;
            return text;
        }
        finally { Native.CloseClipboard(); }
    }
    internal bool WriteSynthetic(string text, bool suppressOwn)
    {
        if (!text.StartsWith(FixtureEngine.Prefix, StringComparison.Ordinal) || Encoding.UTF8.GetByteCount(text) > 8192 || text.Contains('\0')) return false;
        nint markerHandle = Allocate(marker), textHandle = Allocate(text);
        if (markerHandle == 0 || textHandle == 0) { Free(markerHandle); Free(textHandle); return false; }
        if (!Native.OpenClipboard(hwnd)) { Free(markerHandle); Free(textHandle); return false; }
        bool success = false;
        try
        {
            if (!Native.EmptyClipboard()) return false;
            if (Native.SetClipboardData(markerFormat, markerHandle) == 0) return false;
            markerHandle = 0; // Windows now owns this allocation.
            if (Native.SetClipboardData(Native.CF_UNICODETEXT, textHandle) == 0) return false;
            textHandle = 0; success = true;
        }
        finally
        {
            Native.CloseClipboard(); Free(markerHandle); Free(textHandle);
            if (success && suppressOwn) ownSequence = Native.GetClipboardSequenceNumber();
        }
        return success;
    }
    private static nint Allocate(string text)
    {
        byte[] bytes = Encoding.Unicode.GetBytes(text + "\0");
        nint memory = Native.GlobalAlloc(2, (nuint)bytes.Length);
        if (memory == 0) return 0;
        nint pointer = Native.GlobalLock(memory);
        if (pointer == 0) { Free(memory); return 0; }
        try { Marshal.Copy(bytes, 0, pointer, bytes.Length); } finally { Native.GlobalUnlock(memory); }
        return memory;
    }
    private static void Free(nint handle) { if (handle != 0) Native.GlobalFree(handle); }
    private static string? ReadUnicode(uint format, int maximumBytes)
    {
        nint handle = Native.GetClipboardData(format);
        if (handle == 0) return null;
        nuint size = Native.GlobalSize(handle);
        if (size < 2 || size > (nuint)maximumBytes || size % 2 != 0) return null;
        nint pointer = Native.GlobalLock(handle);
        if (pointer == 0) return null;
        try
        {
            byte[] bytes = new byte[(int)size]; Marshal.Copy(pointer, bytes, 0, bytes.Length);
            for (int i = 0; i < bytes.Length; i += 2)
                if (bytes[i] == 0 && bytes[i + 1] == 0) return new UnicodeEncoding(false, false, true).GetString(bytes, 0, i);
            return null;
        }
        catch (DecoderFallbackException) { return null; }
        finally { Native.GlobalUnlock(handle); }
    }
}
