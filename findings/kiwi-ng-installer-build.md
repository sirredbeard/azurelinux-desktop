# KIWI-NG installer build

**Status:** Active installer path

## Context

The installer ISO uses KIWI-NG (`python3-kiwi`, `kiwi-ng system build`),
matching the tool Microsoft's own Azure Linux installer ISO uses.
Description files live under `kiwi/`
(`azl-desktop-installer.kiwi`, `config.sh`, `azl-install.ks.in`,
`grub_template.cfg`, launcher, post scripts). They are adaptations of
`microsoft/azurelinux` `base/images/vm-iso-installer/`.

There is no separate `azl-install-encrypted.ks.in` in-tree. `config.sh`
duplicates the rendered kickstart for the launcher's second option.

The live ISO and disk images use Lorax/livemedia-creator. Do not
conflate the two build paths.

## Container and binary issues

* Fedora's `python3-kiwi` installs the binary as `/usr/bin/kiwi-ng-3`,
  not `kiwi-ng`. Use `command -v` fallback in the workflow.
* `isomd5sum` required for `mediacheck="true"`. Without it:
  `KiwiRuntimeError: Required tool implantisomd5 not found`.
* `qemu-img` required for the FAT EFI system partition image.
* `e2fsprogs` required for `mkfs.ext4`.
* `mtools`/`mcopy` required. Read KIWI source before assuming the
  package list is complete.
* Pin the build container to stable Fedora (`RELEASE_TYPE=stable`) in
  both installer and live workflows. A development Fedora tag replaced
  glibc/coreutils/rpm mid-container and broke `/workspace` bind-mounts.
* `/workspace` mkdir race: run `mkdir -p /workspace` before `dnf5
  install` (while the mount is fresh), with a retry loop.

## KIWI DNF5 compatibility

* `--disable-plugin=priorities,versionlock` causes failures. KIWI
  hard-codes this argument; current libdnf5 no longer ships either
  legacy plugin and treats unknown plugin names as a failed transaction.
  Fix: `scripts/patch-kiwi-dnf5.sh` removes that obsolete argument.
  Run after installing `python3-kiwi`, before `kiwi-ng system build`.
* AZL dnf5 does not accept `-v`. Use `--debugsolver` /
  `debuglevel=10` for verbose solver output.

```
Unknown argument "-v" for command "dnf5".
Offline repository download attempt 1 failed.
```

## Repository configuration

* Fedora repo required in KIWI runtime for Plymouth. KIWI's
  `<repository>` bootstraps with Azure Linux repos only by default.
  Plymouth packages are Fedora-supplied. Add Fedora release repo at
  `priority=50` in the `.kiwi` runtime definition (Azure Linux repos at
  `priority=10`). Test script:
  `scripts/test-installer-runtime-resolve.sh`.
* `priority=` vs `cost=` in `config.sh`'s `dnf5 download`: `priority=`
  is a hard shadow; `cost=` only tie-breaks identical NEVRAs. Use
  `--setopt=<repo>.cost=` matching the live kickstart. Mixing them
  caused `grub2-efi-x64-cdboot`'s AZL dependency to be unresolvable.
* Multilib i686/x86_64 conflict: `dnf5 download --alldeps` pulls i686
  alongside x86_64. Fix: `--arch=x86_64 --arch=noarch` (repeated flags;
  comma form fails with "Unsupported architecture").
* RPMFusion must be in `config.sh`'s `dnf5 download` repo list.
  `ffmpeg`/`gstreamer1-plugin-libav` require it.
* Global `--exclude=` drops from all repos including Fedora. Use
  per-repo `--setopt=<repo>.excludepkgs=`. See
  `anaconda-kickstart-patterns.md`.
* `grub2-tools-extra` belongs in `EXTRA_REPO_PKGS`, not `INSTALL_PKGS`.
  It is an Anaconda support package. Its AZL version hard-requires an
  exact-version `grub2-tools-minimal` that is excluded; exclude the AZL
  copy too so the complete Fedora GRUB family is selected.
* `nvme-cli` belongs in `EXTRA_REPO_PKGS`. Blivet requires it for any
  NVMe install disk. Details: `anaconda-nvme-cli-offline-repo.md`.

## Plymouth asset staging order

Stage theme files BEFORE calling `plymouth-set-default-theme`. If the
`azurelinux` theme directory does not exist when the selection command
runs, the build fails:

```
KiwiScriptFailed: config.sh failed with:
/usr/share/plymouth/themes/azurelinux/azurelinux.plymouth does not exist
```

Copy `.plymouth`, `.script`, logo PNG, and dot PNGs from the unpacked
asset archive into `/usr/share/plymouth/themes/azurelinux/` first.

