#if WSLC_SDK
using Microsoft.WSL.Containers;
#endif
using System.Diagnostics;

namespace AzureLinuxDesktop_App;

public sealed class WslcDesktopLauncher
{
#if WSLC_SDK
    private Session? _session;
    private Container? _container;
#endif

    public bool IsAvailable
    {
        get
        {
#if WSLC_SDK
            return true;
#else
            return false;
#endif
        }
    }

    public async Task<int> StartDesktopAsync(
        string sessionName,
        string storagePath,
        string imageName,
        string containerName,
        int hostRdpPort,
        Func<Task> buildImageIntoSessionAsync,
        Action<string> log)
    {
#if WSLC_SDK
        var missing = WslcService.GetMissingComponents();
        if (missing != ComponentFlags.None)
        {
            log($"Installing missing wslc components: {missing}");
            await WslcService.InstallWithDependenciesAsync();
        }

        // Pick a free loopback port for the host side of the RDP mapping.
        // Binding the requested port directly fails with WSAEACCES when the
        // host's own Remote Desktop service (or an exclusion range) owns it,
        // and 3389 usually is owned.
        if (hostRdpPort <= 0 || !IsPortFree(hostRdpPort))
        {
            hostRdpPort = FindFreePort();
        }
        log($"Mapping container RDP to localhost:{hostRdpPort}.");

        Directory.CreateDirectory(storagePath);

        // Terminate any leftover session from a previous app instance. A live
        // session with the same display name fails Start with
        // ERROR_ALREADY_EXISTS, and its containers die with it (clean slate).
        await RunWslcQuietAsync($"system session terminate \"{sessionName}\"");

        // Storage handles release asynchronously after a terminate, so retry
        // with a short backoff.
        Session? session = null;
        for (var attempt = 1; session is null; attempt++)
        {
            try
            {
                var settings = new SessionSettings(sessionName, storagePath)
                {
                    CpuCount = 4,
                    MemoryMB = 8192,
                    // Explicit sessions default to no GPU (the service only
                    // defaults it on for the null-settings default session);
                    // the container's EnableGpu flag requires it.
                    FeatureFlags = SessionFeatureFlags.EnableGpu
                };
                session = new Session(settings);
                session.Start();
            }
            catch when (attempt < 5)
            {
                session = null;
                log("Waiting for the previous wslc session to wind down...");
                await Task.Delay(1500);
            }
        }
        _session = session;
        log("wslc session started.");

        // A previous run may have left a container with our name in this
        // session's store (for example, after a failed start). The WinRT SDK
        // has no container enumeration yet, so remove it best-effort with the
        // CLI while the session is alive.
        await RunWslcQuietAsync($"rm --session \"{sessionName}\" -f \"{containerName}\"");

        // wslc image stores are per-session. A plain `wslc build` lands in the
        // default session's store, not this one. Fast path: copy the image
        // over with `wslc save` + LoadImageAsync. Slow path: build it directly
        // into this session (the build script passes --session).
        if (!HasImage(imageName))
        {
            if (await TryLoadFromDefaultStoreAsync(imageName, log))
            {
                log($"Image copied from the default wslc store: {imageName}");
            }
            else
            {
                log("Image not found in any local store. Building it (first run, takes a while)...");
                await buildImageIntoSessionAsync();
                // The build lands in the default store (the CLI cannot build
                // into SDK-created sessions); copy it into this session.
                if (!HasImage(imageName) && !await TryLoadFromDefaultStoreAsync(imageName, log))
                {
                    throw new InvalidOperationException(
                        $"Image '{imageName}' is still missing after the build. Check the activity log.");
                }
            }
        }
        log($"Image ready: {imageName}");

        // The container clock already tracks the host through Hyper-V time
        // synchronization; only the timezone differs (the image defaults to
        // US Eastern). Re-point /etc/localtime at the host's zone on every
        // start so the desktop clock always matches the host.
        var hostTimeZone = GetHostIanaTimeZone();

        // ContainerSettings freeze once a CreateContainer attempt has applied
        // them, so retries need a freshly built instance.
        ContainerSettings BuildSettings(bool withGpu)
        {
            var initProcess = new ProcessSettings();
            initProcess.CmdLine.Add("/bin/bash");
            initProcess.CmdLine.Add("-lc");
            initProcess.CmdLine.Add(
                $"ln -sfn /usr/share/zoneinfo/{hostTimeZone} /etc/localtime 2>/dev/null; " +
                "exec /usr/local/bin/start-desktop.sh");

            var settings = new ContainerSettings(imageName)
            {
                Name = containerName,
                InitProcess = initProcess,
                // The C SDK defaults the network mode to "none" (wslcsdk.cpp,
                // WslcCreateContainerSettings) while the CLI defaults to
                // bridge. Port mappings require networking; set it explicitly.
                NetworkingMode = ContainerNetworkingMode.Bridged,
                // GPU paravirtualization: injects /dev/dxg and the WSL Mesa
                // d3d12 stack via CDI so in-container GL renders on the GPU.
                Flags = withGpu ? ContainerFlags.EnableGpu : ContainerFlags.None
            };
            settings.PortMappings.Add(new ContainerPortMapping((ushort)hostRdpPort, 3389, PortProtocol.TCP));
            return settings;
        }

        try
        {
            _container = _session.CreateContainer(BuildSettings(withGpu: true));
        }
        catch (System.Runtime.InteropServices.COMException ex) when ((uint)ex.HResult == 0x800700B7) // ERROR_ALREADY_EXISTS
        {
            // The best-effort cleanup can miss (CLI session-name resolution
            // is flaky for SDK-created sessions). Remove and retry once.
            log("A container with our name already exists; removing it and retrying...");
            await RunWslcQuietAsync($"rm --session \"{sessionName}\" -f \"{containerName}\"");
            _container = _session.CreateContainer(BuildSettings(withGpu: true));
        }
        catch (System.Runtime.InteropServices.COMException ex) when ((uint)ex.HResult == 0x80070032) // ERROR_NOT_SUPPORTED
        {
            // GPU paravirtualization unavailable; run without it.
            log("GPU passthrough not supported here; starting without it.");
            _container = _session.CreateContainer(BuildSettings(withGpu: false));
        }
        _container.Start();
        log($"Container '{containerName}' started.");
        return hostRdpPort;
#else
        _ = buildImageIntoSessionAsync;
        throw new InvalidOperationException(
            "wslc SDK is not enabled. Run scripts\\Build-Wsl.ps1 (or Build-WslcSdk.ps1) so artifacts\\wslc exists, then rebuild; the project picks it up automatically.");
#endif
    }

#if WSLC_SDK
    /// <summary>
    /// The host's timezone as an IANA name the container's zoneinfo database
    /// understands (for example America/New_York). Falls back to UTC when no
    /// mapping exists. The character check keeps the value safe to splice
    /// into the init shell command.
    /// </summary>
    private static string GetHostIanaTimeZone()
    {
        if (TimeZoneInfo.TryConvertWindowsIdToIanaId(TimeZoneInfo.Local.Id, out var iana)
            && System.Text.RegularExpressions.Regex.IsMatch(iana, @"^[A-Za-z0-9_+\-/]+$"))
        {
            return iana;
        }
        return "Etc/UTC";
    }

