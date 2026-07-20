# GitHub Actions live ISO build - what we learned

What was found and fixed while getting the live ISO, disk images, and
the whole CI pipeline working. Earlier findings docs
(`investigation.md`, `live-iso-and-bare-metal.md`,
`alternative-architectures.md`) cover the podman package-resolution
research and the first local `livemedia-creator` bring-up; this one
picks up from "move the build to GitHub Actions" onward.

## Why move off local builds

Local `livemedia-creator` builds were memory-constrained (~58 min vs.
~31 min on GH Actions because of swap thrashing). GH Actions runners
(`ubuntu-latest`, ~14GB RAM) don't have that problem.

## The workflow itself

`.github/workflows/build-live-iso.yml` - manual (`workflow_dispatch`),
runs in a Fedora container (`registry.fedoraproject.org/Fedora container`)
on an `ubuntu-latest` runner. Installs lorax/anaconda/livemedia-creator,
checks out the repo to `/workspace`, runs `livemedia-creator --no-virt`
against `kickstart/azurelinux-desktop-live.ks`, and uploads the ISO and
build log as workflow artifacts.

## Runs 1-2: missing `grub2-efi-x64-cdboot`

First runs failed in `xorrisofs`: `Cannot determine attributes of
source file '.../EFI/BOOT': No such file or directory`. Root cause:
lorax's `x86.tmpl` only builds `EFI/BOOT` + `images/efiboot.img` if it
finds `boot/efi/EFI/*/gcdx64.efi`, which ships in
`grub2-efi-x64-cdboot` specifically - not in plain `grub2-efi-x64`.
Missing it doesn't fail the package install; it silently skips the
whole EFI template section, then `xorrisofs` blows up later. Fix: add
`grub2-efi-x64-cdboot` to `%packages`.

## Run 3: first real success - bugs found from QEMU testing

31m3s, first working ISO. Downloaded and boot-tested in QEMU (see
`scripts/qemu-test-live-iso.sh`). Boots to a real GNOME desktop.
Bugs found from directly viewing the QEMU GTK window plus mounting the
ISO's squashfs:

### Dock/favorites never applied

`livesys-gnome` had the correct `favorite-apps=` sed patch, but
`livesys-main`'s dispatch logic
(`if [ "${livesys_session}" ]; then . sessions.d/livesys-${livesys_session} ; fi`)
is a complete no-op when `livesys_session=""` (empty, the out-of-box
default). The kickstart never set this variable. Fix:

```
sed -i 's/^livesys_session=.*/livesys_session="gnome"/' /etc/sysconfig/livesys
```

### GitHub Copilot GUI/CLI/edit never installed (no network in chrooted `%post`)

`/var/log/azl-desktop-post.log` had: `curl: (6) Could not resolve host:
api.github.com`. **Regular (chrooted) `%post` has no network access at
all** in `livemedia-creator --no-virt` builds, even though `%packages`/
`dnf5` clearly does. Anaconda's payload/dnf5 backend manages its own
network setup that isn't inherited by the chrooted `%post` shell.

Fix: split all curl-based downloads into a `%post --nochroot` section
(placed before the regular `%post` in kickstart file order). `%post
--nochroot` runs in the anaconda/build-host environment with real
network; the target root is mounted at `/mnt/sysimage` (confirmed via
`pyanaconda/argument_parsing.py`, hardcoded `ANACONDA_ROOT_PATH`).
Downloads go to `/mnt/sysimage/root/thirdparty/`; the regular `%post`
installs from those staged local files. Also a convenient place to
`cp` repo assets (icons, `.desktop` files, plymouth theme) directly
from `/workspace/` - the nochroot step runs in the same container, no
packaging step needed for small files we already own.

### GNOME Keyring "Choose password for new keyring" dialog

