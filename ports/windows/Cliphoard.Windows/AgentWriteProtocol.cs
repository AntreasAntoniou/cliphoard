using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Org.BouncyCastle.Math.EC.Rfc7748;
namespace Cliphoard.Windows;

internal sealed record AgentHost([property: JsonPropertyName("processID")] int ProcessId, ulong StartSeconds, ulong StartMicroseconds, string BootSession);
internal sealed record AgentSession(int Version, [property: JsonPropertyName("sessionID")] string SessionId, double? ExpiresAt, byte[] PublicKey, string? Lifetime = null, AgentHost? Host = null);
internal sealed record AgentRequest(int Version, [property: JsonPropertyName("sessionID")] string SessionId, [property: JsonPropertyName("requestID")] string RequestId, double CreatedAt, string Text);
internal sealed record AgentReceipt(int Version, [property: JsonPropertyName("sessionID")] string SessionId, [property: JsonPropertyName("requestID")] string RequestId, string RequestDigest, string Status, [property: JsonPropertyName("clipID")] string? ClipId);
internal sealed record AgentOpened(AgentRequest Request, byte[] ResponseKey, string RequestDigest) : IDisposable
{
    public void Dispose() => CryptographicOperations.ZeroMemory(ResponseKey);
}
internal sealed record AgentPrepared(byte[] Data, byte[] ResponseKey, string RequestDigest, string SessionId, string RequestId) : IDisposable
{
    public void Dispose() => CryptographicOperations.ZeroMemory(ResponseKey);
}