    /// <summary>
    /// True when the session's image store has the image. Image names from
    /// the store are canonical (docker.io/library/name:tag), so compare with
    /// the registry prefixes stripped.
    /// </summary>
    private bool HasImage(string imageName)
    {
        static string Normalize(string name) =>
            name.Replace("docker.io/", "", StringComparison.OrdinalIgnoreCase)
                .Replace("library/", "", StringComparison.OrdinalIgnoreCase);

        var wanted = Normalize(imageName);
        return _session!.Images.Any(
            image => string.Equals(Normalize(image.Name), wanted, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Copies the image from the default wslc session store (where a plain
    /// `wslc build` puts it) into this session via `wslc save` + LoadImageAsync.
    /// Returns false when the default store doesn't have it either.
    /// </summary>
    private async Task<bool> TryLoadFromDefaultStoreAsync(string imageName, Action<string> log)
    {
        var tarPath = Path.Combine(Path.GetTempPath(), $"wslc-image-{Guid.NewGuid():N}.tar");
        try
        {
            var info = new ProcessStartInfo(ResolveWslcPath(), $"save -o \"{tarPath}\" \"{imageName}\"")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            // Fully qualified: the wslc SDK also exposes a Process type.
            using var process = System.Diagnostics.Process.Start(info)!;
            await process.WaitForExitAsync();
            if (process.ExitCode != 0 || !File.Exists(tarPath))
            {
                return false;
            }

            log("Copying the image from the default wslc store into this session...");
            await _session!.LoadImageAsync(tarPath);
            return true;
        }
        catch (Exception ex)
        {
            log($"Image copy failed ({ex.Message}); falling back to a build.");
            return false;
        }
        finally
        {
            try { File.Delete(tarPath); } catch { /* temp file */ }
        }
    }

    private static string ResolveWslcPath()
    {
        const string defaultPath = @"C:\Program Files\WSL\wslc.exe";
        return File.Exists(defaultPath) ? defaultPath : "wslc.exe";
    }

    private static async Task RunWslcQuietAsync(string arguments)
    {
        try
        {
            var info = new ProcessStartInfo(ResolveWslcPath(), arguments)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var process = System.Diagnostics.Process.Start(info)!;
            await process.WaitForExitAsync();
        }
        catch
        {
            // Best-effort cleanup; CreateContainer reports the real error if
            // the name is still taken.
        }
    }

    private static bool IsPortFree(int port)
    {
        try
        {
            var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
            probe.Start();
            probe.Stop();
            return true;
        }
        catch (System.Net.Sockets.SocketException)
        {
            return false;
        }
    }

    private static int FindFreePort()
    {
        var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        probe.Start();
        var port = ((System.Net.IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        return port;
    }
#endif
}
