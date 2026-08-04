# Copilot desktop GTK - WebKit performance and RAM

**Status:** Improved in upstream app `sirredbeard/copilot-desktop-gtk` (local
build **0.1.11**). Not yet shipped through Azure Linux Desktop image rebuild /
Pages Flatpak pin. Host RSS recheck done; live-ISO VM retest still open.

## Symptom

- First launch slow; under a live QEMU guest (6–8 GiB) or with QEMU still
  holding ~8 GiB on the host, the host GNOME session thrashed (Wait / Force
  Quit).
- Sign-in could sit on a blank white WebView while the UI stayed responsive.
- Host Flatpak run with QEMU still up left ~870 MiB free; after killing QEMU,
  steady app tree was ~1.0–1.1 GiB RSS (not an unbounded process leak).

## Host measurement (2026.08.04, Fedora host, ~19 GiB RAM)

Before app changes (0.1.10):

| Phase | App tree RSS | Notes |
| --- | --- | --- |
| ~10 s | ~874 MiB | cold start |
| ~15–90 s | ~1.0–1.02 GiB | plateau; **12** processes |
| after resize | ~1.10 GiB | main WebKitWebProcess ~670 MiB |
| peak | ~1110 MiB | process count stable |

Breakdown (typical): UI `copilot-desktop-gtk` ~150–190 MiB, main
WebKitWebProcess ~600–670 MiB, second WebKitWebProcess ~130 MiB (GPU /
compositing), NetworkProcess ~77 MiB. Second WebKit process is expected on
WebKitGTK 6 with hardware acceleration, not a second window leak.

Swap was already ~7.7 / 8 GiB used from earlier thrash - that amplified freezes
even after QEMU stop.

Console was flooded with site noise (`copilot.microsoft.com` ↔ `copilot.fun`
frame access, Trusted Types CSP, Clarity, OneCollector 503). That is site JS
plus `EnableWriteConsoleMessagesToStdout = true` always on.

## Root causes (app-side, not classic C# leak)

1. **Always-on page console → stdout** - high volume Clarity/CSP spam.
2. **KMSI unlock script injected on every page** (including the Copilot SPA)
   with `setInterval` + `MutationObserver` on the full document tree. Tick
   returned early off login hosts, but the timers/observer still ran and
   burned CPU on a busy DOM.
3. **HardwareAccelerationPolicy.Always** + full **WebBrowser** cache +
   **page cache** on small VMs - extra GPU process and bfcache snapshots.
4. **Harness**: 8 GiB live QEMU on a 19 GiB host + browsers + WebKit ≈ OOM
   thrash. Stop QEMU before host Flatpak QA.

WebKitGTK 6 only exposes HA **Always** or **Never** (OnDemand removed). Process
sandbox / cross-site process swap cannot be turned off.

## Fix (copilot-desktop-gtk)

Code (local tree `~/copilot-desktop-gtk`, build 0.1.11):

| Change | Where |
| --- | --- |
| `RuntimeProfile` - auto low-memory when MemTotal ≤ 6 GiB or MemAvailable under 2 GiB; CLI/env overrides | `RuntimeProfile.cs`, `Program.cs` |
| Low-memory: HA Never, DocumentViewer cache, page cache off, smaller default window, spellcheck off, set `WEBKIT_DISABLE_COMPOSITING_MODE=1` before WebKit init | `RuntimeProfile.cs`, `MainWindow.cs` |
| Roomy hosts: HA Always, WebBrowser cache (previous defaults) | same |
| KMSI UserScript **allow-list** limited to MSA/Entra login hosts only | `MainWindow.cs` |
| KMSI interval 750 ms + debounced MutationObserver; verbose logs gated | `MainWindow.cs` |
| Console-to-stdout only with `--webkit-debug` / `COPILOT_WEBKIT_DEBUG=1` | `MainWindow.cs` |
| CLI: `--low-memory`, `--hardware-acceleration always\|never\|auto`, `--webkit-debug` | `Program.cs` |
| Env: `COPILOT_LOW_MEMORY`, `COPILOT_HARDWARE_ACCELERATION`, `COPILOT_WEBKIT_DEBUG`, `COPILOT_DISABLE_COMPOSITING` | same |
| Cleaner teardown: stop load + `about:blank` before destroy | `MainWindow.cs` |

Build path: `./scripts/podman-build-local.sh --pull-ghcr 0.1.11` →
`dist/flatpak/com.github.sirredbeard.copilot-desktop-gtk-0.1.11.flatpak`.

Do **not** park long WebKit RAM notes in the app's
`.github/copilot-instructions.md` - keep agent norms short; durable QA lives
here (and in the app commit message / release notes when published).

## Overrides for QA

```bash
# Force lean profile on a roomy host (VM-like)
flatpak run com.github.sirredbeard.copilot-desktop-gtk --low-memory

# Force GPU path even on a small VM
flatpak run com.github.sirredbeard.copilot-desktop-gtk --hardware-acceleration=always

# Site console + profile line
flatpak run com.github.sirredbeard.copilot-desktop-gtk --webkit-debug
```

## Image / release notes

- Azure Linux Desktop live/installer prestages Flatpak from the public Copilot
  remote / fetch script. Bump the published app (release workflow on
  copilot-desktop-gtk) before the next ISO expects 0.1.11+ by default.
- Until then, host or guest can install the local `.flatpak` bundle for QA.
- Plymouth unit-name spam on live is a **separate** theme fix in
  `assets/plymouth/azurelinux/azurelinux.script` (drop UpdateStatus hook);
  see `plymouth-boot-animation.md`.

## Host recheck after 0.1.11 (same machine, QEMU off)

At ~25 s after launch (SPA loading, not idle forever):

| Profile | App tree RSS | Notes |
| --- | --- | --- |
| **0.1.10 baseline** | ~1.0–1.1 GiB | console spam + KMSI on SPA |
| **0.1.11 default** (roomy host, HA Always) | **~845 MiB** | quieter; no KMSI timers on product host |
| **0.1.11 `--low-memory`** | **~789 MiB** | profile line confirms HA Never + document-viewer; still two WebKit processes (engine may keep a helper even with compositing off) |

So the big win on a roomy host is **CPU/console + not running KMSI observers on the SPA**, not a miracle half-GiB drop. Low-memory still matters more inside a **6 GiB or smaller guest** where auto profile engages and swap pressure is real.

## Still open

- Retest blank MS sign-in on live ISO VM with 0.1.11 + low-memory auto
  (MemTotal in guest ≤ 6 GiB should select Never HA).
- Optional later: `MemoryPressureSettings` / back-forward list capacity if
  GirCore bindings are clean; do not set kill thresholds that nuke the SPA.
- Publish app release + refresh desktop image Flatpak pin when ready.
  Commit/push on `copilot-desktop-gtk` when ready (local 0.1.11 bundle already
  installed for host QA).

## Related

- Upstream app: https://github.com/sirredbeard/copilot-desktop-gtk
- Local QA artifacts: `~/azl-work/copilot-host-qa/`
- Live ISO download: `scripts/Get-AzureLinuxDesktop.ps1 -Live`
