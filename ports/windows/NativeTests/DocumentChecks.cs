using Cliphoard.Windows;
using System.Text;
using System.Text.Json;

internal static class DocumentChecks
{
    internal static async Task RunAsync()
    {
        int checks = 0;
        void Check(bool value) { ++checks; if (!value) throw new Exception($"Document check {checks} failed"); }
        byte[] Bytes(string value) => Encoding.ASCII.GetBytes(value);
        Check(RtfText.Read(Bytes(@"{\rtf1 hello\par world}"), 100, default) == "hello\nworld");
        Check(RtfText.Read(Bytes(@"{\rtf1\ansi\ansicpg1252 caf\'e9 \u945?}"), 100, default) == "café α");
        Check(RtfText.Read(Bytes(@"{\rtf1 visible{\object hidden}{\*\unknown private} end}"), 100, default) == "visible end");
        Check(RtfText.Read(Bytes(@"{\rtf1 one {\b two} three}"), 100, default) == "one two three");
        try { RtfText.Read(Bytes(@"{\rtf1 incomplete"), 100, default); Check(false); } catch (IOException) { Check(true); }
        try { RtfText.Read(Bytes(@"{\rtf1\bin9999 a}"), 100, default); Check(false); } catch (IOException) { Check(true); }
        Check(RtfText.Read(Bytes(@"{\rtf1 abcdef}"), 3, default) == "abc");
        Check(RtfText.Read(Bytes(@"{\rtf1\ansi\ansicpg65001 caf\'c3\'a9 \u945?}"), 100, default) == "café α");
        Check(RtfText.Read(Bytes(@"{\rtf1\ansi\ansicpg932 \'82\'a0}"), 100, default) == "あ");
        Check(RtfText.Read(Bytes(@"{\rtf1 \u-10179?\u-8704?}"), 100, default) == "😀");
        Check(RtfText.Read(Bytes(@"{\rtf1 a\u-10179?\u-8704?}"), 2, default) == "a");
        Check(DocumentWorkerClient.Format("source.cs", true, true) == "text");
        Check(DocumentWorkerClient.Format("document.pdf", false, true) is null);
        Check(DocumentWorkerClient.Format("program.exe", true, true) is null);
        async Task<DocumentResponse> Extract(string format, byte[] bytes) => await DocumentWorkerClient.ExtractBytesAsync(new(format, bytes), default);
        Check((await Extract("text", Encoding.UTF8.GetBytes("synthetic résumé"))).Text == "synthetic résumé");
        Check((await Extract("text", Encoding.Unicode.GetPreamble().Concat(Encoding.Unicode.GetBytes("synthetic UTF16")).ToArray())).Text == "synthetic UTF16");
        Check((await Extract("rtf", Bytes(@"{\rtf1 synthetic\tab document}"))).Text == "synthetic\tdocument");
        // A minimal synthetic PDF uses only an embedded page and standard font.
        string pdf = "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >> endobj\n4 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n";
        string content = "BT /F1 12 Tf 72 720 Td (Synthetic PDF fixture) Tj ET";
        pdf += $"5 0 obj << /Length {content.Length} >> stream\n{content}\nendstream endobj\ntrailer << /Root 1 0 R /Size 6 >>\n%%EOF";
        Check((await Extract("pdf", Bytes(pdf))).Text.Contains("Synthetic PDF fixture"));
        DocumentResponse bounded = await Extract("text", Bytes(new string('a', 200001)));
        Check(bounded.Truncated && bounded.Text.Length == 200000);
        try { await Extract("text", new byte[] { 0, 1, 2 }); Check(false); } catch (IOException) { Check(true); }
        try { await Extract("pdf", Bytes("invalid PDF")); Check(false); } catch (IOException) { Check(true); }
        using (var cancelled = new CancellationTokenSource())
        {
            cancelled.Cancel();
            try { await DocumentWorkerClient.ExtractBytesAsync(new("text", Bytes("cancel")), cancelled.Token); Check(false); } catch (OperationCanceledException) { Check(true); }
        }
        string folder = Path.Combine(Path.GetTempPath(), "CliphoardDocumentFixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            string path = Path.Combine(folder, "synthetic.txt");
            await File.WriteAllTextAsync(path, "local synthetic snapshot");
            Check((await DocumentWorkerClient.ExtractAsync(path, true, true, default)).Text == "local synthetic snapshot");
            var history = new HistoryStore(folder);
            byte[] paths = Encoding.Unicode.GetBytes(path + "\0\0");
            byte[] drop = new byte[20 + paths.Length]; BitConverter.GetBytes(20).CopyTo(drop, 0); BitConverter.GetBytes(1).CopyTo(drop, 16); paths.CopyTo(drop, 20);
            history.Add(new HistoryItem { Text = path, Kind = "Files", Format = 15, Payload = drop, DocumentText = "synthetic snapshot", DocumentTruncated = true });
            var reloaded = new HistoryStore(folder);
            Check(reloaded.State.Items.Single().DocumentText == "synthetic snapshot" && reloaded.State.Items.Single().DocumentTruncated);
        }
        finally { Directory.Delete(folder, true); }
        using var frame = new MemoryStream();
        try { await ModelWorkerProtocol.WriteAsync(frame, new { Value = "large" }, default, 2); Check(false); } catch (IOException) { Check(frame.Length == 0); }
        Console.WriteLine(JsonSerializer.Serialize(new { document_checks = checks, status = "passed" }));
    }
}
