using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace Cliphoard.Windows;

/// Explicitly Windows archive format; not misrepresented as the Mac chunked .cliphoard format.
internal static class PortableHistory
{
    private const int Header = 40, Rounds = 600_000, Limit = 48 * 1024 * 1024;
    internal static byte[] Seal(HistoryState state, string passphrase)
    {
        HistoryStore.ValidateState(state); ValidatePassphrase(passphrase);
        byte[] plain = JsonSerializer.SerializeToUtf8Bytes(state), envelope = new byte[Header + plain.Length + 16];
        if (plain.Length > Limit) { CryptographicOperations.ZeroMemory(plain); throw new IOException("History is too large for this archive."); }
        "CLPHWIN1"u8.CopyTo(envelope); RandomNumberGenerator.Fill(envelope.AsSpan(12, 28)); BinaryPrimitives.WriteInt32BigEndian(envelope.AsSpan(8, 4), Rounds);
        byte[] key = Derive(passphrase, envelope.AsSpan(12, 16));
        try { using var cipher = new AesGcm(key, 16); cipher.Encrypt(envelope.AsSpan(28, 12), plain, envelope.AsSpan(Header, plain.Length), envelope.AsSpan(Header + plain.Length, 16), envelope.AsSpan(0, Header)); return envelope; }
        finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plain); }
    }
    internal static HistoryState Open(byte[] envelope, string passphrase)
    {
        ValidatePassphrase(passphrase);
        if (envelope.Length is < Header + 16 or > Limit + Header + 16 || !envelope.AsSpan(0, 8).SequenceEqual("CLPHWIN1"u8) || BinaryPrimitives.ReadInt32BigEndian(envelope.AsSpan(8, 4)) != Rounds) throw new IOException("This is not a supported Windows history archive.");
        int size = envelope.Length - Header - 16; byte[] plain = new byte[size], key = Derive(passphrase, envelope.AsSpan(12, 16));
        try
        {
            using var cipher = new AesGcm(key, 16); cipher.Decrypt(envelope.AsSpan(28, 12), envelope.AsSpan(Header, size), envelope.AsSpan(Header + size, 16), plain, envelope.AsSpan(0, Header));
            var state = JsonSerializer.Deserialize<HistoryState>(plain) ?? throw new IOException("Archive contents could not be read."); HistoryStore.ValidateState(state); return state;
        }
        finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plain); }
    }
    private static void ValidatePassphrase(string passphrase) { if (passphrase.EnumerateRunes().Count() < 12 || passphrase.Length > 1024) throw new ArgumentException("Use a passphrase of at least 12 characters (at most 1024). Spaces are preserved."); }
    private static byte[] Derive(string passphrase, ReadOnlySpan<byte> salt)
    {
        byte[] utf8 = Encoding.UTF8.GetBytes(passphrase.Normalize(NormalizationForm.FormC));
        try { return Rfc2898DeriveBytes.Pbkdf2(utf8, salt, Rounds, HashAlgorithmName.SHA256, 32); }
        finally { CryptographicOperations.ZeroMemory(utf8); }
    }
    internal static byte[] ReadBounded(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Archive source is a link.");
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length > Limit || file.Length < 8) throw new IOException("Archive size is invalid.");
        var bytes = new byte[checked((int)file.Length)];
        file.ReadExactly(bytes);
        if (file.ReadByte() != -1) throw new IOException("Archive changed during reading.");
        return bytes;
    }
    internal static void WriteAtomic(string destination, byte[] encrypted)
    {
        if (File.Exists(destination) && (File.GetAttributes(destination) & FileAttributes.ReparsePoint) != 0) throw new IOException("Archive destination is a link.");
        string temp = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(encrypted); file.Flush(true); } File.Move(temp, destination, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