Traced to **Microsoft Edge Canary** auto-launching at first login and
calling `CreateCollection` on an empty Secret Service. GDM autologin
skips the normal PAM auth stack - `pam_gdm.so`'s `[success=ok
default=1]` jumps past `-auth optional pam_gnome_keyring.so` in
`/etc/pam.d/gdm-autologin`, so `pam_gnome_keyring.so` never runs in
the auth stack, and no password (not even empty) seeds a login keyring.

Fix (replaces the earlier `--unlock` autostart workaround): add an
unskippable `auth optional pam_gnome_keyring.so` line past where
`pam_gdm.so`'s skip lands (before the `pam_permit.so` line), plus the
session-stack `auto_start` line - same pattern real GNOME-kiosk-autologin
setups use:

```bash
sed -i '/^auth.*pam_permit/i auth       optional    pam_gnome_keyring.so' /etc/pam.d/gdm-autologin
sed -i '/^session.*postlogin/i session    optional    pam_gnome_keyring.so auto_start' /etc/pam.d/gdm-autologin
```

Why Fedora Workstation Live doesn't show this: Firefox handles a
locked/unavailable Secret Service gracefully (in-memory fallback)
instead of calling `CreateCollection` the way Chromium-based Edge does.

### QEMU `screendump` is unreliable

Consistent diagonal RGB-striping corruption in `screendump` PPM
captures, even when the guest is paused. The real GTK window is fine.
**Lesson: don't trust `screendump` for pixel-level verification** -
use it only for coarse state checks, prefer direct screenshots of the
real QEMU window.

### Live-session disk space ("only 2GB")

With `-m 4096` and no persistent overlay, dracut's default live-image
writable overlay is a RAM-backed tmpfs - 4GB RAM lands on ~2GB writable
space, which is expected. Key facts from reading dracut and lorax source:

- `rd.live.overlay.size=` is an apparent/sparse size, not a RAM
  reservation. Raising it does nothing for a RAM-constrained VM.
- `livemedia-creator --overlay-size` **does not exist** as a flag.
- The real constraint is GNOME's ~1.5-2GB footprint eating most of 4GB.

Fix: bumped test VM RAM to 8GB in `scripts/qemu-test-live-iso.sh`, and
added `--extra-boot-args "rd.live.overlay.overlayfs=1"` to the GH
Actions `livemedia-creator` invocation (OverlayFS instead of
DM-snapshot - still RAM-bounded but fails softer).

### Flathub not configured

`flatpak` was in `%packages` but nothing added the Flathub remote. Fix:

```
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

## Plymouth, dark mode, dock/launcher polish

- Plymouth `script`-plugin theme from `AzureLinuxLogo.png`, `cp`'d from
  `/workspace` in `%post --nochroot`. `plymouth-set-default-theme
  azurelinux` (no `-R`) in chrooted `%post` - lorax rebuilds the initrd
  after `%post`, so it picks up the theme choice on its own.
- Console noise before splash (Device Mapper multipath warnings) fixed
  at source: `/etc/dracut.conf.d/no-multipath.conf`.
- Always-on dark mode via dconf (`color-scheme='prefer-dark'`,
  `gtk-theme='Adwaita-dark'`), user-overridable default.
- `.desktop` launchers for `edit` and PowerShell (real icons from their
  upstream repos), plus a `.NET` launcher.
- Plymouth splash briefly drops to console text before GDM - the
  well-known virtio-gpu KMS driver mode-switch flicker. Mitigated with
  `/etc/dracut.conf.d/early-kms.conf` (`add_drivers+=" virtio_gpu "`).

## Standing conventions for this repo

- Public repo (`sirredbeard/azurelinux-desktop`). Git history kept
  to a single squashed commit, force-pushed.
- Only one kickstart: `kickstart/azurelinux-desktop-live.ks`.
- Default live user is `liveuser` (from `livesys-scripts`, hardcoded).
- `pykickstart` is the fast kickstart syntax check before committing.
- Failed GH Actions runs get deleted after their errors are diagnosed.

## Runs 4-5: `mdatp` broke the build

`mdatp` (Microsoft Defender) started appearing as a transitive
dependency from a Microsoft repo. Its postinstall scriptlet can't work
in a dirinstall chroot (`No such file or directory:
'/usr/sbin/load_policy'`). A repo-level `--excludepkgs=mdatp` on
`ms-prod` didn't work because `mdatp` was resolving from a different
repo entirely. Fix: use `%packages`'s `-mdatp` form, which excludes
regardless of source repo.

**Lesson**: reach for the `%packages` `-pkgname` exclude form first for
this class of problem, not repo-level `--excludepkgs=`.

## Session cleanup

- Moved stray `.log` files into `findings/logs/` with descriptive
  names, removed two confirmed-duplicate logs.
- Deleted stale `scripts/podman-test-azl4-fedora-full-desktop.sh`.
- `findings/final-package-list.txt` replaced with a real `rpm -qa` list
  extracted from the built ISO via `xorriso`/`unsquashfs`, uploaded as
  its own CI artifact (`azurelinux-desktop-live-package-list`).
