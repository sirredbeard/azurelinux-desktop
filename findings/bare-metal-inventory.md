# Bare-metal inventory - first full session inside the installed desktop

**Status:** Baseline recorded 2026-08-06. First Copilot CLI session run
inside azurelinux-desktop booted on real hardware. This file is the
reference snapshot of what the machine, OS, and tooling look like from
inside.

## Hardware

* Lenovo ThinkPad (`20JTS0D500`), Intel Core i5-6300U (Skylake), 4 CPUs
* 20 GB RAM
* Intel HD Graphics 520, `i915` in use, `/dev/dri/card1` + `renderD128`
* Intel Wireless-AC 8260 (`wlp58s0`) + Intel BT USB `8087:0a2b` (CNVi)
* NVMe disk, dual boot: Fedora host on LUKS (`nvme0n1p3`), AZL on the
  `nvme0n1p4` container partition per `dual-boot-nested-host-partition.md`

## Disk layout (AZL side)

```
nvme0n1p4p1  600M  vfat  /boot/efi
nvme0n1p4p2    2G  ext4  /boot
nvme0n1p4p3 60.8G  ext4  /        (18% used)
nvme0n1p4p4 29.7G  ext4  /home
```

`BOOT_IMAGE=/vmlinuz-azl-desktop-nested`. Cmdline is clean for desktop
use: `ro rootwait console=tty0 rhgb quiet` - no serial console, Plymouth
theme `azurelinux`, `/sys/class/tty/console/active` = `tty0`.

## OS and package origins

* Azure Linux 4.0 (Four Beta), kernel `6.18.31-1.12.azl4`
* 1053 RPMs total: 573 `.azl4`, 470 `.fc43`, ~10 vendor
* GNOME Shell 49.8, GDM 49.3, Mutter 49.7 (Fedora packages), Wayland
* PipeWire 1.4.11 + WirePlumber active (Flatpak portal stack healthy)
* bluez 5.86, flatpak 1.16.6, plymouth from Fedora 43

Project kmod RPMs installed, all matching kernel `6.18.31-1.12.azl4`:
bluetooth, iwlwifi, psmouse, sound, thinkpad, typec, usb-storage,
usbhid, uvc, plus `azurelinux-desktop-policy`. Modules land in
`/lib/modules/*/extra/azurelinux-desktop/`. Kernel taint `12288`
(OOT + unsigned) is expected from these.

## Repos (`/etc/yum.repos.d/`)

| Repo | Role | Priority/cost |
| --- | --- | --- |
| `azurelinux.repo`, `microsoft.repo` | AZL base + Microsoft | default |
| `azl-desktop-fedora.repo` | Fedora 43 + updates, long exclude list | 50 |
| `azl-desktop-rpmfusion.repo` | RPM Fusion free/nonfree | 50 |
| `azl-desktop-microsoft-github.repo` | ms-prod, vscode, edge-canary, gh-cli, github-desktop | 1 |
| `azl-desktop-kmods.repo` | project Pages DNF repo, `gpgcheck=1` | cost=1 |

## Tools on the box

| Tool | Version | Source |
| --- | --- | --- |
| pwsh | 7.6.4 | `powershell` RPM (ms-prod); default shell of `azurelinux` |
| edit | 2.0.0 | side-load, `/usr/local/bin/edit` |
| dotnet | 11.0.100-preview | `/usr/share/dotnet` |
| gh | 2.97.0 | gh-cli repo, keyring auth as `sirredbeard` |
| Copilot CLI | 1.0.78 | `/usr/local/bin/copilot` |
| Copilot GUI | 0.1.16 | Flatpak `com.github.sirredbeard.copilot-desktop-gtk`, signed `copilot-desktop-gtk` remote |

Flatpak remotes (system): `copilot-desktop-gtk`, `flathub`. Also
installed: Blue Recorder, GNOME Platform 50, Mesa, Intel VAAPI, codecs.

## Desktop state

* Favorites: Copilot GTK, Edge Canary, Code Insiders, PowerShell,
  GitHub Copilot, Nautilus
* Wallpaper: `/usr/share/backgrounds/azurelinux/adwaita-{l,d}.jpg`
* No user GNOME extensions
* Wi-Fi connected via NM; BT powered with paired audio device
* Running services: gdm, NetworkManager, bluetooth, pipewire,
  wireplumber, fwupd, udisks2, sshd, thermald, etc.

## Noise in the journal (all low impact, recorded once)

* `usb 1-4 ... error -71` retries at boot - CNVi BT settle time, then
  firmware loads fine (see `bluetooth-hci-timeout-thinkpad.md`)
* `hdaudio hdaudioC1D2: Unable to configure, disabling` - one codec
  node disabled; audio output works
* `systemd-networkd-wait-online.service` fails - networkd is enabled
  but NM owns the links; cosmetic failed unit at boot
* `gkr-pam: unable to locate daemon control file` at login - GNOME
  keyring PAM note, no functional impact seen
* `obexd: stat(/home/azurelinux/phonebook/telecom)` - normal obex noise

## Access notes for future agent sessions

* Passwordless wheel sudo is the product default (live + installed).
  This host has `/etc/sudoers.d/90-wheel-nopasswd`. Do not put the
  account password in git.
* RPM DB is **root-owned** (correct). Query files should be mode
  `0644`; if `rpmdb.sqlite` is `0600`, non-root `rpm -q` fails — use
  `sudo rpm` or `chmod a+r` (see `rpmdb-permissions.md`).
* Default shell is `pwsh`. Wrap POSIX one-liners in `bash -c '...'`
  when scripting over SSH or in scripts.
* Full package snapshot: `rpm -qa | sort` (or `sudo rpm -qa` if DB is
  still mode 0600).