/// Compatible with the Mac encrypted folder protocol for append-only notes.
internal static class AgentWriteProtocol
{
    internal const int MaximumTextBytes = 32768, MaximumWireBytes = 65536;
    internal const double SessionDuration = 900, RequestDuration = 120;
    private sealed record Envelope(int Version, [property: JsonPropertyName("sessionID")] string SessionId, [property: JsonPropertyName("requestID")] string RequestId, string RequestDigest, byte[] EphemeralPublicKey, byte[] Sealed);
    private sealed record ResponseEnvelope(int Version, [property: JsonPropertyName("sessionID")] string SessionId, [property: JsonPropertyName("requestID")] string RequestId, string RequestDigest, byte[] Sealed);
    private static readonly JsonSerializerOptions Options = CreateOptions();
    private static JsonSerializerOptions CreateOptions()
    {
        var resolver = new DefaultJsonTypeInfoResolver();
        resolver.Modifiers.Add(info => { int order = 0; foreach (JsonPropertyInfo property in info.Properties.OrderBy(property => property.Name, StringComparer.Ordinal)) property.Order = order++; });
        return new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, TypeInfoResolver = resolver };
    }
    internal static byte[] Encode<T>(T value)
    {
        JsonElement element = JsonSerializer.SerializeToElement(value, Options);
        var output = new StringBuilder();
        void Quoted(string text)
        {
            output.Append('"');
            foreach (Rune rune in text.EnumerateRunes())
                output.Append(rune.Value switch
                {
                    34 => "\\\"", 92 => "\\\\", 8 => "\\b", 12 => "\\f", 10 => "\\n", 13 => "\\r", 9 => "\\t",
                    < 32 => "\\u" + rune.Value.ToString("x4", System.Globalization.CultureInfo.InvariantCulture),
                    _ => rune.ToString()
                });
            output.Append('"');
        }
        void Write(JsonElement item)
        {
            switch (item.ValueKind)
            {
                case JsonValueKind.Object:
                    output.Append('{'); bool first = true;
                    foreach (JsonProperty property in item.EnumerateObject().OrderBy(property => property.Name, StringComparer.Ordinal))
                    {
                        if (!first) output.Append(','); first = false; Quoted(property.Name); output.Append(':'); Write(property.Value);
                    }
                    output.Append('}'); break;
                case JsonValueKind.Array:
                    output.Append('['); bool initial = true;
                    foreach (JsonElement child in item.EnumerateArray()) { if (!initial) output.Append(','); initial = false; Write(child); }
                    output.Append(']'); break;
                case JsonValueKind.String: Quoted(item.GetString()!); break;
                default: output.Append(item.GetRawText()); break;
            }
        }
        Write(element); return Encoding.UTF8.GetBytes(output.ToString());
    }
    private static T Decode<T>(byte[] bytes, int maximum = MaximumWireBytes)
    {
        if (bytes.Length < 1 || bytes.Length > maximum) throw new IOException("Invalid agent frame.");
        T value = JsonSerializer.Deserialize<T>(bytes, Options) ?? throw new IOException("Invalid agent frame.");
        byte[] canonical = Encode(value);
        try { if (!canonical.AsSpan().SequenceEqual(bytes)) throw new IOException("Noncanonical agent frame."); }
        finally { CryptographicOperations.ZeroMemory(canonical); }
        return value;
    }
    private static bool Uuid(string? value) => value is not null && Guid.TryParseExact(value, "D", out Guid id) && value == id.ToString("D").ToUpperInvariant();
    private static bool Digest(string? value) => value is { Length: 64 } && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');
    internal static byte[] PublicKey(byte[] privateKey)
    {
        if (privateKey.Length != 32) throw new CryptographicException("Invalid agent key.");
        var result = new byte[32]; X25519.GeneratePublicKey(privateKey, 0, result, 0); return result;
    }
    internal static void ValidateSession(AgentSession session, double now)
    {
        if (!double.IsFinite(now) || !Uuid(session.SessionId) || session.PublicKey is not { Length: 32 }) throw new IOException("Invalid agent session.");
        if (session.Version == 1)
        {
            if (session.Lifetime is not null || session.Host is not null || session.ExpiresAt is null) throw new IOException("Invalid agent session.");
        }
        else if (session.Version == 2)
        {
            AgentHost? host = session.Host;
            if (session.Lifetime is not ("bounded" or "whileAppRuns") || host is null || host.ProcessId <= 0 || host.StartSeconds == 0 || host.StartMicroseconds >= 1000000
                || !Guid.TryParseExact(host.BootSession, "D", out Guid boot) || boot.ToString("D") != host.BootSession || (session.Lifetime == "whileAppRuns") != (session.ExpiresAt is null)) throw new IOException("Invalid agent host.");
        }
        else throw new IOException("Unsupported agent session.");
        if (session.ExpiresAt is double expiry && (!double.IsFinite(expiry) || now >= expiry || expiry - now > SessionDuration + 5)) throw new IOException("Agent session expired.");
    }
    internal static byte[] EncodeSession(AgentSession session, double now) { ValidateSession(session, now); return Encode(session); }
    internal static AgentSession DecodeSession(byte[] bytes, double now) { AgentSession session = Decode<AgentSession>(bytes, 1024); ValidateSession(session, now); return session; }
    private static void ValidateRequest(AgentRequest request, AgentSession session, double now)
    {
        ValidateSession(session, now);
        if (request.Version != 1 || request.SessionId != session.SessionId || !Uuid(request.RequestId) || !double.IsFinite(request.CreatedAt) || string.IsNullOrWhiteSpace(request.Text)
            || Encoding.UTF8.GetByteCount(request.Text) > MaximumTextBytes || request.Text.Contains('\0')) throw new IOException("Invalid agent request.");
        if (request.CreatedAt > now + 5 || now - request.CreatedAt >= RequestDuration || session.ExpiresAt is double expiry && request.CreatedAt >= expiry) throw new IOException("Agent request expired.");
    }
    private static byte[] Shared(byte[] privateKey, byte[] publicKey)
    {
        if (privateKey.Length != 32 || publicKey.Length != 32) throw new CryptographicException("Invalid agent key.");
        var secret = new byte[32];
        if (X25519.CalculateAgreement(privateKey, 0, publicKey, 0, secret, 0)) return secret;
        CryptographicOperations.ZeroMemory(secret); throw new CryptographicException("Invalid agent agreement.");
    }
    private static byte[] Key(byte[] shared, string direction, string session, string request) => HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, Encoding.UTF8.GetBytes(session), Encoding.UTF8.GetBytes($"Cliphoard.AgentWrite.v1|{direction}|{request}"));
    private static byte[] Context(string direction, string session, string request, string digest) => Encoding.UTF8.GetBytes($"Cliphoard.AgentWrite.v1|{direction}|{session}|{request}|{digest}");
    private static byte[] Seal(byte[] plain, byte[] key, byte[] aad)
    {
        byte[] combined = new byte[12 + plain.Length + 16]; RandomNumberGenerator.Fill(combined.AsSpan(0, 12));
        using var aes = new AesGcm(key, 16); aes.Encrypt(combined.AsSpan(0, 12), plain, combined.AsSpan(12, plain.Length), combined.AsSpan(12 + plain.Length, 16), aad); return combined;
    }
    private static byte[] Open(byte[] combined, byte[] key, byte[] aad)
    {
        if (combined.Length is < 28 or > MaximumWireBytes) throw new CryptographicException("Invalid agent ciphertext.");
        byte[] plain = new byte[combined.Length - 28];
        try { using var aes = new AesGcm(key, 16); aes.Decrypt(combined.AsSpan(0, 12), combined.AsSpan(12, plain.Length), combined.AsSpan(12 + plain.Length, 16), plain, aad); return plain; }
        catch { CryptographicOperations.ZeroMemory(plain); throw; }
    }
    internal static AgentPrepared Prepare(AgentRequest request, AgentSession session, double now)
    {
        ValidateRequest(request, session, now);
        byte[] ephemeral = RandomNumberGenerator.GetBytes(32), shared = Array.Empty<byte>(), plain = Array.Empty<byte>(), requestKey = Array.Empty<byte>();
        try
        {
            shared = Shared(ephemeral, session.PublicKey); plain = Encode(request); requestKey = Key(shared, "request", request.SessionId, request.RequestId);
            byte[] sealedBytes = Seal(plain, requestKey, Context("request", request.SessionId, request.RequestId, ""));
            string digest = Convert.ToHexString(SHA256.HashData(sealedBytes)).ToLowerInvariant();
            byte[] data = Encode(new Envelope(1, request.SessionId, request.RequestId, digest, PublicKey(ephemeral), sealedBytes));
            if (data.Length > MaximumWireBytes) throw new IOException("Agent request exceeds its bound.");
            return new(data, Key(shared, "response", request.SessionId, request.RequestId), digest, request.SessionId, request.RequestId);
        }
        finally { CryptographicOperations.ZeroMemory(ephemeral); CryptographicOperations.ZeroMemory(shared); CryptographicOperations.ZeroMemory(plain); CryptographicOperations.ZeroMemory(requestKey); }
    }
    internal static AgentOpened OpenRequest(byte[] data, AgentSession session, byte[] privateKey, double now)
    {
        ValidateSession(session, now);
        if (!PublicKey(privateKey).AsSpan().SequenceEqual(session.PublicKey)) throw new CryptographicException("Agent key does not match this session.");
        Envelope envelope = Decode<Envelope>(data);
        if (envelope.Version != 1 || envelope.SessionId != session.SessionId || !Uuid(envelope.RequestId) || envelope.EphemeralPublicKey is not { Length: 32 } || envelope.Sealed is null || !Digest(envelope.RequestDigest)) throw new IOException("Invalid agent envelope.");
        if (Convert.ToHexString(SHA256.HashData(envelope.Sealed)).ToLowerInvariant() != envelope.RequestDigest) throw new CryptographicException("Agent ciphertext changed.");
        byte[] shared = Shared(privateKey, envelope.EphemeralPublicKey), requestKey = Key(shared, "request", envelope.SessionId, envelope.RequestId);
        byte[]? plain = null;
        try
        {
            plain = Open(envelope.Sealed, requestKey, Context("request", envelope.SessionId, envelope.RequestId, ""));
            AgentRequest request = Decode<AgentRequest>(plain);
            if (request.RequestId != envelope.RequestId || request.SessionId != envelope.SessionId) throw new IOException("Agent request identity changed.");
            ValidateRequest(request, session, now);
            return new(request, Key(shared, "response", envelope.SessionId, envelope.RequestId), envelope.RequestDigest);
        }
        finally { CryptographicOperations.ZeroMemory(shared); CryptographicOperations.ZeroMemory(requestKey); if (plain is not null) CryptographicOperations.ZeroMemory(plain); }
    }
    internal static byte[] SealReceipt(string status, AgentOpened opened)
    {
        if (status is not ("saved" or "rejected" or "expired" or "unavailable")) throw new IOException("Invalid agent receipt status.");
        AgentRequest request = opened.Request;
        byte[] plain = Encode(new AgentReceipt(1, request.SessionId, request.RequestId, opened.RequestDigest, status, status == "saved" ? request.RequestId : null));
        try { return Encode(new ResponseEnvelope(1, request.SessionId, request.RequestId, opened.RequestDigest, Seal(plain, opened.ResponseKey, Context("response", request.SessionId, request.RequestId, opened.RequestDigest)))); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    internal static AgentReceipt OpenReceipt(byte[] data, AgentPrepared prepared, string session, string request)
    {
        if (session != prepared.SessionId || request != prepared.RequestId) throw new IOException("Agent receipt scope changed.");
        ResponseEnvelope envelope = Decode<ResponseEnvelope>(data, 2048);
        if (envelope.Version != 1 || envelope.SessionId != session || envelope.RequestId != request || envelope.RequestDigest != prepared.RequestDigest) throw new CryptographicException("Agent receipt identity changed.");
        byte[] plain = Open(envelope.Sealed, prepared.ResponseKey, Context("response", session, request, prepared.RequestDigest));
        try
        {
            AgentReceipt receipt = Decode<AgentReceipt>(plain, 1024);
            if (receipt.Version != 1 || receipt.SessionId != session || receipt.RequestId != request || receipt.RequestDigest != prepared.RequestDigest || receipt.Status is not ("saved" or "rejected" or "expired" or "unavailable") || receipt.ClipId != (receipt.Status == "saved" ? request : null)) throw new CryptographicException("Invalid agent receipt.");
            return receipt;
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
}
