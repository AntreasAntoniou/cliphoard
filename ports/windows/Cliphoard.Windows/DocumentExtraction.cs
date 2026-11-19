using System.Text;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace Cliphoard.Windows;

internal static class DocumentExtraction
{
    internal const int MaximumBytes = 16 * 1024 * 1024, MaximumCharacters = 200000, MaximumPages = 100;
    internal static DocumentResponse Extract(DocumentRequest request, CancellationToken cancellation)
    {
        if (request.Bytes.Length > MaximumBytes) throw new IOException("Document exceeds the extraction limit.");
        string text;
        bool truncated = false;
        switch (request.Format)
        {
            case "pdf" when request.Pdf:
                using (PdfDocument document = PdfDocument.Open(request.Bytes))
                {
                    var output = new StringBuilder();
                    truncated = document.NumberOfPages > MaximumPages;
                    for (int page = 1; page <= Math.Min(document.NumberOfPages, MaximumPages); ++page)
                    {
                        cancellation.ThrowIfCancellationRequested();
                        output.AppendLine(ContentOrderTextExtractor.GetText(document.GetPage(page)));
                        if (output.Length >= MaximumCharacters) { truncated = true; break; }
                    }
                    text = output.ToString();
                }
                break;
            case "rtf" when request.RichText:
                text = RtfText.Read(request.Bytes, MaximumCharacters + 1, cancellation);
                break;
            case "text":
                bool little = request.Bytes.AsSpan().StartsWith(new byte[] { 0xff, 0xfe });
                bool big = request.Bytes.AsSpan().StartsWith(new byte[] { 0xfe, 0xff });
                Encoding encoding = little || big ? new UnicodeEncoding(big, false, true) : new UTF8Encoding(false, true);
                text = encoding.GetString(request.Bytes).TrimStart('\ufeff');
                if (text.Contains('\0')) throw new IOException("Binary data is excluded from document text.");
                break;
            default: throw new IOException("Unsupported document format.");
        }
        cancellation.ThrowIfCancellationRequested();
        if (text.Length > MaximumCharacters)
        {
            int limit = char.IsHighSurrogate(text[MaximumCharacters - 1]) ? MaximumCharacters - 1 : MaximumCharacters;
            text = text[..limit]; truncated = true;
        }
        return new(true, text, truncated);
    }
}
