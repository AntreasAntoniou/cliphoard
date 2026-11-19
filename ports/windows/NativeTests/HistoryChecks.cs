using Cliphoard.Windows;
using Microsoft.Data.Sqlite;
using System.Text;
using System.Text.Json;
internal static class HistoryChecks
{
    internal static void Run()
    {
        int checks = 0;
        void Check(bool condition) { ++checks; if (!condition) throw new Exception($"History check {checks} failed"); }
        string dir = Path.Combine(Path.GetTempPath(), "Cliphoard-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var history = new HistoryStore(dir); Check(history.Writable);
            string generated = "[CLIPHOARD_SYNTHETIC_V1] encrypted history " + Guid.NewGuid();
            history.Add(new() { Text = generated, Pinned = true });
            string id = history.State.Items[0].Id;
            history.Add(new() { Text = generated }); Check(history.State.Items.Count == 1 && history.State.Items[0].Pinned && history.State.Items[0].Id == id);
            history.State.Limit = 50;
            for (int i = 0; i < 55; ++i) history.Add(new() { Text = "[CLIPHOARD_SYNTHETIC_V1] generated note " + i });
            Check(history.State.Items.Count == 51 && history.State.Items.Any(i => i.Id == id));
            byte[] encrypted = File.ReadAllBytes(Path.Combine(dir, "history.sqlite"));
            Check(!Encoding.UTF8.GetString(encrypted).Contains(generated) && !Encoding.Unicode.GetString(encrypted).Contains(generated));
            var restored = new HistoryStore(dir); Check(restored.Writable && restored.State.Items.Count == 51 && restored.State.Items.Any(i => i.Text == generated && i.Pinned));
            restored.State.Items.RemoveAll(i => !i.Pinned); restored.Save(); Check(new HistoryStore(dir).State.Items.Count == 1);
            using (var connection = new SqliteConnection($"Data Source={Path.Combine(dir, "history.sqlite")};Pooling=False"))
            {
                connection.Open(); using var command = connection.CreateCommand(); command.CommandText = "SELECT metadata FROM clips LIMIT 1";
                byte[] corrupt = (byte[])command.ExecuteScalar()!; corrupt[^1] ^= 0xff;
                command.CommandText = "UPDATE clips SET metadata=$body"; command.Parameters.AddWithValue("$body", corrupt); command.ExecuteNonQuery();
            }
            byte[] bad = File.ReadAllBytes(Path.Combine(dir, "history.sqlite"));
            var damaged = new HistoryStore(dir); Check(!damaged.Writable && damaged.State.Items.Count == 0);
            damaged.Add(new() { Text = "[CLIPHOARD_SYNTHETIC_V1] memory only" }); Check(File.ReadAllBytes(Path.Combine(dir, "history.sqlite")).SequenceEqual(bad));
            byte[] dib = new byte[56]; BitConverter.GetBytes(40).CopyTo(dib, 0); BitConverter.GetBytes(2).CopyTo(dib, 4); BitConverter.GetBytes(2).CopyTo(dib, 8); BitConverter.GetBytes((ushort)1).CopyTo(dib, 12); BitConverter.GetBytes((ushort)32).CopyTo(dib, 14);
            Check(HistoryClipboard.ValidDib(dib)); Check(!HistoryClipboard.ValidDib(dib[..55]));
            BitConverter.GetBytes(int.MinValue).CopyTo(dib, 8); Check(!HistoryClipboard.ValidDib(dib));
            using var owner = new Form(); var clipboard = new HistoryClipboard(owner.Handle);
            Clipboard.SetText("[CLIPHOARD_SYNTHETIC_V1] capture check");
            var captured = clipboard.ReadUpdate(); Check(captured?.Text == "[CLIPHOARD_SYNTHETIC_V1] capture check");
            Check(clipboard.ReadUpdate() is null); Check(clipboard.Write(captured!, true)); Check(clipboard.ReadUpdate() is null);
            var excluded = new DataObject(); excluded.SetData(DataFormats.UnicodeText, "[CLIPHOARD_SYNTHETIC_V1] excluded"); excluded.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[] { 1 })); Clipboard.SetDataObject(excluded, true);
            Check(clipboard.ReadUpdate() is null);
            var privacy = new DataObject(); privacy.SetData(DataFormats.UnicodeText, "[CLIPHOARD_SYNTHETIC_V1] private"); privacy.SetData("CanIncludeInClipboardHistory", new MemoryStream(new byte[4])); Clipboard.SetDataObject(privacy, true); Check(clipboard.ReadUpdate() is null);
            Clipboard.SetText("[CLIPHOARD_SYNTHETIC_V1] existing before adapter");
            var baseline = new HistoryClipboard(owner.Handle); Check(baseline.ReadUpdate() is null);
            using (var image = new Bitmap(32, 24)) { using var graphics = Graphics.FromImage(image); graphics.Clear(Color.MediumSlateBlue); Clipboard.SetImage(image); }
            var media = clipboard.ReadUpdate(); Check(media is { Kind: "Image", Payload: not null });
            Check(clipboard.Write(media!, false)); using (var restoredImage = Clipboard.GetImage()) Check(restoredImage?.Width == 32 && restoredImage.Height == 24);
            var names = new System.Collections.Specialized.StringCollection { @"C:\CliphoardDev\synthetic-only-one.txt", @"C:\CliphoardDev\synthetic-only-two.txt" };
            Clipboard.SetFileDropList(names); var files = clipboard.ReadUpdate(); Check(files is { Kind: "Files", Format: 15 } && files.Text.Contains("synthetic-only-two.txt"));
            Check(clipboard.Write(files!, false)); Check(Clipboard.GetFileDropList().Cast<string>().SequenceEqual(names.Cast<string>()));
            var rich = new DataObject(); rich.SetData(DataFormats.UnicodeText, "[CLIPHOARD_SYNTHETIC_V1] rich text"); rich.SetData(DataFormats.Rtf, "{\\rtf1 [CLIPHOARD_SYNTHETIC_V1] \\b rich text}"); Clipboard.SetDataObject(rich, true);
            var formatted = clipboard.ReadUpdate(); Check(formatted?.RichText is { Length: > 0 }); Check(clipboard.Write(formatted!, false)); Check(Clipboard.ContainsText(TextDataFormat.Rtf));
            Check(clipboard.Write(formatted!, true)); Check(!Clipboard.ContainsText(TextDataFormat.Rtf) && Clipboard.GetText() == formatted!.Text);
            Console.WriteLine(JsonSerializer.Serialize(new { history_checks = checks, status = "passed", data = "generated synthetic only" }));
        }
        finally { Directory.Delete(dir, true); }
    }
}
internal sealed class NormalEditor : Form
{
    private readonly RichTextBox editor = new() { Dock = DockStyle.Fill, Font = new Font("Segoe UI", 16) };
    internal NormalEditor()
    {
        Text = "Cliphoard · synthetic usability editor"; Width = 1050; Height = 550; StartPosition = FormStartPosition.CenterScreen;
        var controls = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 140, AutoSize = false };
        void Add(string title, Action action) { var b = new Button { Text = title, Width = 160, Height = 36 }; b.Click += (_, _) => { action(); editor.Focus(); }; controls.Controls.Add(b); }
        Add("Copy meeting note", () => Clipboard.SetText("[CLIPHOARD_SYNTHETIC_V1] Product meeting\r\nShip a clipboard manager that feels native.\r\nSearch, choose a card, and keep writing."));
        Add("Copy link", () => Clipboard.SetText("https://example.com/cliphoard-synthetic"));
        Add("Copy code", () => Clipboard.SetText("// CLIPHOARD_SYNTHETIC_V1\r\nconst clipboard = {\r\n  local: true,\r\n  encrypted: true\r\n};"));
        Add("Copy image", () => { using var bitmap = new Bitmap(480, 280); using var g = Graphics.FromImage(bitmap); g.Clear(Color.MediumSlateBlue); using var font = new Font("Segoe UI", 28); g.DrawString("Synthetic image", font, Brushes.White, 30, 90); Clipboard.SetImage(bitmap); });
        Add("Copy meal note", () => Clipboard.SetText("[CLIPHOARD_SYNTHETIC_V1] The restaurant serves delicious meals."));
        Add("Copy OCR image", () => { using var bitmap = new Bitmap(1000, 200); using var graphics = Graphics.FromImage(bitmap); using var font = new Font("Arial", 42); graphics.Clear(Color.White); graphics.DrawString("SYNTHETIC CLIPBOARD 2026", font, Brushes.Black, 24, 45); Clipboard.SetImage(bitmap); });
        Add("Copy red picture", () => { using var bitmap = new Bitmap(224, 224); using var graphics = Graphics.FromImage(bitmap); graphics.Clear(Color.Red); Clipboard.SetImage(bitmap); });
        Add("Copy blue picture", () => { using var bitmap = new Bitmap(224, 224); using var graphics = Graphics.FromImage(bitmap); graphics.Clear(Color.Blue); Clipboard.SetImage(bitmap); });
        Add("Copy speech file", () =>
        {
            string path = @"C:\CliphoardDev\evidence\SyntheticSpeech.wav";
            using var source = typeof(NormalEditor).Assembly.GetManifestResourceStream("NativeTests.Fixtures.SyntheticSpeech.wav") ?? throw new IOException("Synthetic audio is missing.");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            using (var output = File.Create(path)) source.CopyTo(output);
            Clipboard.SetFileDropList(new System.Collections.Specialized.StringCollection { path });
        });
        Add("Clear editor", () => editor.Clear()); Controls.Add(editor); Controls.Add(controls);
        Add("Copy PNG picture", () =>
        {
            using var bitmap = new Bitmap(224, 224);
            using (var graphics = Graphics.FromImage(bitmap)) graphics.Clear(Color.Red);
            using var png = new MemoryStream(); bitmap.Save(png, System.Drawing.Imaging.ImageFormat.Png);
            var image = new DataObject(); image.SetData("PNG", new MemoryStream(png.ToArray()));
            Clipboard.SetDataObject(image, true);
        });
        Add("Copy rich note", () =>
        {
            const string text = "[CLIPHOARD_SYNTHETIC_V1] Rich note";
            var rich = new DataObject(); rich.SetData(DataFormats.UnicodeText, text);
            rich.SetData("Rich Text Format", new MemoryStream(System.Text.Encoding.ASCII.GetBytes(@"{\rtf1\ansi [CLIPHOARD_SYNTHETIC_V1] \b Rich note\b0}")));
            rich.SetData("HTML Format", new MemoryStream(FeatureChecks.MakeHtml("<p>[CLIPHOARD_SYNTHETIC_V1] <strong>Rich note</strong></p>")));
            Clipboard.SetDataObject(rich, true);
        });
        Add("Copy document file", () => Clipboard.SetFileDropList(new System.Collections.Specialized.StringCollection { @"C:\CliphoardDev\qualification\interactive-profile\fixtures\synthetic.txt" }));
        editor.TextChanged += (_, _) =>
        {
            // This fixture is only ever fed generated values; never reads clipboard contents.
            Directory.CreateDirectory(@"C:\CliphoardDev\evidence");
            File.WriteAllText(@"C:\CliphoardDev\evidence\normal-editor.json", JsonSerializer.Serialize(new
            {
                length = editor.TextLength,
                syntheticMeetingPasted = editor.Text.Contains("[CLIPHOARD_SYNTHETIC_V1] Product meeting"),
                syntheticLinkPasted = editor.Text.Contains("https://example.com/cliphoard-synthetic"),
                syntheticRichPasted = editor.Text.Contains("[CLIPHOARD_SYNTHETIC_V1] Rich note"),
                richFormatting = editor.Rtf?.Contains(@"\b ") == true
            }));
        };
        Shown += (_, _) => editor.Focus();
    }
}
