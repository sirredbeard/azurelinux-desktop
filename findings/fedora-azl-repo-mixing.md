# Fedora + Azure Linux repo mixing

**Status:** active policy; canary guards drift

## Context

This project installs a full GNOME desktop on Azure Linux 4.0 by mixing AZL 4.0 repos (priority source for base OS) with Fedora 43 repos (source for GNOME/GTK stack and anything AZL doesn't ship). The core challenge: `cost=` and `priority=` behave differently in dnf5, ABI conflicts exist between specific package families, and the exclude list must be maintained explicitly or Fedora's newer NEVRAs silently replace AZL-owned packages.

## Known issues and root causes

### priority= vs cost= — the critical difference

- **`priority=` is a hard shadow:** dnf5 selects the highest-priority repo's candidate even if it's unresolvable. Lower-priority repos are never considered for that package name.
- **`cost=` only tie-breaks identical NEVRAs:** if Fedora has a newer NEVRA than AZL for the same package name, Fedora wins regardless of cost. Cost just decides the tiebreaker when both repos have the same version.
- **When `priority=` was switched to `cost=` (to fix a `grub2-efi-x64-cdboot` conflict):** the real installed ISO showed **1,177 total, 60 AZL, 1,100 Fedora, 17 Microsoft/GitHub** — kernel, glibc, systemd, and NetworkManager were all Fedora builds.
- **Fix:** `--setopt=Fedora.excludepkgs=<list>` (and matching for `Fedora-updates`) removes specific package names from Fedora's candidate pool before `cost=` ever gets a tie to break. Wired into both pipelines: `kiwi/config.sh`'s `FEDORA_EXCLUDES` variable and the live kickstart's `repo --excludepkgs=`.
- **Result after clawback:** 171 AZL / 986 Fedora / 16 other / 1,173 total. Kernel, systemd, NetworkManager, bluez, linux-firmware, microcode_ctl, and the base coreutils/util-linux/cryptsetup/openssh/audit/firewalld/selinux-policy layer resolve to AZL.

### Three packages/families that cannot move back to AZL

**1. glibc family (stays on Fedora).**
`gtk4` → `gnome-shell` hard-requires `GLIBC_2.43`. AZL 4.0 ships `glibc-2.42-10.azl4`; Fedora 43 ships `2.42-4.fc43` (same upstream snapshot, different build). Rawhide is at `glibc-2.43.9000` — two releases ahead, not the right donor. Excluding glibc from Fedora with `--skip-unavailable` silently drops the GNOME session. The whole glibc family stays on Fedora.

**2. wpa_supplicant (stays on Fedora).**
No AZL build exists. Excluding it from Fedora with `--skip-unavailable` silently drops it — WiFi breaks with nothing in the build log to flag it. Caught only by listing the offline repo's actual contents, not by trusting exit codes.

**3. fwupd / fwupd-efi (fwupd stays on Fedora).**
AZL's `fwupd` links against `libcbor.so.0.12`. Fedora's `freerdp-libs` (a `gnome-connections` dependency) needs `libcbor.so.0.13`. Only one can be installed. Fedora's `fwupd` is functionally equivalent, so it stays on Fedora. `fwupd-efi` naturally resolves to AZL (Fedora doesn't ship it).

### ABI fork: fuse3-libs (both stay installed)

AZL's `grub2-tools-minimal` links against `libfuse3.so.3`. Fedora's `flatpak`/`xdg-desktop-portal` need `libfuse3.so.4`. Both sonames are genuine, both have real consumers; both AZL and Fedora fuse3 builds stay installed side by side. This is not a conflict — it's two separate library slots. Do not try to unify them.

### Version-locked sibling libraries (must exclude whole family)

Clawing back a parent without its exact-version-locked siblings breaks it:

| Parent | Must also exclude from Fedora |
|---|---|
| `util-linux`/`util-linux-core` | `libblkid`, `libmount`, `libuuid`, `libfdisk`, `libsmartcols` |
| `e2fsprogs` | `libcom_err` |
| `xz` | `xz-libs` |

These have confirmed ABI-compatible identical max-exported symbol versions in both repos. Not the same situation as fuse3 (genuine soname fork).

### The 93-package FEDORA_EXCLUDES list

