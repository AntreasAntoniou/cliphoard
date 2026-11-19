using System.IO.Compression;
using System.Security.Cryptography;
namespace Cliphoard.Windows;

internal static class GemmaAssets
{
    internal static readonly ModelAsset Model = new("embeddinggemma2-94408f31843f8bd0adb11c262292627287f5fda4", "embeddinggemma-2-740m.litertlm", "https://huggingface.co/litert-community/embeddinggemma-2-740m-litert-lm/resolve/94408f31843f8bd0adb11c262292627287f5fda4/embeddinggemma-2-740m.litertlm", 484622336, "e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c");
    internal static readonly ModelAsset RuntimeArchive = new("litert-lm-0.19.1-capi1", "runtime.zip", "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.19.1/litert_lm_c_api-1.0.0.zip", 123469788, "1d430d80eaf536f696a4922270ba55eb3d112189ac198c3066d487a45e3b4d4c");
    internal static readonly ModelAsset Runtime = new(RuntimeArchive.Folder, "litert-lm.dll", RuntimeArchive.Url, 52962304, "442e411af57bf6cf36ebf11aba03504a02c6f6fbe405010150f87a877ad12a11");
    internal static async Task EnsureAsync(bool download, CancellationToken cancellation, IProgress<string>? progress)
    {
        await VerifiedModelAssets.EnsureAsync(Model, download, cancellation, progress);
        await VerifiedModelAssets.EnsureAsync(RuntimeArchive, download, cancellation, progress);
        if (File.Exists(VerifiedModelAssets.PathFor(Runtime))) { using var verified = VerifiedModelAssets.OpenVerified(Runtime); return; }
        using var source = VerifiedModelAssets.OpenVerified(RuntimeArchive);
        using var archive = new ZipArchive(source, ZipArchiveMode.Read);
        string path = VerifiedModelAssets.PathFor(Runtime), temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var entry = archive.GetEntry("lib/windows_x86_64/bin/litert-lm.dll") ?? throw new IOException("Verified runtime lacks its Windows library.");
            if (entry.Length != Runtime.Size) throw new IOException("Runtime size mismatch.");
            using (var input = entry.Open())
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                await input.CopyToAsync(output, cancellation); output.Flush(true);
            }
            using (var input = File.OpenRead(temporary))
                if (input.Length != Runtime.Size || !Convert.ToHexString(SHA256.HashData(input)).Equals(Runtime.Sha256, StringComparison.OrdinalIgnoreCase)) throw new IOException("Runtime verification failed.");
            cancellation.ThrowIfCancellationRequested();
            try { File.Move(temporary, path); }
            catch (IOException) when (File.Exists(path)) { using var concurrent = VerifiedModelAssets.OpenVerified(Runtime); }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
