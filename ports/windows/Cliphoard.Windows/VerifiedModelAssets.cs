using System.Security.Cryptography;

namespace Cliphoard.Windows;

internal sealed record ModelAsset(string Folder, string FileName, string Url, long Size, string Sha256);

internal static class VerifiedModelAssets
{
    internal static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cliphoard", "models");
    internal static string PathFor(ModelAsset asset) => Path.Combine(Root, asset.Folder, asset.FileName);

    internal static void CheckPath(string path)
    {
        for (FileSystemInfo? entry = File.Exists(path) ? new FileInfo(path) : new DirectoryInfo(path); entry is not null;
             entry = entry is FileInfo file ? file.Directory : ((DirectoryInfo)entry).Parent)
            if (entry.Exists && (entry.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Model paths must be local regular files.");
    }

    internal static FileStream OpenVerified(ModelAsset asset)
    {
        string path = PathFor(asset);
        CheckPath(path);
        var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        try
        {
            if (stream.Length != asset.Size || !Convert.ToHexString(SHA256.HashData(stream)).Equals(asset.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Model verification failed.");
            stream.Position = 0;
            return stream;
        }
        catch { stream.Dispose(); throw; }
    }

    internal static async Task EnsureAsync(ModelAsset asset, bool download, CancellationToken cancellation, IProgress<string>? progress)
    {
        string path = PathFor(asset);
        CheckPath(path);
        if (File.Exists(path)) { using var verified = OpenVerified(asset); return; }
        if (!download) throw new FileNotFoundException("Download and prepare this model in Search settings.");
        string directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        CheckPath(directory);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
            using var response = await client.GetAsync(asset.Url, HttpCompletionOption.ResponseHeadersRead, cancellation);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength is long length && length != asset.Size) throw new IOException("Unexpected model download size.");
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            await using (var input = await response.Content.ReadAsStreamAsync(cancellation))
            {
                byte[] buffer = new byte[131072];
                long total = 0;
                int count, lastPercent = -1;
                while ((count = await input.ReadAsync(buffer, cancellation)) != 0)
                {
                    total += count;
                    if (total > asset.Size) throw new IOException("Model download exceeded its bound.");
                    hash.AppendData(buffer, 0, count);
                    await output.WriteAsync(buffer.AsMemory(0, count), cancellation);
                    int percent = (int)(total * 100 / asset.Size);
                    if (percent != lastPercent) { progress?.Report($"Downloading {asset.FileName} · {percent}%"); lastPercent = percent; }
                }
                if (total != asset.Size || !Convert.ToHexString(hash.GetHashAndReset()).Equals(asset.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Downloaded model verification failed.");
                output.Flush(true);
            }
            cancellation.ThrowIfCancellationRequested();
            CheckPath(directory);
            try { File.Move(temporary, path); }
            catch (IOException) when (File.Exists(path)) { using var concurrent = OpenVerified(asset); }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
