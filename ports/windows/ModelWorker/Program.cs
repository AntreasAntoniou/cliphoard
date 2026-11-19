using Cliphoard.Windows;
using System.Text;

if (args.SequenceEqual(new[] { "--media-worker" }) && Console.IsInputRedirected && Console.IsOutputRedirected) return await MediaDecodeWorker.RunAsync();
if (args.SequenceEqual(new[] { "--manager-import-worker" }) && Console.IsInputRedirected && Console.IsOutputRedirected) return await ManagerImportWorker.RunAsync();
if (args.SequenceEqual(new[] { "--document-worker" }) && Console.IsInputRedirected && Console.IsOutputRedirected) return await DocumentWorker.RunAsync();
if (!args.SequenceEqual(new[] { "--private-worker" }) || !Console.IsInputRedirected || !Console.IsOutputRedirected) return 78;
GemmaNativeModel? model = null;
using var input = Console.OpenStandardInput();
using var output = Console.OpenStandardOutput();
try
{
    while (true)
    {
        ModelRequest request = await ModelWorkerProtocol.ReadAsync<ModelRequest>(input, CancellationToken.None);
        if (request.Operation == "close") break;
        ModelResponse response;
        try
        {
            if (request.Operation == "prepare") { model ??= new GemmaNativeModel(); response = new(true); }
            else if (model is not null && request.Operation is "query" or "document" or "image" or "audio" && Encoding.UTF8.GetByteCount(request.Text) <= 1024)
            {
                if (request.Operation == "image" && request.Image is null || request.Operation == "audio" && request.Audio is null || request.Operation is "query" or "document" && (request.Image is not null || request.Audio is not null)) throw new IOException("Invalid model request.");
                response = new(true, model.Embed(request.Text, request.Operation == "query", request.Image, request.Audio));
            }
            else response = new(false);
        }
        catch { response = new(false); }
        await ModelWorkerProtocol.WriteAsync(output, response, CancellationToken.None);
    }
}
catch (EndOfStreamException) { }
catch { return 1; }
finally { model?.Dispose(); }
return 0;
