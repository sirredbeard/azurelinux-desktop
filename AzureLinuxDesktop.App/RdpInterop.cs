using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Reactor.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Win32;
// Windows.Foundation.Point clashes with System.Drawing.Point (WinForms) —
// alias the WinUI one, which is what XAML layout math uses.
using FoundationPoint = Windows.Foundation.Point;

namespace AzureLinuxDesktop_App;

/// <summary>
/// A Reactor element that shows the Windows RDP client ActiveX control
/// (mstscax.dll) over the placeholder's region — no XAML, no external
/// mstsc.exe.
///
/// Hosting note: mstscax renders nothing when its window is reparented as a
/// child of a WinUI 3 top-level (it stays "Connected" but never presents),
/// while the same control in a plain WinForms window paints fine. So the
/// control lives in a borderless WinForms window OWNED by the WinUI window,
/// glued over the placeholder's screen rectangle by a tracking timer. Owned
/// windows stay above their owner, minimize with it, and take no taskbar
/// slot, so the result looks embedded.
/// </summary>
public sealed record RdpHostElement(
    string Server,
    int Port,
    string UserName,
    string Password,
    Action<string>? OnStatus = null) : Element;

public static class RdpInterop
{
    // Reconciler.IsElementTypeRegistered is internal, so track the reconcilers
    // we've already registered with to keep Register idempotent (duplicate
    // RegisterType calls throw by design — spec 047 §13 Q17).
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<Reconciler, object> Registered = new();

    /// <summary>
    /// Session started ahead of the desktop branch: the boot page stays on
    /// screen while the control connects parked off-screen. The
    /// RdpHostElement adopts this session on mount instead of creating one.
    /// </summary>
    internal static RdpSession? ActiveSession;

    /// <summary>
    /// Starts connecting before any RdpHostElement is mounted. The control's
    /// window is owned by the main window, parked off-screen, and begins its
    /// RDP handshake immediately.
    /// </summary>
    public static void BeginSession(nint ownerHwnd, DispatcherQueue dispatcher, RdpHostElement settings)
    {
        if (ActiveSession is not null)
            return;
        var session = new RdpSession(settings);
        ActiveSession = session;
        session.EnsureAttachedToWindow(ownerHwnd, dispatcher);
    }

    /// <summary>
    /// Registers <see cref="RdpHostElement"/> with a Reconciler. Call from the
    /// <c>configure</c> callback of ReactorApp.Run.
    /// </summary>
    public static void Register(Reconciler reconciler)
    {
        if (!Registered.TryAdd(reconciler, null!))
            return;

        reconciler.RegisterType<RdpHostElement, Border>(
            mount: (r, el, rerender) =>
            {
                var placeholder = new Border();
                // Adopt the pre-connected session when one exists; otherwise
                // run standalone (attach + connect driven by layout).
                var session = ActiveSession ?? new RdpSession(el);
                if (ReferenceEquals(session, ActiveSession))
                    session.Update(el);
                placeholder.Tag = session;

                // The XamlRoot (and therefore the owning HWND) only exists
                // once the placeholder is live in a window's tree.
                placeholder.Loaded += (_, _) => session.EnsureAttached(placeholder);
                placeholder.LayoutUpdated += (_, _) => session.SyncBounds(placeholder);

                Reconciler.SetElementTag(placeholder, el);
                return placeholder;
            },
            update: (r, oldEl, newEl, placeholder, rerender) =>
            {
                if (placeholder.Tag is RdpSession session)
                    session.Update(newEl);
                Reconciler.SetElementTag(placeholder, newEl);
                return null; // updated in place
            },
            unmount: (r, placeholder) =>
            {
                if (placeholder.Tag is RdpSession session)
                {
                    session.Dispose();
                    placeholder.Tag = null;
                }
                Reconciler.DetachReactorState(placeholder);
            });
    }

    /// <summary>
    /// Owns the WinForms/ActiveX side of one RDP session: a borderless
    /// owned Form with the AxHost-wrapped mstscax control docked inside,
    /// a status-polling timer, and a position tracker that keeps the form
    /// glued over the placeholder while the session is visible.
    /// </summary>
    internal sealed class RdpSession : IDisposable
    {
        private RdpHostElement _element;
        private HostForm? _form;
        private RdpAxClient? _rdp;
        private DispatcherQueueTimer? _timer;
        private DispatcherQueueTimer? _trackTimer;
        private readonly WeakReference<Border> _placeholderRef = new(null!);
        private nint _ownerHwnd;
        private bool _connectRequested;
        private string _lastStatus = "";
        private bool _disposed;
        // xrdp inside the container needs a few seconds after the container
        // starts; retry the connection instead of giving up on the first miss.
        private int _reconnectAttemptsLeft = 20;
        private int _ticksUntilReconnect;
        // The form stays parked off-screen until a placeholder adopts it.
        private bool _shown;
        private (int X, int Y, int W, int H) _lastRect;
        // Dynamic resize: when the surface size settles on something other
        // than the negotiated desktop size, renegotiate the resolution.
        private int _sessionW;
        private int _sessionH;
        private (int W, int H) _pendingSize;
        private int _settleTicks;

