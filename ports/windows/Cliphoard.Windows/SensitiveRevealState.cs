using System.Security.Cryptography;
using System.Text;

namespace Cliphoard.Windows;

internal sealed class SensitiveRevealState
{
    internal sealed record Request(Guid Nonce, string Id, string Fingerprint);
    private Request? pending, grant;
    private long expires;
    internal int Count => grant is null ? 0 : 1;

    internal Request Begin(HistoryItem item)
    {
        Clear();
        return pending = new(Guid.NewGuid(), item.Id, Fingerprint(item));
    }

    internal bool Complete(Request request, HistoryItem item, bool success, long now)
    {
        if (pending != request) return false;
        pending = null;
        if (!success || request.Id != item.Id || request.Fingerprint != Fingerprint(item)) return false;
        grant = request;
        expires = checked(now + 60000);
        return true;
    }

    internal bool Permits(HistoryItem item, long now) => grant is not null
        && now >= expires - 60000 && now < expires
        && grant.Id == item.Id && grant.Fingerprint == Fingerprint(item);

    internal bool Expire(long now)
    {
        if (grant is null || now >= expires - 60000 && now < expires) return false;
        Clear();
        return true;
    }

    internal void Clear() { pending = null; grant = null; expires = 0; }

    internal static string Fingerprint(HistoryItem item)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (string value in new[] { item.Text, item.Source, item.Kind, item.OcrText ?? "", item.DocumentText ?? "", item.Transcript ?? "", string.Join('\0', item.Tags), item.Flags.ToString(System.Globalization.CultureInfo.InvariantCulture) })
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value);
            hash.AppendData(BitConverter.GetBytes(bytes.Length));
            hash.AppendData(bytes);
            CryptographicOperations.ZeroMemory(bytes);
        }
        foreach (byte[] bytes in new[] { item.Payload ?? Array.Empty<byte>(), item.RichText ?? Array.Empty<byte>(), item.Html ?? Array.Empty<byte>() })
        {
            hash.AppendData(BitConverter.GetBytes(bytes.Length));
            hash.AppendData(bytes);
        }
        byte[] media = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(item.MediaIndex);
        try { hash.AppendData(BitConverter.GetBytes(media.Length)); hash.AppendData(media); }
        finally { CryptographicOperations.ZeroMemory(media); }
        return Convert.ToHexString(hash.GetHashAndReset());
    }
}
