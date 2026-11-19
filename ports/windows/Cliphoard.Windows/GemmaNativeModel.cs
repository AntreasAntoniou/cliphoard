using System.Runtime.InteropServices;
using System.Text;
namespace Cliphoard.Windows;

/// Used inside the private x64 worker. It holds verified model bytes read-locked through engine teardown.
internal sealed class GemmaNativeModel : IDisposable
{
    private const string Library = "cliphoard-litert-runtime";
    private static readonly Lazy<nint> Runtime = new(() =>
    {
        if (RuntimeInformation.ProcessArchitecture != Architecture.X64) throw new IOException("The Gemma runtime requires the private x64 worker.");
        using var verified = VerifiedModelAssets.OpenVerified(GemmaAssets.Runtime);
        return NativeLibrary.Load(VerifiedModelAssets.PathFor(GemmaAssets.Runtime));
    });
    static GemmaNativeModel() => NativeLibrary.SetDllImportResolver(typeof(GemmaNativeModel).Assembly, (name, _, _) => name == Library ? Runtime.Value : 0);
    private readonly FileStream modelLease;
    private nint engine;
    internal GemmaNativeModel()
    {
        modelLease = VerifiedModelAssets.OpenVerified(GemmaAssets.Model);
        nint settings = 0;
        try
        {
            Check(SettingsCreate(VerifiedModelAssets.PathFor(GemmaAssets.Model), "cpu", "cpu", "cpu", out settings));
            Check(Threads(settings, 2)); Check(AudioThreads(settings, 2)); Check(MaxInput(settings, 2048)); Check(VisionTokens(settings, 70));
            Check(EngineCreate(settings, out engine));
        }
        catch { modelLease.Dispose(); throw; }
        finally { if (settings != 0) SettingsDelete(settings); }
    }
    internal float[] Embed(string text, bool query, byte[]? image = null, byte[]? audio = null)
    {
        if (engine == 0 || Encoding.UTF8.GetByteCount(text) > 1024 || image is not null && audio is not null || image?.Length > 8 * 1024 * 1024 || audio?.Length > 960044)
            throw new IOException("Gemma input exceeds the local request contract.");
        if (image is not null && !ClipboardContent.IsPng(image)) throw new IOException("Gemma accepts bounded PNG images.");
        if (audio is not null)
        {
            float[] samples = WavePcm.Read(audio);
            try { if (samples.Length > 480000) throw new IOException("Gemma audio is limited to thirty seconds."); }
            finally { Array.Clear(samples); }
        }
        string prefix = query ? "task: search result | query: " : "title: none | text: ";
        var inputs = new List<nint>();
        nint response = 0;
        try
        {
            byte[] bytes = Encoding.UTF8.GetBytes(prefix + text);
            Check(InputCreate(0, bytes, (nuint)bytes.Length, out nint content)); inputs.Add(content);
            if (image is not null) { Check(InputCreate(1, image, (nuint)image.Length, out content)); inputs.Add(content); }
            if (audio is not null) { Check(InputCreate(3, audio, (nuint)audio.Length, out content)); inputs.Add(content); }
            Check(Compute(engine, inputs.ToArray(), (nuint)inputs.Count, 0, out response));
            Check(ResponseSize(response, out nuint count));
            if (count != 768) throw new IOException("Unexpected Gemma embedding dimension.");
            Check(ResponseValues(response, out nint values));
            var vector = new float[768]; Marshal.Copy(values, vector, 0, vector.Length);
            double norm = Math.Sqrt(vector.Sum(value => (double)value * value));
            if (!double.IsFinite(norm) || norm is < .9 or > 1.1 || vector.Any(value => !float.IsFinite(value))) throw new IOException("Invalid Gemma embedding.");
            return vector;
        }
        finally { if (response != 0) ResponseDelete(response); foreach (nint input in inputs) InputDelete(input); }
    }
    private static void Check(int status) { if (status != 0) throw new IOException("Local Gemma inference failed."); }
    public void Dispose() { if (engine != 0) { EngineDelete(engine); engine = 0; } modelLease.Dispose(); }

    [DllImport(Library, EntryPoint = "litert_lm_embedding_engine_settings_create", CallingConvention = CallingConvention.Cdecl)] private static extern int SettingsCreate([MarshalAs(UnmanagedType.LPUTF8Str)] string path, [MarshalAs(UnmanagedType.LPUTF8Str)] string backend, [MarshalAs(UnmanagedType.LPUTF8Str)] string vision, [MarshalAs(UnmanagedType.LPUTF8Str)] string audio, out nint result);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_engine_settings_delete", CallingConvention = CallingConvention.Cdecl)] private static extern void SettingsDelete(nint settings);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_engine_settings_set_num_threads", CallingConvention = CallingConvention.Cdecl)] private static extern int Threads(nint settings, int count);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_engine_settings_set_audio_num_threads", CallingConvention = CallingConvention.Cdecl)] private static extern int AudioThreads(nint settings, int count);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_engine_settings_set_max_input_length", CallingConvention = CallingConvention.Cdecl)] private static extern int MaxInput(nint settings, int count);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_engine_settings_set_vision_tokens_per_image", CallingConvention = CallingConvention.Cdecl)] private static extern int VisionTokens(nint settings, int count);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_engine_create", CallingConvention = CallingConvention.Cdecl)] private static extern int EngineCreate(nint settings, out nint engine);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_engine_delete", CallingConvention = CallingConvention.Cdecl)] private static extern void EngineDelete(nint engine);
    [DllImport(Library, EntryPoint = "litert_lm_input_data_create", CallingConvention = CallingConvention.Cdecl)] private static extern int InputCreate(int type, byte[] data, nuint size, out nint input);
    [DllImport(Library, EntryPoint = "litert_lm_input_data_delete", CallingConvention = CallingConvention.Cdecl)] private static extern void InputDelete(nint input);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_engine_compute_embedding", CallingConvention = CallingConvention.Cdecl)] private static extern int Compute(nint engine, nint[] inputs, nuint count, nint options, out nint response);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_response_get_size", CallingConvention = CallingConvention.Cdecl)] private static extern int ResponseSize(nint response, out nuint count);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_response_get_values", CallingConvention = CallingConvention.Cdecl)] private static extern int ResponseValues(nint response, out nint values);
    [DllImport(Library, EntryPoint = "litert_lm_embedding_response_delete", CallingConvention = CallingConvention.Cdecl)] private static extern void ResponseDelete(nint response);
}
