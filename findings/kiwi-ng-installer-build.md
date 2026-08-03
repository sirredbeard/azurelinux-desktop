# KIWI-NG installer build

**Status:** active installer path

## Context

The installer ISO uses KIWI-NG (`python3-kiwi`, `kiwi-ng system build`), matching the tool Microsoft's own Azure Linux installer ISO is built with. The description files are `kiwi/azl-desktop-installer.kiwi`, `kiwi/config.sh`, `kiwi/azl-install.ks.in`, and `kiwi/azl-install-encrypted.ks.in` — direct adaptations of `microsoft/azurelinux` `base/images/vm-iso-installer/`. The live ISO and disk images use Lorax/livemedia-creator. Do not conflate the two build paths.

## Known issues and root causes

### Container and binary issues

- **`kiwi-ng` binary name on Fedora.** Fedora's `python3-kiwi` installs the binary as `/usr/bin/kiwi-ng-3` (Python packaging suffix), not `kiwi-ng`. Use `command -v` fallback in the workflow.
- **`isomd5sum` required for `mediacheck="true"`.** Without it: `KiwiRuntimeError: Required tool implantisomd5 not found`. Add to the build container's package list.
- **`qemu-img` required.** KIWI-NG needs it to build the FAT-formatted EFI system partition image.
- **`e2fsprogs` required.** KIWI-NG needs `mkfs.ext4` for the ext4 disk image.
- **`mtools`/`mcopy` required.** Read KIWI-NG source before assuming the package list is complete; mcopy/mtools is needed and can fail silently without it.
- **Fedora container version: must be stable.** `fedora:45` is `RELEASE_TYPE=development` (daily-drifting prerelease). `dnf5 install` was replacing glibc/coreutils/rpm mid-container, causing `/workspace` bind-mount failures. Pin to `Fedora container` (`RELEASE_TYPE=stable`) in both `build-installer-iso.yml` and `build-live-iso.yml`.
- **`/workspace` mkdir race.** GitHub-hosted-runner/Docker bind-mount timing issue: run `mkdir -p /workspace` before `dnf5 install` (while the mount is fresh), with a retry loop.

### KIWI DNF5 compatibility

- **`--disable-plugin=priorities,versionlock` causes failures.** KIWI hard-codes this argument; current libdnf5 no longer ships either legacy plugin and treats unknown plugin names as a failed transaction. Fix: `scripts/patch-kiwi-dnf5.sh` removes that obsolete argument from the installed KIWI Python backend. Run after installing `python3-kiwi`, before `kiwi-ng system build`.
- **AZL dnf5 does not accept `-v`.** AZL's DNF5 does not accept the familiar `-v` flag (unlike Fedora's build). Use `--debugsolver` / `debuglevel=10` for verbose solver output. Log excerpt: `logs/installer-release-dnf-debug-29889193251.log`.

### Repository configuration

- **Fedora repo required in KIWI runtime for Plymouth.** KIWI's `<repository>` bootstraps the installer runtime with Azure Linux repos only by default. `plymouth`, `plymouth-plugin-script`, and `plymouth-plugin-label` are Fedora-supplied. Fix: add Fedora release repo at `priority=50` in the `.kiwi` runtime definition (Azure Linux repos at `priority=10`). Test script: `scripts/test-installer-runtime-resolve.sh` — resolved 426 packages including Fedora Plymouth. Log: `logs/installer-runtime-resolve-optionb-2026-07-22.log`.
- **`priority=` vs `cost=` in `config.sh`'s `dnf5 download`.** `priority=` is a hard shadow (locks onto higher-priority repo's candidate even if unresolvable); `cost=` only tie-breaks identical NEVRAs. Use `--setopt=<repo>.cost=` matching the live kickstart. Mixing them caused `grub2-efi-x64-cdboot`'s AZL dependency to be unresolvable.
- **Multilib i686/x86_64 conflict.** `dnf5 download --alldeps` pulls `libpeas1-gtk-...i686` alongside `.x86_64`, causing an unresolvable conflict. `--setopt=multilib_policy=best` doesn't help. Fix: `--arch=x86_64 --arch=noarch` (repeated flags; comma form `--arch=x86_64,noarch` fails with "Unsupported architecture").
- **RPMFusion must be in `config.sh`'s `dnf5 download` repo list.** `ffmpeg`/`gstreamer1-plugin-libav` require it; omitting it silently drops those packages from the offline repo.
- **Global `--exclude=` drops from all repos including Fedora.** Use per-repo `--setopt=<repo>.excludepkgs=`. See `anaconda-kickstart-patterns.md`.
- **`grub2-tools-extra` belongs in `EXTRA_REPO_PKGS`, not `INSTALL_PKGS`.** It's an Anaconda support package, not a target-install package. Its AZL version hard-requires an exact-version `grub2-tools-minimal` that's excluded; exclude the AZL copy too so the complete Fedora GRUB family is selected.
- **`nvme-cli` belongs in `EXTRA_REPO_PKGS`.** Blivet requires it for any NVMe install disk; Anaconda resolves it at install time even when kickstart `%packages` never lists it. Missing from the offline repo → `NonCriticalInstallationError: No match for argument: nvme-cli`. Package is in Azure Linux base. Details: `anaconda-nvme-cli-offline-repo.md`.

### Plymouth asset staging order

- **Stage theme files BEFORE calling `plymouth-set-default-theme`.** If the `azurelinux` theme directory doesn't exist when the selection command runs, it exits with `azurelinux.plymouth does not exist` and the build fails. Copy `.plymouth`, `.script`, logo PNG, and dot PNGs from the unpacked asset archive into `/usr/share/plymouth/themes/azurelinux/` first. Log: `logs/installer-release-runtime-plymouth-29890385508.log`.