- `reference/azl-installer/` files confirmed byte-identical to
  upstream's `base/images/vm-iso-installer/` via `diff`; added
  `README.md` with provenance and pinned commit link.

## Run 6 fixes

- `LICENSE` (MIT) with full third-party attribution section.
- Grub menu defaults changed: `default="0"` (boot first, not "Test
  media"), `timeout=2` (not 60). Patched via sed on lorax's own grub
  templates before `livemedia-creator` runs.
- Removed `/etc/os-release` `PRETTY_NAME` override entirely.
- Suppressed anaconda-live's "Welcome" popup and "Install to Hard
  Drive" launcher (`rm -f` the `.desktop` files in `%post`).
- .NET CPU instruction set crash was a QEMU `-cpu qemu64` problem (no
  SSE4.2/POPCNT) - fixed with `-cpu host` in the test script.
- Plymouth dot throbber: replaced `Image.Text("*")` with real PNGs
  (`dot.png`, `dot-glow.png`) and `Math.Sin`-driven pulse animation.

## Run 7: `unsquashfs -e` does not mean "extract this path"

`unsquashfs -e <path>` does not take a path to extract - it takes the
name of a file that *itself contains* a list of paths. The correct way:
list the path as a plain trailing argument after the squashfs image
(`unsquashfs -d out squashfs.img var/log/azl-desktop-package-list.txt`).
Made the extraction step `continue-on-error: true` regardless.

## Run 8: dogfooding the download/test scripts

Three new bugs from actually downloading and booting with the published
scripts:

**GRUB menu read "Start Azure Linux Desktop 44".** `--releasever`'s
value leaking into the boot title. Fixed by sed-patching
`@PRODUCT@ @VERSION@` down to `@PRODUCT@` in lorax's grub templates.

**GDM login showed Fedora's "f" logo.** `fedora-logos` came in as a
weak dependency. Fixed: add `generic-logos` (Fedora's trademark-free
replacement) to `%packages`, exclude `-fedora-logos`.

**PolicyKit "Authentication Required" dialog for software updates.**
`gnome-software`/PackageKit's background update-check hits `auth_admin`
polkit, which is a dead end because `liveuser` has no password. Fixed
with a polkit JS rule granting `org.freedesktop.packagekit.*` to local,
active, wheel-group subjects.

## Release workflow

`release-live-iso.yml` uses `$(date -u +%Y.%m.%d)` tags, one per UTC
day. `softprops/action-gh-release@v2`'s `overwrite_files` defaults to
`true`, so same-day rebuilds replace assets in place. Made this explicit
in the workflow with a comment.

## Package sourcing ratio: "mostly Fedora" and the claw-back

After switching from `priority=` to `cost=` (to fix a
`grub2-efi-x64-cdboot` conflict - see
`gh-actions-installer-iso-build.md`), the real installed package
database showed: **1,177 packages total, 60 from Azure Linux, 1,100
from Fedora, 17 Microsoft/GitHub** - including kernel, glibc,
systemd, and NetworkManager. `cost=` only tie-breaks identical NEVRAs,
it doesn't shadow repos like `priority=` does.

This was fixed with a per-package `excludepkgs` on the Fedora repos -
see `package-sourcing-clawback.md` for the full investigation. Result:
**171 Azure Linux, 986 Fedora, 16 other, 1,173 total.**

## Disk-image build: the full bug chain (bugs 1-7)

The qcow2/VHDX disk-image build used `livemedia-creator --make-disk` in
the same workflow. It hit seven distinct bugs before working. Worth
documenting the whole chain because `--make-disk --no-virt` inside a
container is an unsupported path (lorax's own docs say it won't work in
a mock due to partitioned disk images), and this repo is, as far as we
can tell, the only public project attempting it.

### Bug #1: `--disk-image` was the wrong flag

`--disk-image` points `livemedia-creator` at an *existing* disk image to
reinstall onto, not an output path for `--make-disk`. `--image-size`
also isn't a real flag - argparse's prefix matching silently accepted it
as `--image-size-align`. Fix: use `--image-name` and let the kickstart's
own partition sizes determine the disk size.

Log: `findings/logs/live-disk-image-build-failure-2026-07-18.log`.

### Bug #2: `umount of /tmp failed (32)`

`--make-disk` runs anaconda with `--image` (not `--dirinstall`), which
bind-mounts `/tmp` into the target root. In a `--privileged` container
with shared mount propagation, anaconda's teardown unmount tries to
propagate to a peer group it never asked for. Fix: `mount
--make-rprivate /` before `livemedia-creator` runs.

### Bug #3: `kpartx` needs udevd

`kpartx -a -s` depends on live udev to create partition device nodes.
A bare container has no init/udevd. Fix: install `systemd-udev`, start
`systemd-udevd --daemon`, then `udevadm trigger`/`udevadm settle`.

### Bug #4: `--boot-drive=vda` invalid in `--no-virt`

`--no-virt` never creates virtio devices - blivet discovers the disk
image directly, never as `vda`. Fix: drop `--boot-drive=` entirely.

### Bug #5 - RESOLVED: `verify_bootloader()` "You have not created a bootable partition"

This one took the longest to trace. Logs:
`findings/logs/live-disk-image-build-failure-5b-2026-07-18.log`,
`findings/logs/live-disk-image-storage-log-run29638688163.log`,
`findings/logs/disk-build-run-29641568473-storage-log-excerpt.log`.

Anaconda's `verify_bootloader()` fires when `stage1` is found but
`stage2_device` is empty. `stage2_device` comes from
`storage.boot_device`, which is `mountpoints.get("/boot",
mountpoints.get("/"))`. Two independent gates made it fail:

**Gate 1: EFI-vs-BIOS misdetection.** `blivet.arch.is_efi()` just
checks `os.path.exists("/sys/firmware/efi")`. Our privileged container
shares the GitHub runner's UEFI kernel, so this path exists even though
our kickstart (at the time, matching lorax's own `fedora-minimal.ks`)
laid out a BIOS/MBR disk. Documented upstream in `weldr/lorax#1262`.
Fix: mount an empty tmpfs over `/sys/firmware` before
`livemedia-creator` runs.

**Gate 2: xfs module not loaded.** `DeviceTree.mountpoints` only
includes devices whose `format.mountable` is `True`. `FS.mountable`
checks `/proc/filesystems`, which blivet snapshots once at **import
time**. The Ubuntu runner kernel never autoloads xfs, so at blivet
import time xfs isn't in `/proc/filesystems`, `mountable` returns
`False` for the root partition, and `boot_device` comes back `None`.
Fix: `sudo modprobe xfs` on the runner **before** the container starts.

**Lesson**: a privileged container sharing the host kernel inherits
kernel-global state (`/sys/firmware`, loaded modules,
`/proc/filesystems`) that can silently disagree with what the
kickstart expects. Treat platform assumptions as explicit CI
dependencies. Also: a CI job reporting one unchanged error after a fix
doesn't mean the fix didn't work - check what changed *underneath*
(the biosboot partition started being scheduled) before concluding.

### Bug #6: `grub2-install` refuses BIOS install inside EFI chroot

With bug #5's EFI-mask applied in the outer mount namespace but `mount
--make-rprivate /` preventing it from propagating into anaconda's own
bind-mounted `/sys` inside the chroot, `grub2-install`'s own
platform detection re-detected EFI independently.

**Decision: stop fighting the runner's real firmware.** Switched to a
genuine UEFI/GPT disk image. The GitHub runner is UEFI, Azure Gen2 VMs
are UEFI, there was never a reason to force BIOS/MBR. This also
sidesteps bug #6 entirely: `EFIGRUB` never calls `grub2-install` at
all - `EFIBase.install()` only calls `efibootmgr()`, which no-ops for
image/directory installs (`if not conf.target.is_hardware: return`).

Removed the `/sys/firmware` mask and BIOS-only sed rules. The disk-image
kickstart now uses plain `bootloader` and untouched `reqpart`. The xfs
module fix still applies regardless.

### Bug #7 - RESOLVED: `efibootmgr()` returns `""` instead of `0`

After switching to UEFI/GPT, everything worked (grub config generated,
`grub2-set-default` succeeded) until: `Failed to set new efi boot
target. This is most likely a kernel or firmware bug.`

Root cause: **a Fedora packaging bug, not our environment.** The
the installed Anaconda package has older, pre-fix code where
`efibootmgr()`'s skip path always returns `""` (a string), not `0`
(an int). `_add_single_efi_boot_target()` does `if rc != 0: raise` -
and in Python, `"" != 0` is always `True` (cross-type comparison), so
it raises every time this skip path runs. The upstream `main` branch
already has the fix (pops `capture` kwarg first, returns `"" if
capture_expected else 0`); it just hasn't been backported to Fedora's
package yet.

Fix: `scripts/patch-anaconda-efi-skip-bug.py`, a small idempotent
script that patches the installed `efi.py` to match upstream. Asserts
on exact source text so a future Fedora update that backports the real
fix fails loudly instead of leaving stale patches. Verified in podman
end-to-end before touching CI.

**Lesson**: when a CI failure doesn't match upstream's latest source,
check the **exact installed package version's actual source** (pull the
NEVRA into a disposable container and read its files), not just
whatever's newest on GitHub.

### Process note: `actionlint` needs `shellcheck` installed

`actionlint` only checks `run:` shell with `shellcheck` if
`shellcheck` is on `PATH` - otherwise it silently skips and exits 0.
**Always confirm `shellcheck` is installed** before trusting a clean
`actionlint` run.

## Disk image confirmed to genuinely boot

CI run `29644221313` produced the first fully successful disk-image
build. Verified two ways:

1. **Static**: `qemu-nbd` showed a GPT with a 500MB ESP
   (`EFI/BOOT/BOOTX64.EFI`, `grub.cfg`) and 16GB xfs root (real Azure
   Linux kernel `6.18.31-1.5.azl4.x86_64`).
2. **Boot**: `scripts/qemu-test-disk-image.sh` (OVMF/UEFI, serial
   console, `-snapshot`) booted through shim→grub→kernel→systemd→GDM,
   no errors.

### Root partition doesn't grow to fill the 64G qcow2

The qcow2 is resized to 64G after installation, but the kickstart's
`part / --size=16384 --grow` only grew to the install-time disk size
(~16GB + ESP pad). ~48GB left as permanently unused space.

Fix: `azl-growroot.service` (oneshot, runs once via
`ConditionPathExists=!/var/lib/azl-growroot.done`), using
`cloud-utils-growpart` + `xfs_growfs` (both real Azure Linux 4.0 beta
packages, no cloud-init dependency). The script resolves the root device
dynamically (`findmnt`/`lsblk`/`/sys/class/block/*/partition`) instead
of hardcoding device names, since the same qcow2 gets converted to
VHDX/VDI/VMDK under different hypervisors. Only enabled on the
disk-image variant (the live ISO's root is read-only squashfs).

### Bug: `azl-growroot.service` was never actually enabled

The `sed` rule inserted `systemctl enable azl-growroot.service`
*before* the unit file's own `cat > ... << 'EOF'` block had run.
`systemctl enable` needs the file to already exist. Fix: placed a
sentinel comment (`# AZL_GROWROOT_ENABLE_MARKER`) right *after* the
unit file creation, and the sed rule substitutes that marker.

**Lesson**: when using `sed` to enable a systemd unit created in the
same generated script, anchor the enable line to a marker *after* the
unit file's creation, not to a nearby unrelated line.

### Bug: VHDX converted from pre-resize raw image

The VHDX conversion read from the original raw `.img` (16.5GB), not the
resized qcow2 (64GB). `qemu-img resize` only works on qcow2 - VHDX,
VDI, and VMDK don't support post-conversion resize (confirmed
empirically: `qemu-img: Image format driver does not support resize`).
Fix: convert from the already-resized qcow2, not the raw image.

### Both fixes confirmed working (CI run 29645743900)

- VHDX: `virtual size: 64 GiB` (was 16.5GB).
- Growroot: serial log shows the service starting/finishing during boot.
  Root partition grew from 16GB to 63.5GB, xfs filesystem reports 64G
  total. `azl-growroot.done` stamp file present.

## Split disk-image jobs + VDI/VMDK formats

- `build-disk-image` now only produces the base qcow2.
- `build-vhdx`, `build-vdi`, `build-vmdk` are independent jobs, each
  `needs: build-disk-image`, downloading its qcow2 artifact and running
  one `qemu-img convert`. None touch the Fedora container container or anaconda.
- Each format has its own `workflow_dispatch` toggle.
- All three convert from the resized qcow2, never from raw - same
  lesson as the VHDX bug above.
- Updated `release-live-iso.yml` to include all four disk-image formats.

**Open**: VDI/VMDK verified locally with `qemu-img info` (correct
size/format) but not boot-tested (no VirtualBox/VMware installed).

## Shrinking the disk-image release assets

Investigated why VMDK and VHDX came out different sizes (fewer/more
1900M split parts) for what's the same guest content converted from the
same source qcow2. Confirmed via `qemu-img convert --help`: `-c`/
`--compress` is qcow/qcow2-only - VHDX, VDI, and VMDK have no
compression option at the qemu-img level at all, full stop. The size
difference between them comes from sparse-block granularity, not
compression: VHDX's default dynamic-disk `block_size` (0 = auto-
calculate) lands on a large block for a disk this size, so any block
touched at all gets fully realized even if mostly empty; VMDK's default
`monolithicSparse` subformat uses a much smaller grain, wasting far
less space for the same actual data.

Four changes made based on this, all verified syntactically against
synthetic qcow2/vhdx/vdi/vmdk files with real qemu-img (v11.0.0) before
touching CI:

1. **qcow2**: added `-o compression_type=zstd` to the existing `-c`
   conversion. zstd is usually a modest improvement over qcow2's zlib
   default at comparable or better speed - confirmed the flag is
   accepted and produces a valid qcow2 (`qemu-img info` reports
   `compression type: zstd`). Only needs QEMU >= 5.1 to read, which is
   a non-issue since only this project's own QEMU-based tooling ever
   opens the qcow2 directly.
2. **VHDX `block_size`**: was left at the default (0/auto). Set to `-o
   subformat=dynamic,block_size=2M` (min is 1M, max 256M) - a much
   finer allocation granularity than whatever auto was choosing,
   closing most of the gap with VMDK's naturally smaller grain.
3. **`-S 4k` (sparse-size) on all three conversions**: tightens the
   zero-run-length threshold qemu-img uses to treat bytes as a hole on
   output, instead of leaving it at qemu-img's own default.
4. **`virt-sparsify --in-place`** on the qcow2, right after the resize
   step, before any of the three conversions read it. Anaconda's own
   install/cleanup (dnf cache, package `%post` scripts, journal/temp
   file churn) leaves non-zero garbage in what's logically free space -
   none of the above (sparse detection, `-c`/zstd, `-S`) can shrink
   data it can't recognize as zero. `--in-place` avoids needing a
   second temporary copy of a 64G image; it rewrites already-allocated
   clusters to zero in place instead. Needs `libguestfs-tools-c`
   (installed inside the same privileged Fedora container container that
   already builds the qcow2). GitHub-hosted runners have no KVM (see
   this repo's own runner notes elsewhere in this file), so libguestfs
   falls back to its own TCG appliance for this - slower, but
   `build-disk-image` already carries a 180-minute job timeout with
   room to spare.

**7z compression for VHDX/VDI/VMDK**: since none of the three support
compression at the qemu-img level, `build-vhdx`/`build-vdi`/`build-vmdk`
now each run `7z a -mx=9` on their own conversion output and upload the
`.7z` instead of the raw disk image - a real size win for these three,
not a redundant second pass, since the source data was genuinely
uncompressed going in (unlike the ISO's squashfs or qcow2's own -c/
zstd). `release-live-iso.yml`'s `release-vhdx`/`release-vdi`/
`release-vmdk` jobs now look for `*.7z` rather than the raw disk image
before splitting. `Get-AzureLinuxDesktop.ps1` decompresses the `.7z`
after reassembly/checksum - see its own comments for the native-7z-
first, 7Zip4Powershell-fallback-on-Windows-only approach (confirmed by
direct testing that 7Zip4Powershell throws `DllNotFoundException` on
`kernel32.dll` under Linux/macOS pwsh - it's a Windows-only P/Invoke
wrapper around 7-Zip's own DLLs, despite being a "PowerShell" module).

**Not changed**: VMDK's `monolithicSparse` subformat stays as-is rather
than switching to `streamOptimized` (which would add real qemu-img-
level compression) - `streamOptimized` trades away the broad VMware
Workstation/Player compatibility `monolithicSparse` was chosen for in
the first place, and 7z compression on top of `monolithicSparse` gets
most of the same size win without that trade-off.

**Open**: none of this has been through a real CI build yet as of this
writing - the qemu-img flag combinations are confirmed correct against
synthetic test images, but the actual size deltas on real guest data,
and `virt-sparsify`'s real runtime under TCG on a 64G image, are only
provable via a real release run.
