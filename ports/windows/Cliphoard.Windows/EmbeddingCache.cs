using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace Cliphoard.Windows;

/// Current-user authenticated records. Each model and clip has an independent atomic record.
internal sealed class EmbeddingCache
{
    private readonly string directory;
    private readonly object gate = new();
    private long? storedBytes;
    private int storedEntries;
    private sealed record Entry(string Id, string Model, string Content, byte[] Vector);
    internal EmbeddingCache(string? directory = null)
    {
        this.directory = directory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cliphoard", "indexes");
    }
    private static string Content(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    private string PathFor(string id, string model)
    {
        if (!Guid.TryParse(id, out Guid clip)) throw new IOException("Invalid index identity.");
        return Path.Combine(directory, clip.ToString("N") + "-" + Content(model) + ".dpapi");
    }
    internal float[]? Read(string id, string model, string text, int dimension)
    {
        lock (gate)
        {
            byte[]? clear = null;
            try
            {
                string path = PathFor(id, model); VerifiedModelAssets.CheckPath(path);
                if (!File.Exists(path) || new FileInfo(path).Length > 32768) return null;
                clear = HistoryStore.Protect(File.ReadAllBytes(path), false);
                Entry? entry = JsonSerializer.Deserialize<Entry>(clear);
                if (entry is null || entry.Id != id || entry.Model != model || entry.Content != Content(text) || entry.Vector is null || entry.Vector.Length != dimension * 2) return null;
                var vector = new float[dimension];
                for (int index = 0; index < dimension; ++index) vector[index] = (float)BitConverter.Int16BitsToHalf(System.Buffers.Binary.BinaryPrimitives.ReadInt16LittleEndian(entry.Vector.AsSpan(index * 2)));
                CryptographicOperations.ZeroMemory(entry.Vector);
                if (!vector.All(float.IsFinite)) return null;
                double norm = Math.Sqrt(vector.Sum(value => (double)value * value));
                return norm > 0 ? vector.Select(value => (float)(value / norm)).ToArray() : null;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException or JsonException) { return null; }
            finally { if (clear is not null) CryptographicOperations.ZeroMemory(clear); }
        }
    }
    internal void Write(string id, string model, string text, float[] vector, CancellationToken cancellation)
    {
        if (vector.Length is < 1 or > 4096 || !vector.All(float.IsFinite) || vector.Any(value => Math.Abs(value) > 65504)) return;
        lock (gate)
        {
            byte[]? clear = null;
            string? temporary = null;
            try
            {
                cancellation.ThrowIfCancellationRequested();
                VerifiedModelAssets.CheckPath(directory); Directory.CreateDirectory(directory);
                string path = PathFor(id, model); VerifiedModelAssets.CheckPath(path);
                if (storedBytes is null)
                {
                    FileInfo[] entries = new DirectoryInfo(directory).EnumerateFiles("*.dpapi").Take(100001).ToArray();
                    storedEntries = entries.Length; storedBytes = entries.Sum(file => file.Length);
                }
                bool exists = File.Exists(path);
                long priorBytes = exists ? new FileInfo(path).Length : 0;
                if (!exists && storedEntries >= 100000) return;
                byte[] packed = new byte[vector.Length * 2];
                for (int index = 0; index < vector.Length; ++index) System.Buffers.Binary.BinaryPrimitives.WriteInt16LittleEndian(packed.AsSpan(index * 2), BitConverter.HalfToInt16Bits((Half)vector[index]));
                clear = JsonSerializer.SerializeToUtf8Bytes(new Entry(id, model, Content(text), packed)); CryptographicOperations.ZeroMemory(packed);
                byte[] cipher = HistoryStore.Protect(clear, true);
                long nextBytes = storedBytes.Value - priorBytes + cipher.Length;
                if (nextBytes > 256L * 1024 * 1024) return;
                temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                File.WriteAllBytes(temporary, cipher);
                cancellation.ThrowIfCancellationRequested();
                VerifiedModelAssets.CheckPath(directory); VerifiedModelAssets.CheckPath(path);
                File.Move(temporary, path, true); storedBytes = nextBytes; if (!exists) ++storedEntries;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException) { }
            finally
            {
                if (clear is not null) CryptographicOperations.ZeroMemory(clear);
                if (temporary is not null && File.Exists(temporary)) File.Delete(temporary);
            }
        }
    }
    internal void Retain(IReadOnlySet<string> ids)
    {
        lock (gate)
        {
            storedBytes = null; storedEntries = 0;
            if (!Directory.Exists(directory)) return;
            VerifiedModelAssets.CheckPath(directory);
            var keep = ids.Where(id => Guid.TryParse(id, out _)).Select(id => Guid.Parse(id).ToString("N")).ToHashSet(StringComparer.Ordinal);
            foreach (string path in Directory.EnumerateFiles(directory, "*.dpapi"))
            {
                string name = Path.GetFileName(path);
                if (name.Length != 103 || !Guid.TryParseExact(name[..32], "N", out _) || keep.Contains(name[..32])) continue;
                VerifiedModelAssets.CheckPath(path); File.Delete(path);
            }
        }
    }
    internal void Forget() => Retain(new HashSet<string>());
}