### KIWI initramfs path

- **KIWI stores the boot initramfs at `/boot/x86_64/loader/initrd`**, not at `/images/pxeboot/initrd.img` (Lorax's path). Post-build verification that uses the Lorax path fails to find the initramfs. Log: `logs/installer-release-kiwi-initramfs-path-29891158562.log`.

### `grub_template.cfg` and `mediacheck`

- **`mediacheck="true"` in `.kiwi` has no effect when `grub_template.cfg` is provided.** The custom template overrides KIWI's auto-generated GRUB config entirely. To add a "Test this media" entry, add it manually to `grub_template.cfg` with `rd.live.check`. Also add `isomd5sum` to the KIWI package list — `dracut-live` alone does not pull it on Fedora 43; `rd.live.check` is handled by `dracut dmsquash-live`, which calls `checkisomd5` from `isomd5sum`. Azure Linux upstream's own installer ISO does not have a media check entry; this is a Fedora-ism carried deliberately.

### Bootstrap packages

- **`libselinux` and `libseccomp` must be explicit in `<packages type="bootstrap">`.** The bootstrap packages' `Requires` don't declare these as runtime dependencies even though their binaries dlopen/link against them. Without explicit entries, all 162 of 163 bootstrap packages install, then scriptlets fail with `error while loading shared libraries: libseccomp.so.2` / `libselinux.so.1`.

### Workflow scripting pitfalls

- **No apostrophes inside `bash -c '...'` single-quoted regions in the workflow.** Comments like `# kiwi-ng's EFI-fat-image builder` close the outer single-quote early, silently corrupting the shell script. Reword all comments to avoid apostrophes.
- **`@@PACKAGES@@` placeholder: comments must not contain the literal marker.** A comment in the kickstart template explaining the mechanism triggers `sed` on the wrong line. See `anaconda-kickstart-patterns.md`.

### Diagnostic artifact permissions

- **`upload-artifact` with recursive glob fails on KIWI's root-owned EFI directory.** `installer-result/**` patterns make the uploader traverse KIWI's image-root and fail with `EACCES` before publishing the logs. Restrict artifact globs to top-level result files and explicitly named log paths.

### Offline download reliability

- **`config.sh` download retry and diagnostics.** The offline target repository download is the longest, most network-dependent step. `config.sh` writes complete DNF output to an internal log, prints the last 200 lines on failure, and retries up to three times with short backoff. Permanent failures retain the actual DNF diagnostic in the Actions log instead of only KIWI's generic `config.sh failed` exception.

## Local build environment boundaries

- **SELinux labeling boundary.** KIWI invokes the target root's `setfiles`, but the host kernel validates each `security.selinux` xattr against the host's loaded policy. Some target policy types are unknown to the host policy, so `setfiles` fails (`setfiles: Could not set context for ...smartdnotify: Invalid argument`). This is a known host-vs-target relabeling boundary (SELinux issue 437, KIWI issue 2192, KIWI security troubleshooting docs). The GitHub Actions Docker environment (no host policy constraint) is the authoritative path for a release-quality, SELinux-labeled installer ISO. Do not weaken the hosted workflow to accommodate the local limitation.
- **`/dev` bind-mount fails locally.** KIWI can't bind-mount `/dev` into the privileged container in this local environment. The separate `scripts/test-installer-runtime-resolve.sh` (empty installroot + package download) validates the package transaction without that constraint.
- **Local validation rule.** The local build can validate ISO construction and a QEMU guest installation (installer boot path is permissive; installed target schedules its own relabel). It cannot validate the installer runtime's final SELinux labels. Use the hosted build for the complete artifact; validate its downloaded artifact in QEMU.
- **Root Podman needs `--cgroups=disabled`** on this host; privileged Podman bind-mounted outputs can be root-owned and require ownership repair.

## What didn't work

- **`fedora:45` container:** daily-drifting prerelease replaced glibc/rpm mid-container. Switched to stable `Fedora container`.
- **mkksiso against the real downloaded AZL ISO:** "Frankenstein stuff," abandoned. KIWI-NG is the correct path.
- **Image Customizer for disk images:** needs `losetup -P` (partition-scanning loop devices), confirmed broken on GitHub-hosted runners. Microsoft's own upstream CI uses self-hosted runners for this reason.

## Current state

First successful installer build: run `29625540225` (~3.1 GiB ISO). KIWI build is stable. Config.sh patches applied: `scripts/patch-kiwi-dnf5.sh`. Plymouth staging order correct. Both kickstart templates render to correct filenames matching `anaconda-launcher.sh`'s expectations. `EXTRA_REPO_PKGS` covers Anaconda support packages. `libselinux`/`libseccomp` explicit in bootstrap. Installer ISO verified 10/10 static checks, QEMU boot confirmed Anaconda TUI, interactive disk selection working.

## References

- `logs/installer-release-dnf-debug-29889193251.log` — DNF5 -v flag failure
- `logs/installer-release-kiwi-initramfs-path-29891158562.log` — wrong initramfs path
- `logs/installer-release-runtime-plymouth-29890385508.log` — Plymouth staging order failure
- `logs/installer-runtime-resolve-optionb-2026-07-22.log` — 426-package runtime resolve
- `logs/gha-run29625540225-installer-first-success.log` — first successful build log
- `local-build-environment-boundaries.md` — superseded by this file; retained for context
- `anaconda-kickstart-patterns.md` — %post, asset staging, storage directives
- `live-iso-installer-parity.md` — installer vs. live vs. installed system parity
- SELinux issue 437, KIWI issue 2192, KIWI security troubleshooting docs