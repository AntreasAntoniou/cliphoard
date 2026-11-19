using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
namespace Cliphoard.Windows;

internal sealed record ModelRequest(string Operation, string Text = "", byte[]? Image = null, byte[]? Audio = null);
internal sealed record ModelResponse(bool Ready, float[]? Vector = null);
internal static class ModelWorkerProtocol
{
    private const int Maximum = 12 * 1024 * 1024;
    internal static async Task WriteAsync<T>(Stream stream, T value, CancellationToken cancellation, int maximumFrame = Maximum)
    {
        if (maximumFrame is < 2 or > 24 * 1024 * 1024) throw new ArgumentOutOfRangeException(nameof(maximumFrame));
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        try
        {
            if (bytes.Length < 2 || bytes.Length > maximumFrame) throw new IOException("Private request exceeds the protocol bound.");
            byte[] header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
            await stream.WriteAsync(header, cancellation); await stream.WriteAsync(bytes, cancellation); await stream.FlushAsync(cancellation);
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    internal static async Task<T> ReadAsync<T>(Stream stream, CancellationToken cancellation, int maximumFrame = Maximum)
    {
        if (maximumFrame is < 2 or > 24 * 1024 * 1024) throw new ArgumentOutOfRangeException(nameof(maximumFrame));
        byte[] header = new byte[4]; await stream.ReadExactlyAsync(header, cancellation);
        int length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length < 2 || length > maximumFrame) throw new IOException("Invalid private frame.");
        byte[] bytes = new byte[length];
        try
        {
            await stream.ReadExactlyAsync(bytes, cancellation);
            return JsonSerializer.Deserialize<T>(bytes) ?? throw new IOException("Invalid private response.");
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
}
