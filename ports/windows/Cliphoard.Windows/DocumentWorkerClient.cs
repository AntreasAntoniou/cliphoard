using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Cliphoard.Windows;

internal static class DocumentWorkerClient
{
    internal const int MaximumBytes = 16 * 1024 * 1024;
    private static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".txt", ".md", ".markdown", ".csv", ".tsv", ".json", ".xml", ".html", ".htm", ".css", ".js", ".jsx", ".ts", ".tsx", ".swift", ".py", ".cs", ".c", ".h", ".cpp", ".hpp", ".java", ".kt", ".go", ".rs", ".rb", ".sh", ".sql", ".yaml", ".yml", ".toml", ".ini", ".log", ".tex"
    };
    internal static string? Format(string path, bool pdf, bool richText)
    {
        string extension = Path.GetExtension(path);
        if (extension.Equals(".pdf", StringComparison.OrdinalIgnoreCase)) return pdf ? "pdf" : null;
        if (extension.Equals(".rtf", StringComparison.OrdinalIgnoreCase)) return richText ? "rtf" : null;
        return TextExtensions.Contains(extension) ? "text" : null;
    }
    internal static async Task<DocumentResponse> ExtractAsync(string path, bool pdf, bool richText, CancellationToken cancellation)
    {
        string? format = Format(path, pdf, richText);
        if (format is null || !Path.IsPathFullyQualified(path) || path.Length < 3 || path[1] != ':' || new DriveInfo(Path.GetPathRoot(path)!).DriveType == DriveType.Network)
            throw new IOException("Select a supported local document.");
        using var file = LocalFileLease.Open(path, MaximumBytes);
        byte[] bytes = new byte[checked((int)file.Length)];
        try
        {
            await file.ReadExactlyAsync(bytes, cancellation);
            return await ExtractBytesAsync(new(format, bytes, pdf, richText), cancellation);
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    internal static async Task<DocumentResponse> ExtractBytesAsync(DocumentRequest request, CancellationToken cancellation)
    {
        if (request.Bytes.Length > MaximumBytes) throw new IOException("Document exceeds the extraction limit.");
        DocumentResponse response = await PrivateWorkerCall.SendAsync<DocumentRequest, DocumentResponse>("--document-worker", request, DocumentProtocol.MaximumFrame, 30, 512u * 1024 * 1024, cancellation);
        if (!response.Success || response.Text.Length > 200000) throw new IOException("Document could not be extracted safely.");
        return response;
    }
}
