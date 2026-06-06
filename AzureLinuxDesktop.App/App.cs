using AzureLinuxDesktop_App;
using Microsoft.UI.Reactor;
using Microsoft.UI.Reactor.Core;
using Microsoft.UI.Reactor.Layout;
using static Microsoft.UI.Reactor.Factories;
using System.Diagnostics;
using System.Text;

/// <summary>
/// Zero-interaction flow: the app opens, ensures the XRDP image exists
/// (building it on first run), launches the wslc container, then the window
/// becomes the XFCE desktop — the RDP surface fills everything below the
/// title bar and signs in automatically. No buttons.
/// </summary>
public sealed class AzureLinuxDesktopApp : Component
{
    private const string SessionName = "azurelinux-desktop-session";
    private const string StoragePath = @"C:\Users\Public\AzureLinuxDesktop\session";
    private const string ImageName = "azurelinux-xfce-xrdp:4.0";
    private const string ContainerName = "azurelinux-xfce-desktop";
    private const string RdpServer = "127.0.0.1";
    private const int RdpPort = 3389;
    // Must match the desktop account baked into container/Dockerfile.
    private const string RdpUser = "deskuser";
    private const string RdpPassword = "ChangeMe123!";

    private readonly WslcDesktopLauncher _launcher = new();
    private readonly StringBuilder _log = new();
    private readonly System.Diagnostics.Stopwatch _bootClock = System.Diagnostics.Stopwatch.StartNew();
    private bool _startupRequested;

    public override Element Render()
    {
        var (status, setStatus) = UseState("Starting...");
        var (log, setLog) = UseState("");
        var (desktopPort, setDesktopPort) = UseState(0);
        var (failed, setFailed) = UseState(false);
        var (surfaceShown, setSurfaceShown) = UseState(false);

        void AppendLog(string text)
        {
            if (string.IsNullOrWhiteSpace(text))
                return;
            _log.AppendLine(text.TrimEnd());
            setLog(_log.ToString());
            Trace($"log: {text.TrimEnd()}");
        }

        async Task StartupAsync()
        {
            try
            {
                if (!_launcher.IsAvailable)
                {
                    setFailed(true);
                    setStatus("wslc SDK is not enabled in this build.");
                    AppendLog("Run scripts\\Build-Wsl.ps1, then rebuild. The project enables the wslc SDK automatically once artifacts\\wslc exists.");
                    return;
                }

                setStatus("Launching the Azure Linux desktop container...");
                var port = await _launcher.StartDesktopAsync(
                    SessionName, StoragePath, ImageName, ContainerName, RdpPort,
                    buildImageIntoSessionAsync: async () =>
                    {
                        setStatus("First run: building the Azure Linux XRDP image (this can take a while)...");
                        // Build into the default wslc store. The CLI cannot
                        // resolve SDK-created sessions by name (--session
                        // fails with ERROR_NOT_FOUND), so the launcher copies
                        // the image into its session afterwards.
                        AppendLog(await RunScriptAsync("Build-AzureLinuxRdpImage.ps1"));
                        setStatus("Launching the Azure Linux desktop container...");
                    },
                    AppendLog);

                setStatus("Connecting...");

                // Connect while the boot page is still on screen (the control
                // is parked off-screen), then jump straight to the desktop.
                var connected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                RdpInterop.BeginSession(
                    AppHost.WindowHandle,
                    AppHost.Dispatcher!,
                    new RdpHostElement(RdpServer, port, RdpUser, RdpPassword, s =>
                    {
                        Trace($"rdp: {s}");
                        if (s == "Connected")
                            connected.TrySetResult();
                    }));

                var winner = await Task.WhenAny(connected.Task, Task.Delay(TimeSpan.FromSeconds(90)));
                if (winner != connected.Task)
                {
                    throw new TimeoutException(
                        $"Timed out waiting for the RDP session. Check the container with: wslc logs --session {SessionName} {ContainerName}");
                }

                // Let the boot spinner complete at least two full cycles.
                const int minimumBootMs = 2 * 1900 + 500;
                var remaining = minimumBootMs - (int)_bootClock.ElapsedMilliseconds;
                if (remaining > 0)
                    await Task.Delay(remaining);

                // Make the spinner's hand-built composition visuals inert
                // BEFORE Reactor unmounts the boot page; tearing them down
                // live crashes the XAML layer (0xc000027b).
                BootPage.StopSpinner();
                await Task.Delay(50);

                setStatus("Connected");
                setDesktopPort(port);
            }
            catch (Exception ex)
            {
                setFailed(true);
                setStatus("Startup failed — see the log below.");
                AppendLog(ex.ToString());
            }
        }

        UseEffect(() =>
        {
            if (_startupRequested)
                return;
            _startupRequested = true;
            _ = StartupAsync();
        }, "startup-once");

        Trace($"render: desktopPort={desktopPort} failed={failed} status='{status}'");

        // Three states: booting (Windows-style boot page), failed (log panel),
        // connected (the window IS the desktop).
        Element body;
        if (failed)
        {
            body = (FlexColumn(
                Heading("Startup failed").Flex(shrink: 0),
                Caption(status).Flex(shrink: 0),
                TextBox(log, _ => { }, header: "Activity Log")
                    .IsReadOnly()
                    .AcceptsReturn()
                    .TextWrapping()
                    .AutomationName("ActivityLog")
                    .Flex(grow: 1)
            ) with { RowGap = 12 }).Flex(grow: 1).Padding(24);
        }
        else if (desktopPort > 0)
        {
            // The boot page stays mounted UNDER the RDP surface until the
            // owned form reports it is actually on screen, so there is no
            // blank gap between the boot page and the desktop.
            async void OnRdpStatus(string s)
            {
                if (s == "SurfaceVisible")
                {
                    // Make the spinner's visuals inert before the boot page
                    // unmounts (live teardown crashes the XAML layer).
                    BootPage.StopSpinner();
                    await Task.Delay(80);
                    setSurfaceShown(true);
                    return;
                }
                setStatus(s);
            }

            body = Grid(new[] { GridSize.Star() }, new[] { GridSize.Star() },
                new RdpHostElement(RdpServer, desktopPort, RdpUser, RdpPassword, OnRdpStatus),
                surfaceShown ? Border(null) : BootPage.Build()
            ).Flex(grow: 1);
        }
        else
        {
            // BootPage paints its own black fill (Windows boot look).
            body = BootPage.Build().Flex(grow: 1);
        }

        return FlexColumn(
            TitleBar("Azure Linux Desktop").Flex(shrink: 0),
            body
        )
        .Backdrop(BackdropKind.Mica)
        .Padding(desktopPort > 0 ? 4 : 0);
    }

