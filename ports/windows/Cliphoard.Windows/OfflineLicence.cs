using System.Text.Json;
using Org.BouncyCastle.Math.EC.Rfc8032;
namespace Cliphoard.Windows;
internal sealed record LicenceEntitlement(bool Pro, string? Order = null, double? Issued = null, string? Reason = null);
internal static class OfflineLicence
{
    private static readonly byte[] PublicKey = Convert.FromHexString("DF8505008123F0790AA4C8F071C9FCF38E31475DA851ACE28EC63CA59A8CBF26");
    internal static LicenceEntitlement Verify(string key) => VerifyUsingPublicKey(key, PublicKey);
    internal static LicenceEntitlement VerifyUsingPublicKey(string key, byte[] publicKey)
    {
        string trimmed = key.Trim();
        if (trimmed.Length == 0) return new(false);
        if (trimmed.Length > 16384 || !trimmed.StartsWith("CLIP1-", StringComparison.Ordinal)) return new(false, Reason: "Not a Cliphoard key.");
        try
        {
            string[] parts = trimmed[6..].Split('.');
            if (parts.Length != 2) return new(false, Reason: "Malformed key.");
            byte[] Decode(string text) => Convert.FromBase64String(text.Replace('-', '+').Replace('_', '/').PadRight((text.Length + 3) / 4 * 4, '='));
            byte[] payload = Decode(parts[0]), signature = Decode(parts[1]);
            if (signature.Length != 64 || publicKey.Length != 32 || !Ed25519.Verify(signature, 0, publicKey, 0, payload, 0, payload.Length)) return new(false, Reason: "Signature does not verify.");
            using var json = JsonDocument.Parse(payload);
            JsonElement item = json.RootElement;
            if (item.ValueKind != JsonValueKind.Object || !item.TryGetProperty("o", out var order) || order.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(order.GetString())
                || !item.TryGetProperty("i", out var issued) || !issued.TryGetDouble(out double epoch) || !double.IsFinite(epoch)
                || !item.TryGetProperty("p", out var product) || product.GetString() != "pro"
                || !item.TryGetProperty("v", out var version) || !version.TryGetInt32(out int schema) || schema < 1)
                return new(false, Reason: "Signature valid but payload unrecognised.");
            return new(true, order.GetString(), epoch);
        }
        catch (Exception error) when (error is FormatException or JsonException or ArgumentException or InvalidOperationException) { return new(false, Reason: "Malformed key."); }
    }
}
