# Copilot desktop GTK: WebKit performance and RAM

**Status:** Live ISO MS sign-in confirmed on 0.1.12 (email to
Authenticator to signed-in SPA). 0.1.11 had AADSTS90100 from KMSI
force-complete on `#idSIButton9` Next. Image Flatpak pin follows the
public Pages remote.

## Symptom

- First launch slow. Under a live QEMU guest (6-8 GiB) or with QEMU
  still holding ~8 GiB on the host, the host GNOME session thrashed.
- Sign-in could sit on a blank white WebView while the UI stayed
  responsive.
- Host Flatpak run with QEMU still up left little free RAM. After
  killing QEMU, steady app tree was about 1.0-1.1 GiB RSS (not an
  unbounded process leak).

## Host measurement (roomy Fedora host)

Before app changes (0.1.10):

- Cold start ~10 s: about 874 MiB app tree RSS
- Plateau 15-90 s: about 1.0-1.02 GiB; 12 processes
- After resize: about 1.10 GiB; main WebKitWebProcess ~670 MiB
- Peak about 1110 MiB; process count stable

Breakdown (typical): UI process ~150-190 MiB, main WebKitWebProcess
~600-670 MiB, second WebKitWebProcess ~130 MiB (GPU / compositing),
NetworkProcess ~77 MiB. Second WebKit process is expected on WebKitGTK 6
with hardware acceleration, not a second window leak.

Swap already heavy from earlier thrash amplified freezes even after
QEMU stop.

Console flooded with site noise (frame access, Trusted Types CSP,
Clarity, OneCollector). That is site JS plus
`EnableWriteConsoleMessagesToStdout = true` always on.

## Root causes (app-side, not classic C# leak)

1. Always-on page console to stdout: high volume Clarity/CSP spam.
2. KMSI unlock script injected on every page (including the Copilot SPA)
   with `setInterval` + `MutationObserver` on the full document tree.
   Tick returned early off login hosts, but timers/observer still ran.
3. HardwareAccelerationPolicy.Always + full WebBrowser cache + page
   cache on small VMs: extra GPU process and bfcache snapshots.
4. Harness: 8 GiB live QEMU on a 19 GiB host + browsers + WebKit can OOM
   thrash. Stop QEMU before host Flatpak QA.

WebKitGTK 6 only exposes HA Always or Never (OnDemand removed). Process
sandbox / cross-site process swap cannot be turned off.

## Fix (copilot-desktop-gtk)

Code in the copilot-desktop-gtk tree:

- `RuntimeProfile`: auto low-memory when MemTotal ≤ 6 GiB or
  MemAvailable under 2 GiB; CLI/env overrides
- Low-memory: HA Never, DocumentViewer cache, page cache off, smaller
  default window, spellcheck off, set `WEBKIT_DISABLE_COMPOSITING_MODE=1`
  before WebKit init
- Roomy hosts: HA Always, WebBrowser cache (previous defaults)
- KMSI UserScript allow-list limited to MSA/Entra login hosts only
- KMSI interval 750 ms + debounced MutationObserver; verbose logs gated
- Console-to-stdout only with `--webkit-debug` / `COPILOT_WEBKIT_DEBUG=1`
- CLI: `--low-memory`, `--hardware-acceleration always|never|auto`,
  `--webkit-debug`
- Env: `COPILOT_LOW_MEMORY`, `COPILOT_HARDWARE_ACCELERATION`,
  `COPILOT_WEBKIT_DEBUG`, `COPILOT_DISABLE_COMPOSITING`
- Cleaner teardown: stop load + `about:blank` before destroy

Do not park long WebKit RAM notes in the app's agent instructions. Keep
durable QA here and in app release notes when published.

## Overrides for QA

```bash
flatpak run com.github.sirredbeard.copilot-desktop-gtk --low-memory
flatpak run com.github.sirredbeard.copilot-desktop-gtk --hardware-acceleration=always
flatpak run com.github.sirredbeard.copilot-desktop-gtk --webkit-debug
```

## Image / release notes

- Azure Linux Desktop live/installer prestages Flatpak from the public
  Copilot remote / fetch script. Bump the published app before the next
  ISO expects a given version by default.
- Until then, host or guest can install a local `.flatpak` bundle for QA.
- Plymouth unit-name spam on live is a separate theme fix in
  `assets/plymouth/azurelinux/azurelinux.script`. See
  `plymouth-boot-animation.md`.

## Host recheck after 0.1.11 (QEMU off)

At ~25 s after launch (SPA loading):

- 0.1.10 baseline: ~1.0-1.1 GiB (console spam + KMSI on SPA)
- 0.1.11 default (roomy host, HA Always): ~845 MiB (quieter; no KMSI
  timers on product host)
- 0.1.11 `--low-memory`: ~789 MiB (HA Never + document-viewer; still two
  WebKit processes)

Big win on a roomy host is CPU/console + not running KMSI observers on
the SPA, not a miracle half-GiB drop. Low-memory matters more inside a
6 GiB or smaller guest.

## Live ISO QA (7 GiB QEMU, 0.1.11 then 0.1.12)

- SSH: live kickstart has `sshd` disabled; enable with empty-password
  drop-in for `liveuser`, then `systemctl start sshd`. Hostfwd `2222→22`
  works.
- Guest MemTotal ~6.8 GiB → auto low-memory does not engage (threshold
  ≤6 GiB). RSS after SPA load ~1.1 GiB; during MS sign-in ~1.5 GiB.
  Stable, not a classic leak.
- Blank white page largely gone vs 0.1.10; MS account form paints.
- Regression in 0.1.11: AADSTS90100 `login parameter is empty or not
  valid` right after "Sign in with Microsoft".
- Root cause: KMSI force-complete treated `#idSIButton9` as Yes. That
  id is also Next on the email step. After ~1.2 s the script auto-clicked
  Next with an empty login field.
- Fix (0.1.12): force-click only when page text looks like "Stay signed
  in?" / "Keep me signed in"; never map `#idSIButton9` to Yes on
  email/password steps.

## Live ISO QA (0.1.12 sign-in pass)

- Guest Flatpak updated from Pages remote to 0.1.12; app relaunched.
- User completed email → Authenticator (prompted a second time; likely
  Microsoft account / number-matching UX, not an empty-login loop).
  Landed in the signed-in Copilot UI.
- Guest log still shows some `load-failed: Frame load interrupted` on
  OAuth hops. Superseded frame navigation, not AADSTS90100, and did not
  block sign-in.
- Post-login RSS ~2.3 GiB app tree on 6.8 GiB guest. Usable; tight for
  smaller VMs. No host thrash with QEMU at 7 GiB on this host.

## Still open

- Consider raising auto low-memory MemTotal threshold to 8 GiB so 7 GiB
  VMs engage HA Never without `--low-memory`.
- Optional later: MemoryPressureSettings / back-forward list capacity if
  bindings are clean; do not set kill thresholds that nuke the SPA.
- EGL/Zink warnings under Flatpak on virtio-vga are noisy; UI still
  renders.
- Double Authenticator prompt: watch if it reproduces; only chase if it
  is clearly our WebView double-submitting.

## Related

- Upstream app: https://github.com/sirredbeard/copilot-desktop-gtk
- Live ISO download: `scripts/Get-AzureLinuxDesktop.ps1 -Live`