    /// <summary>
    /// The repository checkout containing this build, found by walking up
    /// from the exe (works from bin\Debug, bin\Release, and publish folders).
    /// Null when the exe runs outside a checkout.
    /// </summary>
    private static string? FindRepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "scripts", "Build-AzureLinuxRdpImage.ps1")))
                return dir.FullName;
        }
        return null;
    }

    private static readonly string ArtifactsDir = ResolveArtifactsDir();

    private static string ResolveArtifactsDir()
    {
        var root = FindRepoRoot();
        var dir = root is not null
            ? Path.Combine(root, "artifacts")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AzureLinuxDesktop");
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static void Trace(string message)
    {
        try
        {
            var path = Path.Combine(ArtifactsDir, "app-trace.log");
            File.AppendAllText(path, $"{DateTime.Now:HH:mm:ss.fff} {message}{Environment.NewLine}");
        }
        catch { /* tracing only */ }
    }

    private static async Task<string> RunScriptAsync(string scriptName, string? arguments = null)
    {
        var repoRoot = FindRepoRoot();
        if (repoRoot is null)
        {
            return "This build is running outside the repository, so it cannot run the image build script. " +
                   "Build the image from a checkout with scripts\\Build-AzureLinuxRdpImage.ps1 and relaunch.";
        }
        var scriptPath = Path.Combine(repoRoot, "scripts", scriptName);
        if (!File.Exists(scriptPath))
        {
            return $"Script not found: {scriptPath}";
        }

        var info = new ProcessStartInfo("powershell.exe", $"-NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\" {arguments}")
        {
            WorkingDirectory = repoRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = new Process { StartInfo = info };
        process.Start();

        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();

        var output = await stdout;
        var error = await stderr;
        return string.Join(Environment.NewLine, new[] { output, error }.Where(line => !string.IsNullOrWhiteSpace(line)));
    }
}
