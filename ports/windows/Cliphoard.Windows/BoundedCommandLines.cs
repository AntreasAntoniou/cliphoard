using System.Text;
namespace Cliphoard.Windows;

internal sealed class BoundedCommandLines : IAsyncDisposable
{
    private readonly Stream input;
    private readonly byte[] buffer = new byte[4096];
    private readonly MemoryStream line = new();
    private readonly CancellationTokenSource lifetime = new();
    private Task<int>? pending;
    private int position, length;
    internal BoundedCommandLines(Stream input) { this.input = input; }
    internal async Task<byte[]?> NextAsync(Action validate, CancellationToken cancellation, int maximum = 262144)
    {
        while (true)
        {
            cancellation.ThrowIfCancellationRequested(); validate();
            while (position < length)
            {
                byte value = buffer[position++];
                if (value == 10)
                {
                    byte[] bytes = line.ToArray();
                    System.Security.Cryptography.CryptographicOperations.ZeroMemory(line.GetBuffer().AsSpan(0, (int)line.Length)); line.SetLength(0);
                    if (bytes.Length > 0 && bytes[^1] == 13) bytes = bytes[..^1];
                    _ = new UTF8Encoding(false, true).GetCharCount(bytes); return bytes;
                }
                if (line.Length >= maximum) throw new IOException("Command line exceeds its bound.");
                line.WriteByte(value);
            }
            pending ??= input.ReadAsync(buffer.AsMemory(), lifetime.Token).AsTask();
            if (await Task.WhenAny(pending, Task.Delay(1000, cancellation)) != pending) continue;
            length = await pending; pending = null; position = 0;
            if (length == 0) { if (line.Length != 0) throw new IOException("Incomplete command line."); return null; }
        }
    }
    public ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        if (pending is { IsCompleted: false })
            _ = pending.ContinueWith(task => { _ = task.Exception; System.Security.Cryptography.CryptographicOperations.ZeroMemory(buffer); }, TaskScheduler.Default);
        else System.Security.Cryptography.CryptographicOperations.ZeroMemory(buffer);
        System.Security.Cryptography.CryptographicOperations.ZeroMemory(line.GetBuffer());
        line.Dispose(); lifetime.Dispose();
        return ValueTask.CompletedTask;
    }
}