## KIWI initramfs path

KIWI stores the boot initramfs at `/boot/x86_64/loader/initrd`, not at
`/images/pxeboot/initrd.img` (Lorax's path). Post-build verification
that uses the Lorax path fails:

```
xorriso : FAILURE : Cannot determine attributes of (ISO) source file
'/images/pxeboot/initrd.img' : No such file or directory
```

KIWI Result files still list `live_image: ...iso`. Assert the KIWI
loader path instead.

## grub_template.cfg and mediacheck

`mediacheck="true"` in `.kiwi` has no effect when `grub_template.cfg`
is provided. The custom template overrides KIWI's auto GRUB config.
Add a "Test this media" entry manually to `grub_template.cfg` with
`rd.live.check`. Also add `isomd5sum` to the KIWI package list.
`dracut-live` alone does not pull it. Azure Linux upstream's installer
ISO does not have a media check entry; this is a Fedora-ism carried on
purpose. See `installer-grub-test-media.md`.

## Bootstrap packages

`libselinux` and `libseccomp` must be explicit in
`<packages type="bootstrap">`. Bootstrap package Requires do not
declare these as runtime dependencies even though binaries link against
them. Without explicit entries, scriptlets fail with missing
`libseccomp.so.2` / `libselinux.so.1`.

## Workflow scripting pitfalls

* No apostrophes inside `bash -c '...'` single-quoted regions in the
  workflow. Comments like `# kiwi-ng's EFI-fat-image builder` close the
  outer single-quote early and silently corrupt the shell script.
* `@@PACKAGES@@` placeholder: comments must not contain the literal
  marker. See `anaconda-kickstart-patterns.md`.

## Diagnostic artifact permissions

`upload-artifact` with recursive glob fails on KIWI's root-owned EFI
directory. `installer-result/**` patterns make the uploader traverse
KIWI's image-root and fail with `EACCES` before publishing the logs.
Restrict artifact globs to top-level result files and explicitly named
log paths.

## Offline download reliability

The offline target repository download is the longest, most
network-dependent step. `config.sh` writes complete DNF output to an
internal log, prints the last 200 lines on failure, and retries up to
three times with short backoff. Permanent failures retain the actual DNF
diagnostic in the Actions log instead of only KIWI's generic
`config.sh failed` exception.

## Local build environment boundaries

* SELinux labeling boundary: KIWI invokes the target root's `setfiles`,
  but the host kernel validates each `security.selinux` xattr against
  the host's loaded policy. Some target policy types are unknown to the
  host policy, so `setfiles` fails. Known host-vs-target relabeling
  boundary (SELinux issue 437, KIWI issue 2192). GitHub Actions Docker
  (no host policy constraint) is the authoritative path for a
  release-quality, SELinux-labeled installer ISO. Do not weaken the
  hosted workflow to accommodate the local limitation.
* `/dev` bind-mount fails locally. KIWI cannot bind-mount `/dev` into
  the privileged container in this local environment. Use
  `scripts/test-installer-runtime-resolve.sh` (empty installroot +
  package download) to validate the package transaction without that
  constraint.
* Local validation rule: the local build can validate ISO construction
  and a QEMU guest installation. It cannot validate the installer
  runtime's final SELinux labels. Use the hosted build for the complete
  artifact; validate its downloaded artifact in QEMU.
* Root Podman needs `--cgroups=disabled` on this host; privileged
  Podman bind-mounted outputs can be root-owned and need ownership
  repair.

## What did not work

* Development Fedora container tags: replaced glibc/rpm mid-container.
  Switched to stable Fedora.
* mkksiso against the real downloaded AZL ISO: abandoned. KIWI-NG is
  the correct path.
* Image Customizer for disk images: needs `losetup -P`, confirmed broken
  on GitHub-hosted runners. Microsoft's own upstream CI uses self-hosted
  runners for this reason.

## Current state

First successful installer build: run `29625540225`. KIWI build is
stable. Config.sh patches applied via `scripts/patch-kiwi-dnf5.sh`.
Plymouth staging order correct. Kickstart templates render to filenames
matching `anaconda-launcher.sh`. `EXTRA_REPO_PKGS` covers Anaconda
support packages. `libselinux`/`libseccomp` explicit in bootstrap.
Installer ISO verified with static checks; QEMU boot confirmed Anaconda
TUI and interactive disk selection.

## Related

* `anaconda-kickstart-patterns.md`
* `live-iso-installer-parity.md`
* SELinux issue 437, KIWI issue 2192, KIWI security troubleshooting docs
