## Notes

See README.md for project goals, minimum requirements, and build steps.

Keep source dependencies as submodules. Do not vendor full third-party trees.

The primary branch is `main`. Keep its history squashed to a single commit: fold new work into the existing commit (for example, `git reset --soft` to the root and amend) rather than adding commits.

No Co-authored-by trailers in commit messages.

Write docs in the repository voice: direct, factual, precise versions, links to primary sources, and no em-dashes anywhere. Use a comma, colon, parenthetical, or separate sentence instead.

## Details

`<EnableWslcSdk>` in AzureLinuxDesktop.App.csproj is auto-detected: it defaults to `false` and flips to `true` when `artifacts\wslc\wslcsdkcs.dll` exists (produced by scripts\Build-Wsl.ps1). Fresh clones and CI build the stub without edits; do not hardcode the property, and override per-build with `-p:EnableWslcSdk=...` if you must.

The UI is Microsoft UI Reactor only, no XAML files, no XAML-based controls. Native surfaces (e.g. the RDP session) are hosted as child HWNDs behind a Reactor placeholder element (see AzureLinuxDesktop.App\RdpInterop.cs).

The RDP surface is the Windows RDP client control (`mstscax.dll`) hosted as a child HWND behind a Reactor placeholder element, with the window chrome and startup/status UI rendered by Reactor.

## Repository layout

- `AzureLinuxDesktop.App/`: WinUI 3 app. Reactor UI (`App.cs`), wslc launch logic
  (`WslcDesktopLauncher.cs`, including host timezone passthrough), the boot page (`BootPage.cs`, logo plus
  composition spinner), and the embedded RDP desktop (`RdpInterop.cs` hosts mstscax in an owned WinForms
  form glued over a Reactor placeholder)
- `container/Dockerfile`: two-stage image build. Stage 1 compiles pipewire-module-xrdp for audio over RDP.
  Stage 2 installs XFCE from Fedora 43 repos onto Azure Linux 4.0, plus VS Code, PowerShell (release
  tarball, default xfce4-terminal shell), Bluecurve, and the panel/desktop defaults
- `container/fedora43.repo`: Fedora 43 repo overlay. `includepkgs` is the exact dependency closure with
  Azure Linux preferred for everything it provides; both sections must carry the same list
- `container/rasterize-icons.sh`: converts every theme SVG to PNG at build time (see Lessons learned)
- `container/start-desktop.sh`, `container/startwm.sh`, `container/start-audio.sh`: container init,
  XFCE session startup, and the sequenced pipewire stack with the xrdp sink loader
- `container/xfce-defaults/`: xfconf system defaults (panel layout, Bluecurve theme, wallpaper, fonts)
- `external/`: git submodules for source-only dependencies (WSL, Microsoft UI Reactor, Bluecurve)
- `scripts/Setup-BuildEnv.ps1`: installs all prerequisites (VS components, .NET SDK 10, cmake, Developer Mode)
- `scripts/Build-Wsl.ps1`: builds WSL from the `external/WSL` submodule and installs it. Also extracts the
  wslc C# SDK artifacts. Output is logged to `artifacts\build-wsl.log`. Builds for the host architecture by
  default (`-Platform x64|arm64` to override)
- `scripts/Build-WslcSdk.ps1`: rebuilds only the wslc C# SDK artifacts from an already-configured WSL build tree
- `scripts/Build-AzureLinuxRdpImage.ps1`: builds the preconfigured Azure Linux XRDP container image,
  staging the Bluecurve theme from the submodule into the build context first
- `LICENSE.md`: MIT for repo code, acknowledgements and trademarks for everything else

## Lessons learned

Hard-won facts. Verify before assuming any of them changed.

- SVG icons: Fedora 43 dropped the librsvg gdk-pixbuf loader. SVG decode goes through glycin, which
  sandboxes loaders with bubblewrap, and bubblewrap cannot create user namespaces inside the container.
  Result: every SVG icon is a missing placeholder. Removing bubblewrap is worse: glycin's unsandboxed
  path crashes GTK apps here. The fix is `rasterize-icons.sh` in the image build, and bubblewrap stays
  installed so any leftover glycin call fails gracefully. `GLYCIN_SANDBOX_DISABLE` does not exist.
- Git symlinks on Windows: with `core.symlinks=false` (the Windows default), git checks out symlinks as
  plain text files containing the target path. The Bluecurve submodule has thousands of icon-alias
  symlinks, so the staged theme arrives as thousands of 30-byte "PNGs" that shadow good icons in theme
  lookup and fail decode with "Unrecognized image file format". Pass 0 of `rasterize-icons.sh` turns
  path-text files back into real symlinks inside the image. Diagnose with
  `head -c 80 file.png`: if you see a path, it is a checked-out symlink.
- Audio: WSLg-style audio sharing is impossible (wslc sessions are separate VMs with no WSLg). The
  canonical path is pipewire-module-xrdp, compiled in stage 1. Its loader needs `pw-cli` (pipewire-utils)
  and `pactl` (pulseaudio-utils) and the `XRDP_*` env vars sesman exports, and it must run after
  pipewire-pulse is up, which is why `start-audio.sh` sequences the stack instead of trusting XDG
  autostart ordering.
- wslc: the CLI cannot resolve SDK-created sessions by name, so `wslc build --session` fails with
  ERROR_NOT_FOUND. Build into the default store; the app copies with `wslc save` + LoadImageAsync.
  `wslc exec` passes no stdin. SDK ContainerSettings freeze after a create attempt, sessions default to
  no GPU, and networking defaults to none (the CLI defaults to bridge). Sessions die with their creator
  process; their on-disk image stores survive.
- RDP embedding: the mstscax DirectX presenter never paints when parented under a WinUI
  DesktopChildSiteBridge, and the control crashes if created hidden or restyled layered. It lives in a
  borderless owned WinForms form tracked over the placeholder. Do not "simplify" this.
- mstscax on ARM64: the newest CLSID can be unregistered. Probe-activate from v13 down to v9.
- Time: the container clock is host-synced (UTC) through Hyper-V. Only the timezone needs syncing; the
  launcher converts the Windows zone to IANA and re-points /etc/localtime at container start.
- CRLF: a CRLF shebang in any container script fails exec with "no such file or directory".
  `.gitattributes` forces LF under `container/`, and the Dockerfile seds `\r` off as belt and braces.
  PNGs are marked binary so the LF rules cannot mangle them.
- dnf repo files: indented continuation lines belong to the previous key. Commenting out just the first
  `includepkgs=` line makes the file unparseable, and a missing newline can glue `priority=80` to
  `includepkgs=`, silently disabling the filter for that section.
- Publish: `dotnet publish` does not copy WinUI `Content` items unless they carry explicit
  `CopyToOutputDirectory` metadata; runtime-loaded assets (taskbar icon, boot logo) need it. Native AOT
  and trimming are unavailable (WinForms AxHost plus classic COM interop).
- Container apps: WebKit and Electron need their sandboxes disabled in the container
  (`WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`, `code --no-sandbox`); `/run/user/1000` must be owned
  by the desktop user before the session starts.
