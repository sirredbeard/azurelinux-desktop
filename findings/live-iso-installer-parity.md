# Live ISO / installer ISO / installed system / canary container parity

**Status:** active parity checklist

## Context

Four deliverables share a package policy and custom tooling but have different boot and install lifecycles: the live ISO (squashfs+livesys), the qcow2 disk image (installed, persistent), the installer ISO (KIWI runtime + offline repo + Anaconda TUI), and the canary container (repo/policy canary, not a desktop). What must stay in sync and where the intentional differences are is documented here.

## Package and configuration parity matrix

| Item | Live ISO | qcow2 | Installer runtime | Installed target | Canary container |
|---|---|---|---|---|---|
| Azure kernel + usbhid kmod | ✅ | ✅ | N/A | ✅ | Policy check only |
| Pages repo (`azl-desktop-kmods`) | ✅ | ✅ | N/A (embedded) | ✅ | ✅ |
| `azurelinux-desktop-policy` | ✅ | ✅ | In offline repo | ✅ | Transaction check |
| GNOME/GTK stack | ✅ | ✅ | In offline repo | ✅ | ❌ (not a desktop) |
| Dark mode + wallpaper dconf | ✅ (persistent) | ✅ (persistent) | N/A | ✅ | ❌ |
| Dock favorites | ✅ (livesys-gnome) | ✅ (dconf db) | N/A | ✅ (dconf db) | ❌ |
| GDM autologin | ✅ | ✅ | N/A | Anaconda creates account | ❌ |
| Custom launchers + .desktop | ✅ | ✅ | N/A | ✅ | ❌ |
| Edge Canary, GitHub tools | ✅ | ✅ | In offline repo | ✅ | ✅ (rpm only) |
| Flatpak + Flathub | ✅ | ✅ | In offline repo | ✅ | Flatpak install test |
| Plymouth `azurelinux` theme | ✅ (Lorax initrd) | ✅ (dracut --kver) | ✅ (KIWI initrd) | ✅ (Anaconda) | ❌ |
| early-kms.conf | ✅ | ✅ | ✅ | ✅ | ❌ |
| Microsoft/GitHub/RPMFusion repos persisted | ✅ | ✅ | N/A | ✅ | ✅ |
| FEDORA_EXCLUDES in repo files | ✅ | ✅ | N/A | ✅ | N/A |
| Polkit DNF5 rule | ✅ | ✅ | N/A | ✅ | ❌ |
| PAM keyring (gdm-autologin) | ✅ | ✅ | N/A | ✅ | ❌ |
| Copilot CLI + Edit | ✅ | ✅ | In offline extras | ✅ | ✅ |

## Known gaps and intentional differences

### Live ISO vs. qcow2 (lifecycle differences, not drift)

- Live ISO boots with `rd.live.image`; `livesys.service` and `livesys-gnome.service` run at session time. qcow2 never has `rd.live.image` in its cmdline; these services are conditioned not to run.
- Live ISO: `liveuser` created by `livesys-scripts` at first boot. qcow2: `liveuser` pre-created at build time in the disk-image-specific `%post` block.
- Live ISO root is read-only squashfs + RAM overlay. qcow2 is an XFS root that grows to 64 GiB on first boot via `azl-growroot.service`.
- `grub2-tools-extra` and `mtools` present in qcow2 (disk boot tooling), not in live ISO. Both ISOs and qcow2 contain 1,175 RPMs as of 2026-07-24 nightly.

### Installed target from installer ISO (expected gaps)

The installed target has ~1,025 RPMs vs. 1,175 in the live/qcow2. The ~148-name gap is deliberate lifecycle separation:
- Absent from installed target: Anaconda and its deps, `livesys-scripts`, live-dracut, `dracut-config-generic`, `dracut-live`, block-device provisioning tools, Cockpit and its frontend stack, `glibc-all-langpacks`.
- Present only in installed target: persistent LVM/EFI layout, `azl-growroot` disabled (already grown), installer-created admin account with `pwsh` as default shell.
- Installer ISO runtime (Anaconda environment): 426 packages. Carries 1,050 RPMs in its offline repo; Anaconda resolves the target from that closure.

### Installer ISO runtime-only items

- No GDM, no desktop session in the installer runtime. Plymouth + Anaconda TUI only.
- `flatpak-selinux-1.16.6-1.fc43` must be in the offline repo when `selinux-policy-targeted` is installed (Fedora Flatpak requires it conditionally). Anaconda adds `grub2-tools-extra` for the UEFI bootloader beyond what's in the kickstart `%packages` — must be in `EXTRA_REPO_PKGS`.