```
audit, audit-libs, audit-rules, bash, bluez, bluez-libs, bluez-obexd,
bzip2, ca-certificates, chrony, coreutils, coreutils-common, cryptsetup,
cryptsetup-libs, dbus, dbus-broker, dbus-common, dbus-libs,
device-mapper, device-mapper-event, device-mapper-event-libs,
device-mapper-libs, device-mapper-persistent-data, diffutils,
dosfstools, e2fsprogs, e2fsprogs-libs, efibootmgr, findutils,
firewalld, gawk, grep, gzip, hwdata, iproute, iputils, kbd, kernel,
kernel-core, kernel-modules, kernel-modules-core, kernel-modules-extra,
kmod, less, libaio, libblkid, libcom_err, libfdisk, libmount, libnm,
libsmartcols, libuuid, linux-firmware, linux-firmware-whence, lvm2,
microcode_ctl, ModemManager-glib, mtools, ncurses, ncurses-base,
ncurses-libs, NetworkManager, NetworkManager-libnm, NetworkManager-team,
NetworkManager-tui, NetworkManager-wifi, openssh, openssh-clients,
openssh-server, patch, polkit, polkit-libs, procps-ng, sed,
selinux-policy, selinux-policy-targeted, setup, shadow-utils, sudo,
systemd, systemd-boot-unsigned, systemd-container, systemd-libs,
systemd-networkd, systemd-pam, systemd-resolved, systemd-udev, tar,
util-linux, util-linux-core, vim-minimal, xz, xz-libs
```

### Cockpit / selinux-policy chain (2026-07-26)

**Symptom:** `dnf upgrade` on live qcow2/ISO skips `cockpit-ws` and `cockpit-ws-selinux` with broken dependency errors:
```
Problem 1: cockpit-ws-selinux-364-1.fc43 requires selinux-policy-targeted >= 43.8,
           but selinux-policy-targeted-43.8-1.fc43 is filtered out by exclude filtering
Problem 2: cockpit-ws-364-1.fc43 requires (cockpit-ws-selinux = 364-1.fc43 if
           selinux-policy-base), but none of the providers can be installed
```
**Root cause:** Cockpit from AZL installed fine at build time. `fedora43-updates` later published `cockpit-ws-364`, which requires `cockpit-ws-selinux-364`, which requires Fedora's `selinux-policy-targeted >= 43.8`. But `selinux-policy` and `selinux-policy-targeted` are in `FEDORA_EXCLUDES` (AZL owns them). The update chain breaks because the new Fedora cockpit-ws version pulls a dep on the excluded Fedora selinux-policy.

**Fix:** Add `cockpit, cockpit-ws, cockpit-ws-selinux, cockpit-bridge, cockpit-networkmanager, cockpit-packagekit, cockpit-selinux, cockpit-storaged, cockpit-system` to `FEDORA_EXCLUDES` in both static lists (live kickstarts) and `kiwi/config.sh`. Cockpit is an AZL infrastructure tool; it should stay on AZL's version.

**Installer ISO: already handled dynamically.** `kiwi/config.sh` uses a vendor-based dynamic `FEDORA_EXCLUDES`: `rpm -qa --qf '%{NAME}\t%{VENDOR}\n'` filtered for "Microsoft Corporation". AZL-installed cockpit has vendor "Microsoft Corporation", so it was already excluded. The static lists in live artifacts were the gap.

**Packages upgrading Fedora→Fedora (acceptable):** `javascriptcoregtk4.1`, `webkit2gtk4.1`/`webkitgtk6.0`, `p11-kit`, `pam`, `python3-idna` — all Fedora-vendored packages upgrading from offline snapshot to live Fedora 43 updates. Expected; FEDORA_EXCLUDES only covers AZL-owned (Microsoft Corp vendor) and explicit cockpit-family additions.

### Other specific conflicts (early investigation)

