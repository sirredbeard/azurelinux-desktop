# Installer ISO 2026.08.07 clean-room verify

## Status

**Filesystem mount parity: PASS** (installed target vs live ISO checks).  
**Behavioral first boot: PASS** with notes below.  
**Boxes Standard Partition EFI:** still open — see `installer-efi-separate-partition.md`.

## How we installed

- Release tag `2026.08.07` stock installer ISO (no custom `inst.ks`).
- QEMU UEFI, serial TUI, disk `azl-installed-test.qcow2` (~40 GiB virtual).
- Admin user: `azurelinux` / `azurelinux` (wheel).
- Storage: Use All Space + **LVM** (not Standard Partition). ESP on `vda1`, `/boot` on `vda2`, LVM root.
- After Anaconda “Installation complete”, Enter to quit, eject ISO, **UEFI boot from disk only** (do not keep installer `-kernel`/`-initrd` on reset — that re-enters the installer environment).

## Growroot vs bare metal

Growroot is for **prebuilt disk images** that CI builds small then `qemu-img resize`s.  
On a normal installer install to a full-size disk (USB bare metal or a qcow already at final size):

- Anaconda already fills the disk.
- `azl-growroot` runs once, `growpart` is NOCHANGE (or LVM path stamps and skips), writes `/var/lib/azl-growroot.done`.
- **No expand reboot** from growroot itself (the script does not reboot).

**SELinux:** installer `%post` still does `touch /.autorelabel`. First boot runs relabel under Plymouth (`azl-first-boot-prepare` + `SuccessAction=reboot`). That is **one** first-boot reboot, not every boot, and not the same as disk expand.

Observed on this VM:

- `/.autorelabel` absent after boot.
- `/var/lib/azl-growroot.done` present; `azl-growroot.service` skipped (condition unmet).
- Kernel cmdline: `rhgb quiet` (no serial console).

## Mount verify (`scripts/verify-release-features.sh`)

Installed LVM root mounted via nbd + `anaconda_azurelinux-desktop/root`.

| Target | Result |
| --- | --- |
| live-iso | 43 PASS (same run) |
| installer-runtime | 18 PASS |
| installed-qcow | 43 PASS |
| live-qcow | skipped once (bad path); stale nbd mount can also block remount |

**Totals that run:** `PASS=104 FAIL=0 SKIP=1` (skip = live-qcow path).

Installed target included: kmod families (performance, bluetooth, storage, intel, surface, sensors, psmouse, sound, plus thinkpad/typec/usbhid/uvc at runtime), gnome-themes-extra, intel-mediasdk + media-driver, iHD, GPG key, growroot unit/helper, dconf dark, journald/sysctl assets, Copilot flatpak path checks, etc.

## Behavioral (SSH, user azurelinux)

- `systemctl is-system-running`: **degraded** only because `systemd-networkd-wait-online.service` failed. **NetworkManager is active**; typical QEMU/user-net noise, not a desktop blocker.
- SELinux **Enforcing**.
- **GDM + gnome-shell** active; greeter on seat0.
- `color-scheme='prefer-dark'`, `gtk-theme='Adwaita-dark'`; Adwaita-dark theme dirs present.
- Copilot Flatpak **0.1.17** system; remotes `copilot-desktop-gtk` + flathub; appstream refresh unit enabled; polkit flatpak rule present.
- Copilot CLI 1.0.78; `edit` 2.0.0.
- `net.ipv4.tcp_congestion_control = bbr`; journald `SystemMaxUse=200M`; BFQ udev rule for rotational disks.
- Plymouth default theme **azurelinux**; Noto Color Emoji installed.
- EFI: `/boot/efi/EFI/azurelinux/{shimx64,grubx64,...}`.
- Wheel NOPASSWD: file `/etc/sudoers.d/90-wheel-nopasswd` mode `0440`; `sudo -n true` works for azurelinux. (Unprivileged `test -r` fails — verifier must use sudo to read.)

## Canary note

Local `ghcr.io/.../canary:latest` was **stale** (older image): has GPG key + copilot/edit, missing growroot/sudoers paths. Treat canary as placement canary after the **release canary job** for this tag; do not treat a multi-day-old local pull as parity for this install.

## Headless install automation notes

- Single serial chardev + logfile (dual `-serial` left the log empty).
- After install, boot **without** installer kernel/initrd.
- Default user shell is **pwsh** — use `bash -lc` / scp scripts for checks.
- Host sudo for mounts: fedora/fedora.

## Follow-ups landed in tree (next ISO)

* Plymouth first-boot line is now generic: **Finishing setup. System will reboot.**
  (no "expanding disk" — wrong on bare metal when only SELinux relabel runs).
* GRUB: keep menu hidden; also clear `recordfail` / `GRUB_RECORDFAIL_TIMEOUT=0`
  so a prior failed boot cannot force a text menu.

## Still open / next ISO

1. **Standard Partition ESP:** `reqpart` staged in `kiwi/azl-install.ks.in`
   (`installer-efi-separate-partition.md`). Retest Standard on next
   installer ISO. `2026.08.07` still needs LVM or Custom ESP workaround.
2. Optional: mask or drop `systemd-networkd-wait-online` on desktop images if degraded status is confusing (NM-only hosts).
3. Live-qcow remount: ensure previous verify nbd mounts are unmounted before re-run.