using Cliphoard.Windows;
using System.Media;
using System.Security.Cryptography;
using System.Text.Json;

internal static class CopySoundChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool condition) { ++checks; if (!condition) throw new Exception("Copy sound check " + checks + " failed"); }
        var hashes = new HashSet<string>();
        var names = HistoryState.CaptureSounds.Keys.Where(name => name.StartsWith("copy-", StringComparison.Ordinal)).ToArray();
        Check(names.Length == 12);
        foreach (string name in names)
        {
            string path = Path.Combine(AppContext.BaseDirectory, "Assets", "Sounds", name + ".wav");
            byte[] bytes = File.ReadAllBytes(path);
            Check(hashes.Add(Convert.ToHexString(SHA256.HashData(bytes))));
            using var reader = new BinaryReader(new MemoryStream(bytes));
            Check(new string(reader.ReadChars(4)) == "RIFF" && reader.ReadInt32() == bytes.Length - 8);
            Check(new string(reader.ReadChars(4)) == "WAVE" && new string(reader.ReadChars(4)) == "fmt ");
            Check(reader.ReadInt32() == 16 && reader.ReadInt16() == 1 && reader.ReadInt16() == 1 && reader.ReadInt32() == 44100);
            reader.ReadInt32(); reader.ReadInt16(); Check(reader.ReadInt16() == 16);
            Check(new string(reader.ReadChars(4)) == "data"); int size = reader.ReadInt32();
            Check(size == bytes.Length - 44 && size > 1000 && size <= 44100 * 2);
            int peak = 0; while (reader.BaseStream.Position < bytes.Length) peak = Math.Max(peak, Math.Abs((int)reader.ReadInt16()));
            Check(peak > 1000 && peak < 10000);
            using var player = new SoundPlayer(path); player.Load(); Check(player.IsLoadCompleted);
        }
        string directory = Path.Combine(Path.GetTempPath(), "Cliphoard-sounds-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new HistoryStore(directory);
            foreach (string name in HistoryState.CaptureSounds.Keys)
            {
                store.State.SoundName = name; store.Save();
                Check(new HistoryStore(directory).State.SoundName == name);
            }
        }
        finally { Directory.Delete(directory, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { copy_sound_checks = checks, bundled_sounds = names.Length, status = "passed" }));
    }
}