        public RdpSession(RdpHostElement element) => _element = element;

        public void Update(RdpHostElement element) => _element = element;

        /// <summary>
        /// Window-level attach: create the owned form at roughly the owner's
        /// client size, parked off-screen, and start connecting right away.
        /// Used by BeginSession while the boot page is still on screen.
        /// </summary>
        public void EnsureAttachedToWindow(nint ownerHwnd, DispatcherQueue dispatcher)
        {
            if (_disposed || _form is not null)
                return;

            _ownerHwnd = ownerHwnd;
            _ = GetClientRect(ownerHwnd, out var rc);
            var w = Math.Max(640, rc.Right - rc.Left);
            var h = Math.Max(480, rc.Bottom - rc.Top);
            _lastRect = (OffscreenX, 0, w, h);

            Attach(dispatcher, w, h);
            if (_form is null)
                return; // Attach reported the failure

            _connectRequested = true;
            Connect(w, h);
        }

        /// <summary>
        /// Placeholder attach/adopt: from now on the placeholder's layout
        /// (plus the tracking timer, which also follows window moves) drives
        /// the form position, and the parked form moves into place.
        /// </summary>
        public void EnsureAttached(Border placeholder)
        {
            if (_disposed)
                return;

            var firstShow = !_shown;
            _shown = true;
            _placeholderRef.SetTarget(placeholder);

            if (_form is null)
            {
                if (placeholder.XamlRoot?.ContentIslandEnvironment is not { } island)
                    return;
                _ownerHwnd = Microsoft.UI.Win32Interop.GetWindowFromWindowId(island.AppWindowId);
                if (_ownerHwnd == 0)
                    return;
                Attach(placeholder.DispatcherQueue, 800, 600);
                if (_form is null)
                    return;
            }

            SyncBounds(placeholder);
            if (firstShow)
            {
                // Shown without activation and positioned with SWP_NOZORDER,
                // the owned form sits BEHIND its owner until raised once.
                _ = SetWindowPos(_form!.Handle, HWND_TOP,
                    _lastRect.X, _lastRect.Y, _lastRect.W, _lastRect.H,
                    SWP_NOACTIVATE | SWP_SHOWWINDOW);
                StartTracking(placeholder.DispatcherQueue);
                // Tell the app the surface is actually on screen so it can
                // retire the boot page with no blank gap in between.
                _element.OnStatus?.Invoke("SurfaceVisible");
            }
        }

        private void Attach(DispatcherQueue dispatcher, int width, int height)
        {
            try
            {
                _form = new HostForm
                {
                    FormBorderStyle = System.Windows.Forms.FormBorderStyle.None,
                    ShowInTaskbar = false,
                    StartPosition = System.Windows.Forms.FormStartPosition.Manual,
                    BackColor = System.Drawing.Color.Black,
                    Location = new System.Drawing.Point(OffscreenX, 0),
                    Size = new System.Drawing.Size(width, height),
                };
                _rdp = new RdpAxClient();
                ((ISupportInitialize)_rdp).BeginInit();
                _rdp.Dock = System.Windows.Forms.DockStyle.Fill;
                _form.Controls.Add(_rdp);
                ((ISupportInitialize)_rdp).EndInit();

                // Owned by the WinUI window: stays above it, minimizes with
                // it, no taskbar entry of its own.
                _ = SetWindowLongPtr(_form.Handle, GWLP_HWNDPARENT, _ownerHwnd);
                _form.Show();

                StartStatusTimer(dispatcher);
                ReportStatus("Connecting...");
            }
            catch (Exception ex)
            {
                ReportStatus($"RDP control failed: {ex.Message}");
                Dispose();
            }
        }

