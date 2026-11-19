using Microsoft.UI.Xaml;
namespace Cliphoard.Windows;

public partial class App : Application
{
    private Window? window;
    private Mutex? singleton;
    private EventWaitHandle? reopen;
    private RegisteredWaitHandle? reopenWait;
    public App() { InitializeComponent(); }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        bool syntheticProfile = false;
#if DEBUG
        string? brandPreviewTheme = null;
#endif
        string[] options = Environment.GetCommandLineArgs().Skip(1).ToArray();
#if DEBUG
        if (options.SequenceEqual(new[] { "--synthetic-brand-preview-light" }) || options.SequenceEqual(new[] { "--synthetic-brand-preview-dark" }))
        {
            brandPreviewTheme = options[0].EndsWith("-dark", StringComparison.Ordinal) ? "oneDark" : "swiss";
            syntheticProfile = true; options = Array.Empty<string>();
        }
        if (options.SequenceEqual(new[] { "--synthetic-history-profile" })) { syntheticProfile = true; options = Array.Empty<string>(); }
        if (options.SequenceEqual(new[] { "--synthetic-fixture" }))
        {
            var fixture = new MainWindow(); window = fixture; fixture.Activate(); fixture.InitializeFixture(); return;
        }
#endif
        if (options.SequenceEqual(new[] { "--agent-writer" }) || options.SequenceEqual(new[] { "--agent-export-reader" }))
        {
            if (!Console.IsInputRedirected || !Console.IsOutputRedirected) { Environment.Exit(78); return; }
            var broker = new AgentBrokerWindow(options[0] == "--agent-writer"); window = broker; broker.Activate(); return;
        }
        if (options.SequenceEqual(new[] { "--cleanup-startup" })) { DesktopStartup.SetEnabled(false); Environment.Exit(0); return; }
        bool background = options.SequenceEqual(new[] { "--background" });
        if (options.Length != 0 && !background) { Environment.Exit(78); return; }
        // .NET applies a current-user, current-session boundary to both named objects.
        var scope = new NamedWaitHandleOptions { CurrentUserOnly = true, CurrentSessionOnly = true };
        singleton = new Mutex(false, "Cliphoard.Desktop", scope, out bool created);
        reopen = new EventWaitHandle(false, EventResetMode.AutoReset, "Cliphoard.Reopen", scope, out _);
        if (!created) { if (!background) reopen.Set(); Environment.Exit(0); return; }
        HistoryStore? history = null;
#if DEBUG
        if (syntheticProfile)
        {
            const string fixtureDirectory = @"C:\CliphoardDev\qualification\interactive-profile";
            string marker = Path.Combine(fixtureDirectory, ".synthetic-only");
            VerifiedModelAssets.CheckPath(marker);
            if (!File.Exists(marker) || File.ReadAllText(marker) != "CLIPHOARD_SYNTHETIC_V1") { Environment.Exit(78); return; }
            history = new HistoryStore(fixtureDirectory);
            if (brandPreviewTheme is not null)
            {
                history.State.Theme = brandPreviewTheme;
                history.State.Paused = true;
                history.State.SearchMode = "exact";
            }
        }
#else
        _ = syntheticProfile;
#endif
        var normal = new HistoryWindow(history); window = normal;
        reopenWait = ThreadPool.RegisterWaitForSingleObject(reopen, (_, _) => normal.DispatcherQueue.TryEnqueue(normal.ShowPanel), null, Timeout.Infinite, false);
        normal.Closed += (_, _) => { reopenWait?.Unregister(null); reopen.Dispose(); singleton.Dispose(); };
        if (!background) normal.Activate(); normal.Initialize(background);
#if DEBUG
        if (brandPreviewTheme is not null)
        {
            var previewLifetime = new DispatcherTimer { Interval = TimeSpan.FromSeconds(20) };
            previewLifetime.Tick += (_, _) => { previewLifetime.Stop(); normal.Close(); };
            normal.Closed += (_, _) => previewLifetime.Stop();
            previewLifetime.Start();
        }
#endif
    }
}