### EFI vendor path

Our kickstart excludes AZL's `shim-x64` and `grub2-efi-x64`; Fedora's Secure Boot-signed shim/grub RPMs install EFI binaries to `EFI/fedora/`, but Anaconda creates the NVRAM entry pointing to `EFI/azurelinux/shimx64.efi`. `kiwi/post-bootloader.sh` copies `shimx64.efi`, `shim.efi`, `grubx64.efi`, `mmx64.efi` from `EFI/fedora/` → `EFI/azurelinux/` when absent. Do not reintroduce AZL's unsigned shim/grub to avoid this copy step.

### Azure kernel: missing desktop input drivers

AZL kernel `6.18.31-1.6.azl4` explicitly disables `CONFIG_USB_HID` and `CONFIG_INPUT_MOUSE` (confirmed in `base/comps/kernel/6.18-x86_64-azl.config`):

```
Azure:   # CONFIG_USB_HID is not set
Azure:   # CONFIG_MOUSE_PS2 is not set
Azure:   CONFIG_VIRTIO_INPUT=m
Fedora:  CONFIG_USB_HID=y
Fedora:  CONFIG_MOUSE_PS2=y
```

- No `usbhid.ko` or `psmouse.ko` in the Azure kernel. A normal USB mouse and QEMU's USB tablet both use the USB-HID path — absent from the Azure kernel.
- Virtio input (`virtio_input.ko`) is present. QEMU VMs can use `-device virtio-tablet-pci` as a workaround. Not a product fix — real USB mice also need usbhid.
- **Fix:** `azurelinux-desktop-usbhid-kmod` RPM published to the GitHub Pages repo. See `azure-kernel-usbhid-kmod.md`.
- **Fedora control kernel test:** Fedora kernel `6.17.1-300.fc43` + same AZL userspace resolved 1,169 packages cleanly (systemd remained AZL build). Used only as a diagnostic control; Fedora kernel must not become an image dependency.

### Flatpak SELinux

- `flatpak-selinux-1.16.6-1.fc43` (module format 23, active at priority 200) is compatible with the AZL policy base. The earlier format-24 incompatibility theory was disproven by a completed real installation.
- AZL is removing Anaconda's Flatpak source integration upstream (PRs 16957, 17060). No AZL-native Flatpak packaging exists in the public repos. Keep Fedora Flatpak boundary explicitly as unresolved in terms of native AZL packaging, but the Fedora path works.

### Flatpak live-session space

- Live ISO with `--live-rootfs-size 8` ignored for `--make-iso`; Lorax pure-squashfs OverlayFS mode puts the upper layer in tmpfs (~783 MiB at 4 GB RAM). Flatpak's `min-free-space-size=500MB` guard blocked installation since 438 MB < 500 MB.
- Fix: switched to `--rootfs-type squashfs-ext4`; dracut uses DM-snapshot and `statvfs` reports ext4 virtual size (~4 GiB free). Log: `logs/flatpak-live-space-debug.log`.
- Live Flatpak installation requires at least 8 GB RAM in QEMU. 4 GB is sufficient to boot but causes OOM on Flatpak install.

### os-prober and Ubuntu GRUB entries

The disk-image path runs Anaconda on a privileged GitHub Actions runner. `os-prober` scanned runner disks and added Ubuntu GRUB entries to the built qcow2. Fix: disable `os-prober` in the disk-image workflow, regenerate `grub.cfg`, brand all BLS entries as Azure Linux Desktop. Committed in `29f8ab0`.

### Installed GRUB must use gfxterm

`kiwi/post-bootloader.sh` writes the installed system's `/boot/grub2/grub.cfg`. Must use `insmod efi_gop`, `insmod efi_uga`, `insmod all_video`, `set gfxmode=auto`, `set gfxpayload=keep`, `terminal_output gfxterm`, `terminal_input console`. Do NOT use `terminal_output console serial` — forces text-mode GRUB, breaks `gfxpayload=keep`, adds serial overhead on hardware without a serial port. Installer ISO's own GRUB (`kiwi/grub_template.cfg`) already uses gfxterm; installed system must match.

### Root partition growth