- **`hunspell-en`:** pure file collision (no ABI). Both repos ship it at different versions with identical paths. Fix: exclude from AZL, let Fedora win.
- **`gsettings-desktop-schemas`:** version floor. `gnome-shell` requires `>= 50~alpha`; AZL ships `49.1`. Fix: exclude from AZL.
- **`grub2`/`shim` family:** AZL's `grub2-tools-minimal` links `libfuse3.so.3`; Fedora's `flatpak`/`xdg-desktop-portal` need `libfuse3.so.4`. Fix: hand the **entire** grub2/shim family to Fedora. Cherry-picking individual libs out of a coherent dep tree just moves the conflict one layer down.
- **`dnf5`/`libdnf5`/`dnf5daemon-server`:** `gnome-software` needs `dnf5daemon-server(x86-64) >= 5.4.2`; AZL ships `5.2.18.0`. Same "hand the whole family to one repo" fix.
- **`aznfs`:** Azure Files NFS mount helper pulled from `ms-prod` as a transitive dep. Its `%pre` scriptlet hard-fails without `/proc`. Excluded with `-aznfs` in `%packages`.
- **`grub2-efi-x64-cdboot`:** Lorax only builds `EFI/BOOT` + `images/efiboot.img` if it finds `boot/efi/EFI/*/gcdx64.efi` (from `grub2-efi-x64-cdboot` specifically, not plain `grub2-efi-x64`). Missing it silently skips the EFI template section; xorrisofs fails later. Add explicitly to `%packages`.

### Persisting non-AZL/non-Fedora repos

Seven extra `repo` lines (`ms-prod`, `vscode`, `edge-canary`, `gh-cli`, `github-desktop`, `rpmfusion-free`, `rpmfusion-nonfree`) were build-time-only — never persisted to `/etc/yum.repos.d`, leaving those packages frozen at build-time versions with no `dnf upgrade` path. Fix: two `.repo` files in both `%post` blocks:

- `azl-desktop-microsoft-github.repo`: `ms-prod`, `vscode`, `edge-canary`, `gh-cli`, `github-desktop` (`priority=1`).
- `azl-desktop-rpmfusion.repo`: `rpmfusion-free`, `rpmfusion-nonfree` (`priority=50`).

The AZL base and Fedora `.repo` files come from their standard package installers; only these seven extra sources needed explicit persistence.

### Dynamic vs. static FEDORA_EXCLUDES

- **Installer ISO:** `kiwi/config.sh` builds `FEDORA_EXCLUDES` dynamically from `rpm -qa --qf '%{NAME}\t%{VENDOR}\n'` filtered for "Microsoft Corporation". New AZL-vendored packages are automatically excluded from Fedora without manual list maintenance. AZL packages with "Microsoft Corporation" as vendor (including cockpit, kernel, systemd, etc.) are correctly excluded.
- **Live ISO / qcow2 kickstarts:** static `excludepkgs=` list on each Fedora repo line. Must be manually updated when new AZL-owned packages would otherwise be shadowed by Fedora. The cockpit family was the first gap found post-ship.

## What didn't work

- **`priority=` for Fedora repos:** caused `grub2-efi-x64-cdboot`'s AZL dependency to be unresolvable (AZL repo was priority 1; Fedora's `grub2-efi-x64-cdboot` was shadowed; AZL doesn't ship it). Switched to `cost=`.
- **`dnf group install workstation-product-environment`:** far more conflicts than the curated approach (NetworkManager-libnm locks, Box2D/glibc, libdisplay-info soname, glycin mismatches). The right approach: curated initial install, both repos enabled, grow the exclude list as conflicts appear.
- **`--skip-unavailable` for packages not in AZL:** silently drops the package with nothing in the build log. Always verify the offline repo's actual contents, not exit codes.
- **Using Fedora rawhide instead of Fedora 43:** rawhide is at `glibc-2.43.9000`, two releases of drift ahead. Constant conflicts. Fedora 43 (one release ahead of AZL, same upstream glibc snapshot) is the correct donor.

## Alternative architectures considered and rejected

