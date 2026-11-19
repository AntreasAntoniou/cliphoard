using System.Buffers.Binary;
using System.Reflection;
using System.IO.Compression;
using System.Text.Json;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace Cliphoard.Windows;

/// Executable graphs are compiled application resources. Downloaded data supplies only verified float tensors.
internal sealed class VerifiedGraph : IDisposable
{
    private readonly InferenceSession session;
    private readonly List<NamedOnnxValue> weights = new();

    internal static Stream Resource(string name) => Assembly.GetExecutingAssembly().GetManifestResourceStream("Cliphoard.Windows.ModelGraphs." + name + ".json") ?? throw new IOException("Model graph resource is missing.");

    internal VerifiedGraph(string name, ModelAsset asset)
    {
        using var resource = Resource(name);
        using var recipe = JsonDocument.Parse(resource);
        using var input = VerifiedModelAssets.OpenVerified(asset);
        if (asset.FileName.EndsWith(".bin", StringComparison.Ordinal))
        {
            using var archive = new ZipArchive(input, ZipArchiveMode.Read, leaveOpen: true);
            foreach (var mapping in recipe.RootElement.GetProperty("weights").EnumerateArray())
            {
                long[] shape = mapping.GetProperty("shape").EnumerateArray().Select(value => value.GetInt64()).ToArray();
                long[] strides = mapping.GetProperty("strides").EnumerateArray().Select(value => value.GetInt64()).ToArray();
                long start = mapping.GetProperty("offset").GetInt64();
                long elements = shape.Aggregate(1L, (product, dimension) => checked(product * dimension));
                string entryName = mapping.GetProperty("entry").GetString()!;
                var entry = archive.GetEntry(entryName) ?? throw new IOException("Model storage is missing.");
                if (shape.Length != strides.Length || start < 0 || elements > 25000000 || entry.Length is < 4 or > 100000000 || entry.Length % 4 != 0)
                    throw new IOException("Invalid model storage layout.");
                byte[] bytes = new byte[(int)entry.Length];
                using (var stream = entry.Open()) { stream.ReadExactly(bytes); if (stream.ReadByte() != -1) throw new IOException("Invalid model storage size."); }
                var storage = new float[bytes.Length / 4];
                Buffer.BlockCopy(bytes, 0, storage, 0, bytes.Length);
                var values = new float[(int)elements];
                for (int index = 0; index < values.Length; ++index)
                {
                    long source = start, remainder = index;
                    for (int dimension = shape.Length - 1; dimension >= 0; --dimension)
                    {
                        source = checked(source + remainder % shape[dimension] * strides[dimension]);
                        remainder /= shape[dimension];
                    }
                    if (source < 0 || source >= storage.Length) throw new IOException("Model tensor escapes its storage.");
                    values[index] = storage[source];
                }
                AddWeight(mapping, shape, values);
            }
        }
        else
        {
            Span<byte> sizeBytes = stackalloc byte[8];
            input.ReadExactly(sizeBytes);
            long headerSize = BinaryPrimitives.ReadInt64LittleEndian(sizeBytes);
            if (headerSize is < 2 or > 1048576 || headerSize > input.Length - 8) throw new IOException("Invalid model tensor header.");
            byte[] headerBytes = new byte[(int)headerSize];
            input.ReadExactly(headerBytes);
            using var header = JsonDocument.Parse(headerBytes);
            foreach (var mapping in recipe.RootElement.GetProperty("weights").EnumerateArray())
            {
                string tensorName = mapping.GetProperty("tensor").GetString()!;
                var tensor = header.RootElement.GetProperty(tensorName);
                long[] shape = mapping.GetProperty("shape").EnumerateArray().Select(value => value.GetInt64()).ToArray();
                if (tensor.GetProperty("dtype").GetString() != "F32" || !shape.SequenceEqual(tensor.GetProperty("shape").EnumerateArray().Select(value => value.GetInt64())))
                    throw new IOException("Model tensor layout differs from the reviewed graph.");
                long[] range = tensor.GetProperty("data_offsets").EnumerateArray().Select(value => value.GetInt64()).ToArray();
                long elements = shape.Aggregate(1L, (product, dimension) => checked(product * dimension));
                if (range.Length != 2 || range[0] < 0 || range[1] - range[0] != elements * 4 || range[1] > input.Length - headerSize - 8 || elements > 25000000)
                    throw new IOException("Model tensor exceeds its bounds.");
                input.Position = 8 + headerSize + range[0];
                byte[] bytes = new byte[checked((int)elements * 4)];
                input.ReadExactly(bytes);
                float[] values = new float[(int)elements];
                Buffer.BlockCopy(bytes, 0, values, 0, bytes.Length);
                AddWeight(mapping, shape, values);
            }
        }
        using var options = new SessionOptions { IntraOpNumThreads = 2, InterOpNumThreads = 1 };
        session = new InferenceSession(Convert.FromBase64String(recipe.RootElement.GetProperty("graph").GetString()!), options);
    }

    private void AddWeight(JsonElement mapping, long[] shape, float[] values) => weights.Add(NamedOnnxValue.CreateFromTensor(mapping.GetProperty("name").GetString()!, new DenseTensor<float>(values, shape.Select(dimension => checked((int)dimension)).ToArray())));

    internal float[] Run(IEnumerable<NamedOnnxValue> inputs, string outputName, int dimension, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        using var output = session.Run(weights.Concat(inputs).ToArray());
        float[] vector = output.First(value => value.Name == outputName).AsTensor<float>().ToArray();
        cancellation.ThrowIfCancellationRequested();
        double norm = Math.Sqrt(vector.Sum(value => (double)value * value));
        if (vector.Length != dimension || !double.IsFinite(norm) || norm < .5 || vector.Any(value => !float.IsFinite(value)))
            throw new IOException("Model returned an invalid embedding.");
        return vector;
    }

    public void Dispose() => session.Dispose();
}
