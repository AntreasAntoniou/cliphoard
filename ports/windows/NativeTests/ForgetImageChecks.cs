using Cliphoard.Windows;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
internal static class ForgetImageChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Forget image check {checks} failed"); }
        string folder = Path.Combine(Path.GetTempPath(), "CliphoardForgetImagesFixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
        try
        {
            using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.SyntheticRed.png")!; using var bytes = new MemoryStream(); source.CopyTo(bytes);
            var history = new HistoryStore(folder);
            var image = new HistoryItem { Text = "Synthetic image", Kind = "Image", Format = 0, Payload = bytes.ToArray(), OcrText = "synthetic recognized words", MacMetadata = "{\"ocrText\":\"synthetic recognized words\",\"preserved\":\"synthetic metadata\"}", Flags = 1 };
            byte[] vector = new byte[8]; BitConverter.GetBytes(1f).CopyTo(vector, 0);
            image.MacRecords.Add(new() { Type = 3, Name = image.Id, Body = JsonSerializer.SerializeToUtf8Bytes(new { revision = 1, vectorB64 = Convert.ToBase64String(vector) }) });
            history.Add(image); history.ForgetImageUnderstanding();
            HistoryItem restored = new HistoryStore(folder).State.Items.Single();
            Check(restored.OcrText == "" && restored.MacRecords.Count == 0 && restored.Flags == 1);
            JsonObject metadata = JsonNode.Parse(restored.MacMetadata!)!.AsObject(); Check(!metadata.ContainsKey("ocrText") && metadata["preserved"]!.GetValue<string>() == "synthetic metadata");
            Check(restored.Payload!.SequenceEqual(bytes.ToArray()) && history.Writable && !history.UnsavedChanges);
            string wal = Path.Combine(folder, "history.sqlite-wal"); Check(!File.Exists(wal) || new FileInfo(wal).Length == 0);
            byte[] archive = await MacHistoryArchive.SealAsync(MacHistoryArchive.Snapshot(history.State), "synthetic forget archive key");
            HistoryItem archived = MacHistoryArchive.Open(archive, "synthetic forget archive key").Items.Single(); Check(archived.OcrText == "" && archived.MacRecords.Count == 0);
            history.ForgetImageUnderstanding(); Check(history.Writable);
        }
        finally { Directory.Delete(folder, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { forget_image_checks = checks, status = "passed", generated_image_only = true }));
    }
}
