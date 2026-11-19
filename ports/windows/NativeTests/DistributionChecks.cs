using Cliphoard.Windows;
using Org.BouncyCastle.Math.EC.Rfc8032;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
internal static class DistributionChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Distribution check {checks} failed"); }
        byte[] seed = RandomNumberGenerator.GetBytes(32), publicKey = new byte[32];
        try
        {
            Ed25519.GeneratePublicKey(seed, 0, publicKey, 0);
            string Key(string text)
            {
                byte[] payload = Encoding.UTF8.GetBytes(text), signature = new byte[64]; Ed25519.Sign(seed, 0, payload, 0, payload.Length, signature, 0);
                string Encode(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
                return "CLIP1-" + Encode(payload) + "." + Encode(signature);
            }
            string good = Key("{\"o\":\"synthetic-order\",\"i\":1730000000,\"p\":\"pro\",\"v\":1}");
            Check(OfflineLicence.VerifyUsingPublicKey(good, publicKey).Pro);
            Check(!OfflineLicence.Verify(good).Pro);
            Check(OfflineLicence.VerifyUsingPublicKey(" \n" + good + "\n", publicKey).Order == "synthetic-order");
            string[] parts = good.Split('.');
            string signatureText = parts[1].Replace('-', '+').Replace('_', '/');
            byte[] tampered = Convert.FromBase64String(signatureText.PadRight((signatureText.Length + 3) / 4 * 4, '=')); tampered[0] ^= 1;
            Check(!OfflineLicence.VerifyUsingPublicKey(parts[0] + "." + Convert.ToBase64String(tampered).TrimEnd('=').Replace('+', '-').Replace('/', '_'), publicKey).Pro);
            Check(!OfflineLicence.VerifyUsingPublicKey(Key("{\"o\":\"synthetic\",\"i\":1,\"p\":\"free\",\"v\":1}"), publicKey).Pro);
            Check(!OfflineLicence.VerifyUsingPublicKey(Key("{\"o\":\"\",\"i\":1,\"p\":\"pro\",\"v\":1}"), publicKey).Pro);
            foreach (string invalid in new[] { "", "CLIP1-", "CLIP1-a.b", "CLIP2-a.b", new string('x', 20000) }) Check(!OfflineLicence.Verify(invalid).Pro);
        }
        finally { CryptographicOperations.ZeroMemory(seed); }
        string repository = "https://github.com/AntreasAntoniou/cliphoard", tag = "windows-v9.1.2.3", name = "Cliphoard-9.1.2.3-arm64.msi";
        byte[] Feed(bool draft = false, bool prerelease = false, string? assetName = null, string? assetUrl = null) => JsonSerializer.SerializeToUtf8Bytes(new[] { new { draft, prerelease, tag_name = tag, html_url = repository + "/releases/tag/" + tag, assets = new[] { new { name = assetName ?? name, state = "uploaded", size = 12345, browser_download_url = assetUrl ?? repository + "/releases/download/" + tag + "/" + name } } } });
        Check(WindowsReleases.Latest(Feed(), "arm64")?.Version == new Version(9, 1, 2, 3));
        Check(WindowsReleases.Latest(Feed(), "x64") is null);
        Check(WindowsReleases.Latest(Feed(draft: true), "arm64") is null);
        Check(WindowsReleases.Latest(Feed(prerelease: true), "arm64") is null);
        Check(WindowsReleases.Latest(Feed(assetUrl: "https://example.com/foreign.msi"), "arm64") is null);
        Check(WindowsReleases.Latest(Feed(assetName: "Cliphoard-9.1.2-arm64.msi"), "arm64") is null);
        Check(WindowsReleases.Latest("[]"u8.ToArray(), "arm64") is null);
        Console.WriteLine(JsonSerializer.Serialize(new { distribution_checks = checks, status = "passed", synthetic_signing_keys_only = true }));
    }
}
