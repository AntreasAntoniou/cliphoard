using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
namespace Cliphoard.Windows;
internal sealed record WindowsRelease(Version Version, string Tag, Uri Page);
internal static class WindowsReleases
{
    private const string Repository = "https://github.com/AntreasAntoniou/cliphoard";
    internal static WindowsRelease? Latest(byte[] data, string architecture)
    {
        if (data.Length > 524288 || architecture is not ("arm64" or "x64")) throw new IOException("Invalid release metadata.");
        using var json = JsonDocument.Parse(data);
        if (json.RootElement.ValueKind != JsonValueKind.Array) throw new IOException("Invalid release metadata.");
        var releases = new List<WindowsRelease>();
        foreach (JsonElement release in json.RootElement.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean()) continue;
            string? tag = release.GetProperty("tag_name").GetString();
            if (string.IsNullOrEmpty(tag) || tag.Length > 100 || !tag.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.')) continue;
            string page = Repository + "/releases/tag/" + tag;
            if (release.GetProperty("html_url").GetString() != page) continue;
            foreach (JsonElement asset in release.GetProperty("assets").EnumerateArray())
            {
                string? name = asset.GetProperty("name").GetString();
                string suffix = "-" + architecture + ".msi";
                if (name is null || !name.StartsWith("Cliphoard-", StringComparison.Ordinal) || !name.EndsWith(suffix, StringComparison.Ordinal)) continue;
                string text = name[10..^suffix.Length];
                if (!Version.TryParse(text, out Version? version) || version.Revision < 0 || version.ToString(4) != text || version.Major > 255 || version.Minor > 255 || version.Build > 65535) continue;
                if (asset.GetProperty("state").GetString() != "uploaded" || asset.GetProperty("size").GetInt64() <= 0 || asset.GetProperty("browser_download_url").GetString() != Repository + "/releases/download/" + tag + "/" + name) continue;
                releases.Add(new(version, tag, new Uri(page)));
            }
        }
        return releases.OrderByDescending(release => release.Version).FirstOrDefault();
    }
    internal static async Task<WindowsRelease?> CheckAsync(CancellationToken cancellation)
    {
        using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(25) };
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/repos/AntreasAntoniou/cliphoard/releases?per_page=20");
        request.Headers.UserAgent.ParseAdd("Cliphoard-Windows-release-check"); request.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > 524288) throw new IOException("Release metadata exceeds its bound.");
        using var output = new MemoryStream(); using var input = await response.Content.ReadAsStreamAsync(cancellation);
        byte[] buffer = new byte[16384]; int read;
        while ((read = await input.ReadAsync(buffer, cancellation)) != 0) { if (output.Length + read > 524288) throw new IOException("Release metadata exceeds its bound."); output.Write(buffer, 0, read); }
        return Latest(output.ToArray(), RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64");
    }
}
