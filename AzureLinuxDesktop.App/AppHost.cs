namespace AzureLinuxDesktop_App;

/// <summary>
/// Window-level handles stashed at startup for code that runs before any
/// placeholder element exists (the RDP session starts connecting while the
/// boot page is still on screen).
/// </summary>
public static class AppHost
{
    public static nint WindowHandle { get; set; }
    public static Microsoft.UI.Dispatching.DispatcherQueue? Dispatcher { get; set; }
}