qcow2 is resized to 64 GiB after installation, but the kickstart's partition only grew to the install-time disk size (~16 GiB). Fix: `azl-growroot.service` (oneshot, runs once via `ConditionPathExists=!/var/lib/azl-growroot.done`) using `cloud-utils-growpart` + `xfs_growfs`. Resolves root device dynamically (`findmnt`/`lsblk`/`/sys/class/block/*/partition`); device-name-agnostic for VHDX/VDI/VMDK under different hypervisors. Only enabled on disk-image variant.

### Disk image format conversions

- qcow2 is the canonical form produced by `livemedia-creator --make-disk`.
- VHDX, VDI, VMDK are converted from the **already-resized** qcow2 via `qemu-img convert`. Never from the pre-resize raw image — VHDX/VDI/VMDK don't support post-conversion resize (`qemu-img: Image format driver does not support resize`, confirmed empirically).
- Build jobs: `build-disk-image` produces qcow2; `build-vhdx`/`build-vdi`/`build-vmdk` are independent jobs each downloading that artifact. Format conversion does not re-run Anaconda.

## Verification approach

1. **Static filesystem check first.** Mount the ISO squashfs → rootfs.img (two-layer: `LiveOS/squashfs.img` → `LiveOS/rootfs.img` ext4), or mount qcow2 XFS root. Check file presence, modes, dconf content, RPM inventory.
2. **Runtime check second.** Boot in QEMU, verify GNOME session autologin, dock, wallpaper, Plymouth, application launches.
3. **Installed target:** boot installer ISO, complete installation, reboot without ISO, verify first login. Static check of installer ISO runtime (`LiveOS/squashfs.img` → `LiveOS/rootfs.img`) covers Anaconda environment only; installed target rpmdb requires a real installation.
4. **Validator scripts.** `scripts/validate-live-iso-filesystem.sh` (34 checks), `scripts/validate-live-qcow2.sh` (15 checks), `scripts/validate-installer-iso.sh` (10 checks). All pass as of 2026-07-24b artifacts (run 30118396215 / 29990996437).

### Two-layer squashfs structure

Both ISOs use: `LiveOS/squashfs.img` (outer) → `LiveOS/rootfs.img` (inner ext4). Validators must mount both layers. The outer squashfs contains only `LiveOS/rootfs.img`; checking the outer layer finds nothing.

## What didn't work

- **`qemu-nbd` + `unsquashfs` for `rootfs.img`:** `unsquashfs` can't reach into ext4. Use `debugfs -R "dump ..."` to extract files from the inner ext4 image.
- **`unsquashfs -e <path>`:** does not take a path to extract — it takes a file containing a list of paths. Use the path as a plain trailing argument instead.
- **Converting VHDX/VDI/VMDK from the pre-resize raw image:** the formats don't support post-conversion resize. Must convert from the already-resized qcow2.

## Current state

Release 2026-07-24 (commit `c661bdd`, nightly run 30181902965): live ISO 2.75 GB, qcow2 3.1 GB, installer ISO 2.9 GB. All three pass static validation. Live ISO and qcow2 both confirmed GNOME autologin + dark wallpaper in QEMU. Installer ISO confirmed Anaconda TUI appearance in QEMU with interactive disk selection. 2026-07-25 manual QA: no regressions; all user-facing applications functional; PowerShell dock grouping remains known cosmetic issue.

## References

- `logs/installer-flatpak-selinux-dependency.log` — flatpak-selinux offline closure gap
- `logs/installer-grub-support-package.log` — grub2-tools-extra offline closure gap
- `logs/flatpak-live-space-debug.log` — live Flatpak space root cause
- `logs/local-disk-image-efi-and-sparsify-2026-07-20.log` — EFI stub generation, sparsify sequence
- `logs/fedora-kernel-control-download-29893981896.log` — Fedora kernel control test (diagnostic only)
- `logs/disk-build-run-29641568473-storage-log-excerpt.log` — blivet storage debug
- `azure-kernel-usbhid-kmod.md` — USB HID kernel module, GitHub Pages repo
- `anaconda-kickstart-patterns.md` — asset staging, %post, storage directives
- `gnome-desktop-defaults.md` — dconf, GDM, keyring, GNOME configuration
- `fedora-azl-repo-mixing.md` — FEDORA_EXCLUDES, Flatpak SELinux, package sourcing
- `findings/README.md` - index of per-issue findings files
- `deliverable-polish-validation.md` - polish-batch AQ / validation notes
- `flatpak-live-session-space.md` - live Flatpak free-space fix