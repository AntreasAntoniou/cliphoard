using Cliphoard.Windows;

internal static class DocumentWorker
{
    internal static async Task<int> RunAsync()
    {
        using var input = Console.OpenStandardInput();
        using var output = Console.OpenStandardOutput();
        try
        {
            DocumentRequest request = await ModelWorkerProtocol.ReadAsync<DocumentRequest>(input, CancellationToken.None, DocumentProtocol.MaximumFrame);
            DocumentResponse response;
            try { response = DocumentExtraction.Extract(request, CancellationToken.None); }
            catch { response = new(false); }
            await ModelWorkerProtocol.WriteAsync(output, response, CancellationToken.None, DocumentProtocol.MaximumFrame);
            return 0;
        }
        catch { return 1; }
    }
}