- **systemd-sysext/confext:** overlayfs namespace trick; same ABI (host `ld.so`). `GLIBC_2.43` requirement doesn't go away via squashfs delivery. No project ships a full desktop this way.
- **bootc/OSTree:** no AZL bootc base image; rpm-ostree layering calls the same libdnf dependency resolver. `ublue-os/bluefin-lts` (CentOS Stream 10 + GNOME COPR) hits the same conflict category and uses the same fix tools (excludes, version locks). Confirms the approach; doesn't offer a shortcut.
- **systemd-nspawn:** competing seat managers, GPU driver drift risk, manual socket bridging for PipeWire/D-Bus. Nobody runs a real direct-KMS GNOME session this way.
- **Toolbox/distrobox app export:** right tool for individual apps that would extend the exclude list; cannot replace the GNOME session itself.
- **COPR rebuild:** technically possible. Rebuilding the Fedora packages natively means first owning and maintaining a newer glibc (core OS work). Full scope estimate requires a binary-to-SRPM lockfile and separate `BuildRequires` closure. A glibc fork creates a permanent support obligation. Recommended only as a narrow pilot (see `copr-azure-linux-desktop-rebuild-scope.md` for detailed breakdown).

## Desktop lifecycle and update policy

- Treat each published image as one tested AZL + Fedora desktop generation.
- Routine `dnf upgrade --refresh --best` is reasonable only while that generation's repos and ownership exclusions stay unchanged.
- When the Fedora desktop repo reaches EOL, AZL updates do not replace missing desktop-layer security updates.
- Do not automatically redirect an installed image to a newer Fedora release — the package-family boundaries are tested for one specific pairing.
- Normal migration path: backup or VM snapshot, then clean install of a new image.

## Prior art

- `Nue-Houjuu/azurelinux-fedora-repo-installer`: adds Fedora repos to AZL for XFCE/KDE. Unaffiliated; confirms the basic approach.
- `ublue-os/bluefin-lts`: CentOS Stream 10 + GNOME COPR. Hits identical conflict category (`libjxl` ABI mismatch, `glib2` version floor, `fontconfig` symbol requirement, `selinux-policy` varlink rules); fixes them with excludes, version locks, forced upgrades. Independent validation this class of conflict is normal and known.

## Current state

Live ISO and qcow2 kickstarts: static 93-package `FEDORA_EXCLUDES` + cockpit family additions on all Fedora `repo` lines and persisted `.repo` files. Installer ISO `config.sh`: dynamic vendor-based exclusion. Final split: 171 AZL / 986 Fedora / 16 other / 1,173 total for live ISO. Verified by `scripts/podman-test-azl4-fedora.sh` parsing live kickstart directly (azl4=643, fc43=513 in preflight run 2026-07-22).

## References

- `logs/podman-resolve-full-desktop-947pkgs-edge-canary-code-insiders.log` — early 947-package resolution with old priority= approach
- `logs/podman-resolve-full-package-list-1019pkgs-success.log` — 1019-package resolution
- `logs/preflight-iteration-2026-07-22.log` — current preflight pass (azl4=643, fc43=513)
- `investigation.md` — superseded; initial conflict investigation preserved
- `package-sourcing-clawback.md` — superseded; full clawback investigation preserved
- `copr-azure-linux-desktop-rebuild-scope.md` — COPR rebuild scope analysis
- `alternative-architectures.md` — superseded; alternative architecture analysis preserved

### anaconda-live / anaconda-webui / cockpit chain (2026-07-26)

**Symptom:** Live ISO build failed — `anaconda-live-43.44` (Fedora) added a new dep on
`anaconda-webui`, which requires `cockpit-ws >= 275` and `cockpit-bridge >= 275`. All providers
filtered out by exclude filtering.

**Root cause (two parts):**
1. Cockpit has never been in AZL repos — it is 100% Fedora-sourced. The earlier cockpit pin was
   based on a wrong assumption that AZL shipped cockpit.
2. `cockpit-ws-selinux-364` (fedora43-updates) requires `selinux-policy-targeted >= 43.8`, but
   AZL ships only 43.4. Excluding selinux-policy-targeted from Fedora meant cockpit-364 could
   never satisfy its own dep chain.

**Fix:** Remove `cockpit*` and `selinux-policy/selinux-policy-targeted` from `FEDORA_EXCLUDES`
in all three deliverables (live.ks, live-disk.ks, config.sh). Fedora's selinux-policy-targeted
43.8 wins over AZL's 43.4 by version preference (no explicit pin needed). Cockpit-364 from
fedora43-updates installs cleanly. Security updates for cockpit are no longer blocked.

**Verified:** Canary container rebuild — `anaconda-webui` resolves, cockpit-364 from
fedora43-updates, no Problem lines.