        private void StartTracking(DispatcherQueue dispatcher)
        {
            _trackTimer = dispatcher.CreateTimer();
            _trackTimer.Interval = TimeSpan.FromMilliseconds(33);
            _trackTimer.Tick += (_, _) =>
            {
                if (_disposed)
                {
                    _trackTimer?.Stop();
                    return;
                }
                if (_placeholderRef.TryGetTarget(out var placeholder))
                    SyncBounds(placeholder);

                // Debounced dynamic resize: renegotiate the desktop
                // resolution ~0.5s after the size stops changing.
                var size = (_lastRect.W, _lastRect.H);
                if (size != _pendingSize)
                {
                    _pendingSize = size;
                    _settleTicks = 0;
                }
                else if ((size.Item1 != _sessionW || size.Item2 != _sessionH) && ++_settleTicks == 15)
                {
                    ResizeSession(size.Item1, size.Item2);
                }
            };
            _trackTimer.Start();
        }

        /// <summary>
        /// Glue the form to the placeholder's screen rectangle (DIPs →
        /// physical pixels, offset by the owner's client origin). While not
        /// yet adopted the form stays parked off-screen at the same size.
        /// </summary>
        public void SyncBounds(Border placeholder)
        {
            if (_disposed || _form is null || placeholder.XamlRoot is null)
                return;
            if (placeholder.ActualWidth < 1 || placeholder.ActualHeight < 1)
                return;

            var scale = placeholder.XamlRoot.RasterizationScale;
            FoundationPoint origin;
            try
            {
                origin = placeholder.TransformToVisual(null).TransformPoint(new FoundationPoint(0, 0));
            }
            catch
            {
                return; // not in the visual tree yet
            }

            var clientOrigin = new POINT();
            _ = ClientToScreen(_ownerHwnd, ref clientOrigin);
            var x = clientOrigin.X + (int)Math.Round(origin.X * scale);
            var y = clientOrigin.Y + (int)Math.Round(origin.Y * scale);
            var w = (int)Math.Round(placeholder.ActualWidth * scale);
            var h = (int)Math.Round(placeholder.ActualHeight * scale);

            var rect = (x, y, w, h);
            if (rect == _lastRect && _shown)
                return; // nothing moved; skip the SetWindowPos
            _lastRect = rect;

            _ = SetWindowPos(_form.Handle, 0, _shown ? x : OffscreenX, y, w, h,
                SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);

            if (!_connectRequested && _rdp is not null)
            {
                _connectRequested = true;
                Connect(w, h);
            }
        }

        private void Connect(int pixelWidth, int pixelHeight)
        {
            try
            {
                dynamic ocx = _rdp!.GetOcx()!;
                ocx.Server = _element.Server;
                ocx.UserName = _element.UserName;

                dynamic advanced = ocx.AdvancedSettings2;
                advanced.RDPPort = _element.Port;
                advanced.ClearTextPassword = _element.Password;
                advanced.SmartSizing = true; // scale the session on window resize

                // Negotiate NLA/TLS when the server offers it (xrdp negotiates
                // down to TLS). Property arrived with IMsRdpClientAdvancedSettings6.
                try { ocx.AdvancedSettings7.EnableCredSspSupport = true; } catch { /* older control */ }

                // Play remote audio on this computer (rdpsnd channel). The
                // server side needs pipewire-module-xrdp in the image.
                try { ocx.AdvancedSettings.AudioRedirectionMode = 0; } catch { /* optional */ }

                // No drive redirection: chansrv would otherwise FUSE-mount a
                // thinclient_drives folder into the desktop user's home.
                // (The image also sets EnableFuseMount=false server-side.)
                try { advanced.RedirectDrives = false; } catch { /* optional */ }

                ocx.ColorDepth = 32;
                _sessionW = Math.Clamp(pixelWidth, 200, 8192);
                _sessionH = Math.Clamp(pixelHeight, 200, 8192);
                ocx.DesktopWidth = _sessionW;
                ocx.DesktopHeight = _sessionH;
                ocx.Connect();
            }
            catch (Exception ex)
            {
                ReportStatus($"Connect failed: {ex.Message}");
            }
        }

        private void ResizeSession(int width, int height)
        {
            width = Math.Clamp(width, 200, 8192);
            height = Math.Clamp(height, 200, 8192);
            try
            {
                dynamic ocx = _rdp!.GetOcx()!;
                if ((short)ocx.Connected != 1)
                    return;
                try
                {
                    // Dynamic resolution update (IMsRdpClient10+). Falls back
                    // to a quick reconnect at the new size when unsupported.
                    ocx.UpdateSessionDisplaySettings((uint)width, (uint)height, (uint)width, (uint)height, 0u, 100u, 100u);
                }
                catch
                {
                    ocx.Reconnect((uint)width, (uint)height);
                }
                _sessionW = width;
                _sessionH = height;
            }
            catch
            {
                // Resize is best-effort; SmartSizing keeps the session usable.
            }
        }

