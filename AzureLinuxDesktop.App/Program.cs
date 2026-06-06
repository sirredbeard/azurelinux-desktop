using AzureLinuxDesktop_App;
using Microsoft.Extensions.Logging;
using Microsoft.UI.Reactor;

// Reactor reports render-phase exceptions through AppLogger. Without a sink
// they vanish, so write them to the repo's artifacts\app.log (found by
// walking up from the exe, so Debug, Release, and publish builds all agree),
// or LocalAppData when the exe runs outside a checkout.
static string ResolveLogPath()
{
    for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
    {
        if (File.Exists(Path.Combine(dir.FullName, "scripts", "Build-AzureLinuxRdpImage.ps1")))
            return Path.Combine(dir.FullName, "artifacts", "app.log");
    }
    return Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "AzureLinuxDesktop", "app.log");
}
var logPath = ResolveLogPath();
Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
ReactorApp.AppLogger = new FileLogger(logPath);

ReactorApp.Run<AzureLinuxDesktopApp>("Azure Linux Desktop", width: 1280, height: 900,
    configure: host =>
    {
        RdpInterop.Register(host.Reconciler);
        // Azure Linux logo in the title bar and taskbar. The icon embedded in
        // the exe does not drive the running window's taskbar icon.
        host.Window.AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        // Stashed for the early RDP connect that runs while the boot page is
        // still on screen (no placeholder element exists yet at that point).
        AppHost.WindowHandle = WinRT.Interop.WindowNative.GetWindowHandle(host.Window);
        AppHost.Dispatcher = host.Window.DispatcherQueue;

        // Run() sizes the window in DIPs, which can overflow a scaled
        // display. Clamp to the work area and center.
        var appWindow = host.Window.AppWindow;
        var workArea = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(
            appWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Nearest).WorkArea;
        var width = Math.Min(appWindow.Size.Width, workArea.Width - 48);
        var height = Math.Min(appWindow.Size.Height, workArea.Height - 48);
        if (width != appWindow.Size.Width || height != appWindow.Size.Height)
            appWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
        appWindow.Move(new Windows.Graphics.PointInt32(
            workArea.X + (workArea.Width - width) / 2,
            workArea.Y + (workArea.Height - height) / 2));
    });

internal sealed class FileLogger(string path) : ILogger
{
    private readonly object _lock = new();

    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

    public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel))
            return;
        lock (_lock)
        {
            File.AppendAllText(path, $"{DateTime.Now:HH:mm:ss.fff} [{logLevel}] {formatter(state, exception)}{Environment.NewLine}{exception}{Environment.NewLine}");
        }
    }
}
