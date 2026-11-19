using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text;
using System.Text.Json;
using Windows.Storage.Pickers;
using static Cliphoard.Windows.DesktopVisual;
namespace Cliphoard.Windows;

/// Native chooser and consent surfaces for the separately launched stdio companion.
internal sealed class AgentBrokerWindow : Window
{
    private readonly Grid root = new() { Padding = new Thickness(28) };
    private readonly CancellationTokenSource lifetime = new();
    private readonly Stream output = Console.OpenStandardOutput();
    private readonly bool writer;
    private bool began;
    internal AgentBrokerWindow(bool writer)
    {
        this.writer = writer; Title = writer ? "Connect Cliphoard agent saves" : "Share a Cliphoard export";
        var theme = DesktopThemes.Resolve("system", false); root.Background = Brush(theme.Bar); root.RequestedTheme = ElementTheme.Light;
        var body = new StackPanel { Spacing = 16 };
        body.Children.Add(Text(Title, theme, 22));
        body.Children.Add(Text(writer ? "Enable an agent connection in Cliphoard Settings, then choose that connection’s private folder. Cliphoard applies the permission you selected."
            : "Choose an encrypted export. Eligible text clips tagged agent-share can be sent to the connected agent’s model provider for 15 minutes.", theme, 14));
        root.Children.Add(body); Content = root; DesktopVisual.FitWindow(this, 600, 340);
        root.Loaded += async (_, _) => { if (began) return; began = true; await RunAsync(); };
        Closed += (_, _) => lifetime.Cancel();
    }
    private async Task EmitAsync(object value)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        await output.WriteAsync(bytes); await output.WriteAsync(new byte[] { 10 }); await output.FlushAsync();
    }
    private async Task RunAsync()
    {
        try { if (writer) await WriterAsync(); else await ReaderAsync(); }
        catch (OperationCanceledException) { }
        catch { await EmitAsync(new { status = "unavailable" }); }
        finally { await output.DisposeAsync(); Close(); }
    }
    private async Task WriterAsync()
    {
        var picker = new FolderPicker(); picker.FileTypeFilter.Add("*"); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync(); if (folder is null) { await EmitAsync(new { status = "cancelled" }); return; }
        using var connection = new AgentWriterConnection(folder.Path);
        await EmitAsync(new { status = "ready", session_id = connection.Session.SessionId.ToLowerInvariant(), expires_at = connection.Session.ExpiresAt, lifetime = connection.Session.Lifetime ?? "bounded" });
        AppWindow.Hide();
        using Stream input = Console.OpenStandardInput(); await using var lines = new BoundedCommandLines(input);
        while (await lines.NextAsync(connection.Validate, lifetime.Token) is byte[] bytes)
        {
            try
            {
                using var json = JsonDocument.Parse(bytes); JsonElement command = json.RootElement;
                if (command.ValueKind != JsonValueKind.Object) throw new IOException();
                JsonProperty[] properties = command.EnumerateObject().ToArray();
                if (properties.Select(property => property.Name).Distinct(StringComparer.Ordinal).Count() != properties.Length) throw new IOException();
                string action = command.GetProperty("action").GetString() ?? "";
                if (action == "disconnect" && properties.Length == 1) { await EmitAsync(new { status = "disconnected" }); return; }
                string raw = command.GetProperty("request_id").GetString() ?? "";
                if (!Guid.TryParseExact(raw, "D", out Guid id) || id.ToString("D") != raw) throw new IOException();
                object result = action switch
                {
                    "write" when properties.Length == 3 && command.TryGetProperty("text", out JsonElement text) => connection.Write(id, text.GetString() ?? ""),
                    "check" when properties.Length == 2 => connection.Check(id),
                    _ => throw new IOException()
                };
                await EmitAsync(result);
            }
            catch { await EmitAsync(new { status = "unknown" }); }
            finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); }
        }
    }
    private async Task ReaderAsync()
    {
        var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(".cliphoard"); picker.FileTypeFilter.Add(".cliphoard-win"); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync(); if (file is null) { Environment.ExitCode = 1; return; }
        var password = new PasswordBox { Header = "Export passphrase", MaxLength = 1024, PasswordRevealMode = PasswordRevealMode.Hidden };
        var content = new StackPanel { Spacing = 12 }; content.Children.Add(new TextBlock { Text = "Eligible clips tagged agent-share will be available to this MCP client for 15 minutes. The client may send them to its model provider.", TextWrapping = TextWrapping.Wrap }); content.Children.Add(password);
        var consent = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Unlock this export for agent search?", Content = content, PrimaryButtonText = "Share tagged clips", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        try
        {
            if (await consent.ShowAsync() != ContentDialogResult.Primary) { Environment.ExitCode = 1; return; }
            string phrase = password.Password; password.Password = "";
            SharedAgentClip[] shared = await Task.Run(() =>
            {
                using var input = LocalFileLease.Open(file.Path, long.MaxValue); byte[] magic = new byte[8]; input.ReadExactly(magic);
                if (magic.AsSpan().SequenceEqual("CLIPHRD1"u8))
                {
                    input.Position = 0; using MacArchiveStage stage = MacHistoryArchive.OpenStaged(input, phrase, lifetime.Token); return SharedAgentClips.Select(stage.State);
                }
                byte[] bytes = PortableHistory.ReadBounded(file.Path);
                return SharedAgentClips.Select(PortableHistory.Open(bytes, phrase));
            }, lifetime.Token);
            lifetime.Token.ThrowIfCancellationRequested(); await EmitAsync(shared);
        }
        finally { password.Password = ""; }
    }
}