        private void StartStatusTimer(DispatcherQueue dispatcher)
        {
            _timer = dispatcher.CreateTimer();
            _timer.Interval = TimeSpan.FromMilliseconds(750);
            _timer.Tick += (_, _) =>
            {
                if (_disposed || _rdp is null)
                    return;
                try
                {
                    dynamic ocx = _rdp.GetOcx()!;
                    var state = (short)ocx.Connected;
                    if (state == 0 && _connectRequested && _reconnectAttemptsLeft > 0)
                    {
                        // Wait ~3 ticks (~2.25s) between attempts.
                        if (--_ticksUntilReconnect <= 0)
                        {
                            _reconnectAttemptsLeft--;
                            _ticksUntilReconnect = 3;
                            ReportStatus($"Waiting for the desktop to come up (retry {20 - _reconnectAttemptsLeft})...");
                            ocx.Connect();
                            return;
                        }
                    }
                    ReportStatus(state switch
                    {
                        1 => "Connected",
                        2 => "Connecting...",
                        _ => _connectRequested ? "Disconnected" : "Connecting...",
                    });
                }
                catch { /* control torn down mid-poll */ }
            };
            _timer.Start();
        }

        private void ReportStatus(string status)
        {
            if (status == _lastStatus)
                return;
            _lastStatus = status;
            _element.OnStatus?.Invoke(status);
        }

        public void Dispose()
        {
            if (_disposed)
                return;
            _disposed = true;

            if (ReferenceEquals(ActiveSession, this))
                ActiveSession = null;

            _timer?.Stop();
            _timer = null;
            _trackTimer?.Stop();
            _trackTimer = null;

            if (_rdp is not null)
            {
                try
                {
                    dynamic ocx = _rdp.GetOcx()!;
                    if ((short)ocx.Connected != 0)
                        ocx.Disconnect();
                }
                catch { /* already gone */ }
            }

            _form?.Close();
            _form?.Dispose(); // disposes the AxHost child too
            _form = null;
            _rdp = null;
        }

        /// <summary>Borderless owned form that never steals activation when shown.</summary>
        private sealed class HostForm : System.Windows.Forms.Form
        {
            protected override bool ShowWithoutActivation => true;
        }
    }

    /// <summary>
    /// AxHost wrapper over the Microsoft RDP Client Control. The CLSID is
    /// resolved at runtime from the versioned MsTscAx ProgIDs (newest first)
    /// so we always bind the most capable control installed on the machine.
    /// </summary>
    private sealed class RdpAxClient : System.Windows.Forms.AxHost
    {
        public RdpAxClient() : base(ResolveRdpClsid()) { }

        private static string ResolveRdpClsid()
        {
            // "MsTscAx.MsTscAx.13" → Microsoft RDP Client Control - version 13, etc.
            // Some versions are registered but not servable (v13 fails with
            // CLASS_E_CLASSNOTAVAILABLE on ARM64), so verify activation and
            // fall back a version when the class factory refuses.
            for (var version = 13; version >= 9; version--)
            {
                using var key = Registry.ClassesRoot.OpenSubKey($@"MsTscAx.MsTscAx.{version}\CLSID");
                if (key?.GetValue(null) is not string clsid || clsid.Length <= 2)
                    continue;

                try
                {
                    var type = Type.GetTypeFromCLSID(Guid.Parse(clsid));
                    if (type is null)
                        continue;
                    var probe = Activator.CreateInstance(type);
                    if (probe is not null)
                    {
                        Marshal.ReleaseComObject(probe);
                        return clsid.Trim('{', '}');
                    }
                }
                catch
                {
                    // Registered but not activatable — try the next version down.
                }
            }
            throw new InvalidOperationException(
                "No activatable Microsoft RDP Client Control (mstscax.dll) version found on this machine.");
        }
    }

    // ── Win32 interop ──────────────────────────────────────────────────────

    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const int OffscreenX = -32000;
    private const int GWLP_HWNDPARENT = -8;
    private const nint HWND_TOP = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X, Y;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetClientRect(nint hWnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(nint hWnd, ref POINT point);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(nint hWnd, nint hWndInsertAfter,
        int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowLongPtr(nint hWnd, int index, nint value);
}
