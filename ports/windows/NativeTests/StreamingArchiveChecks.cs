using Cliphoard.Windows;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
internal static class StreamingArchiveChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Streaming archive check {checks} failed"); }
        string directory = Path.Combine(Path.GetTempPath(), "CliphoardStreamArchiveFixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        const string phrase = "synthetic streaming archive key";
        try
        {
            string archive = Path.Combine(directory, "large.cliphoard");
            var state = new HistoryState { Limit = 0 };
            for (int index = 0; index < 1001; ++index) state.Items.Add(new() { Text = "Synthetic stream history " + index + " " + new string('a', 61000), Source = "Synthetic fixture", Pinned = index < 31 });
            await MacHistoryArchive.SealFileAsync(state, phrase, archive); Check(new FileInfo(archive).Length > 48L * 1024 * 1024); state.Items.Clear();
            var target = new HistoryStore(Path.Combine(directory, "target")); target.State.Limit = 0;
            using (MacArchiveStage stage = MacHistoryArchive.OpenFile(archive, phrase))
            {
                Check(stage.State.Items.Count == 1001 && stage.State.Items.Count(item => item.Pinned) == 31);
                Check(stage.State.Items[1000].Text.StartsWith("Synthetic stream history 1000 "));
                Check(HistoryStore.NewContentCount(target.State.Items, stage.State.Items) == 1001);
                Check(target.Import(stage.State.Items, false) == 1001);
            }
            Check(new HistoryStore(Path.Combine(directory, "target")).State.Items.Count == 1001);
            using (var file = new FileStream(archive, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                file.Position = file.Length - 1; int last = file.ReadByte(); file.Position -= 1; file.WriteByte((byte)(last ^ 1));
            }
            bool refused = false; try { using var bad = MacHistoryArchive.OpenFile(archive, phrase); } catch (CryptographicException) { refused = true; } Check(refused && target.State.Items.Count == 1001);
            string images = Path.Combine(directory, "images.cliphoard");
            using Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("NativeTests.Fixtures.SyntheticRed.png")!; using var bytes = new MemoryStream(); resource.CopyTo(bytes); byte[] png = bytes.ToArray();
            var imageStore = new HistoryStore(Path.Combine(directory, "image-source")); imageStore.Add(new() { Kind = "Image", Format = 0, Text = "Synthetic image", Payload = png });
            HistoryState snapshot = MacHistoryArchive.Snapshot(imageStore.State); Check(snapshot.Items.Single().PayloadLoader is not null && snapshot.Items.Single().Payload!.SequenceEqual(png));
            await MacHistoryArchive.SealFileAsync(snapshot, phrase, images);
            var imageTarget = new HistoryStore(Path.Combine(directory, "image-target"));
            using (MacArchiveStage stage = MacHistoryArchive.OpenFile(images, phrase))
            {
                HistoryItem item = stage.State.Items.Single(); Check(item.PayloadLoader is not null && item.Payload!.SequenceEqual(png));
                Check(imageTarget.Import(stage.State.Items, false) == 1);
            }
            Check(imageTarget.State.Items.Single().Payload!.SequenceEqual(png));
            string cancelledPath = Path.Combine(directory, "cancelled.cliphoard"); using var cancel = new CancellationTokenSource(); cancel.Cancel();
            refused = false; try { await MacHistoryArchive.SealFileAsync(snapshot, phrase, cancelledPath, cancel.Token); } catch (OperationCanceledException) { refused = true; }
            Check(refused && !File.Exists(cancelledPath) && Directory.GetFiles(directory, "*.tmp").Length == 0);
            string rejectedPublish = Path.Combine(directory, "rejected.cliphoard"); refused = false;
            try { await MacHistoryArchive.SealFileAsync(snapshot, phrase, rejectedPublish, publish: _ => throw new OperationCanceledException()); } catch (OperationCanceledException) { refused = true; }
            Check(refused && !File.Exists(rejectedPublish) && Directory.GetFiles(directory, "*.tmp").Length == 0);
        }
        finally { Directory.Delete(directory, true); }
        Console.WriteLine(JsonSerializer.Serialize(new { streaming_archive_checks = checks, status = "passed", synthetic_large_history_only = true }));
    }
}
