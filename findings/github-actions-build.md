# GitHub Actions build

**Status:** historical CI lessons; still accurate for lorax/disk path

## Context

Workflow surface (keep this small):

| Workflow | Role |
| --- | --- |
| `nightly-release.yml` | Flat full release: cleanup → kmods once → parallel live/installer/canary builds → parallel uploads |
| `release-live-iso.yml` | Manual focused live ISO + disk formats |
| `release-installer-iso.yml` | Manual focused installer ISO |
| `canary-container.yml` | Build, push, and test the GHCR canary (also every 3 days) |
| `publish-desktop-kmods.yml` | GitHub Pages DNF kmod repo |
| `build-live-iso.yml` | Reusable only (no dispatch) |
| `build-installer-iso.yml` | Reusable only (no dispatch) |

Removed: `preflight-non-gui.yml`, separate `test-container.yml`, nested nightly→release→build chains that exploded the Actions graph. Local package-policy scripts under `scripts/` remain for ad-hoc checks. Builds run inside a Fedora stable container on `ubuntu-24.04` with `--privileged` Docker where needed.

## Workflow structure

### Live ISO and disk images (`build-live-iso.yml`)

- Runs inside `registry.fedoraproject.org/Fedora container` (`RELEASE_TYPE=stable`) on `ubuntu-latest`.
- Installs lorax/anaconda/livemedia-creator, checks out to `/workspace`, runs `livemedia-creator --no-virt` against `kickstart/azurelinux-desktop-live.ks`.
- `build-disk-image` job runs `livemedia-creator --make-disk --no-virt`; produces only the qcow2.
- `build-vhdx`, `build-vdi`, `build-vmdk`: independent jobs, each `needs: build-disk-image`, each downloads the qcow2 artifact and runs `qemu-img convert`. None touches Fedora container or Anaconda.
- Each format has its own `workflow_dispatch` toggle.

### Installer ISO (`build-installer-iso.yml`)

- Same container/runner shape. Runs `kiwi-ng system build` instead of `livemedia-creator`.
- `scripts/patch-kiwi-dnf5.sh` removes the obsolete `--disable-plugin=priorities,versionlock` argument from the installed KIWI Python backend before any build step.
- See `kiwi-ng-installer-build.md` for the full KIWI bug chain.

### Release workflows and artifacts

- **Use release workflows for testable artifacts.** Release workflows (`release-live-iso.yml`, `release-installer-iso.yml`) publish to GitHub Releases; `Get-AzureLinuxDesktop.ps1` downloads directly. Build-only workflows produce Actions artifacts that require auth headers and zip extraction.
- **Download build-only artifacts:** `aria2c -x 16 --header="Authorization: Bearer <token>"` against `https://api.github.com/repos/sirredbeard/azurelinux-desktop/actions/artifacts/<id>/zip`.
- **Download released artifacts:** `scripts/Get-AzureLinuxDesktop.ps1 -Live` or `-Install`.
- `nightly-release.yml`: deletes all preceding GitHub releases, tags, and hybrid GHCR versions first, then calls all publication paths. One current set of artifacts.
- UTC-date tags (`$(date -u +%Y.%m.%d)`). Same-day rebuilds upsert into the same release via `softprops/action-gh-release@v2` with `overwrite_files: true`.

### Preflight workflow

- Package-policy canary is `canary-container.yml` (GHCR publish + test). Local equivalents: `scripts/test-container-repos.sh`, `scripts/podman-test-azl4-fedora.sh`, `scripts/test-installer-runtime-resolve.sh`, `scripts/test-canary-container-local.sh`.

## Known bugs and lessons from the build chain

### Live ISO bugs (runs 1–8+)

**`grub2-efi-x64-cdboot` required (not optional).** Lorax's `x86.tmpl` only builds `EFI/BOOT` + `images/efiboot.img` if it finds `boot/efi/EFI/*/gcdx64.efi` — which ships in `grub2-efi-x64-cdboot` specifically, not plain `grub2-efi-x64`. Missing it silently skips the EFI template section; `xorrisofs` fails later with `Cannot determine attributes of source file '.../EFI/BOOT'`. Not a dependency error; a silent omission.

**`mdatp` appeared as a transitive dep.** Its postinstall scriptlet hard-fails without `/proc` (no `/usr/sbin/load_policy`). Repo-level `--excludepkgs=mdatp` didn't work (resolved from a different repo). Fix: use `%packages -mdatp` (works regardless of source repo).

**`gnome-tour` and `malcontent-control` pulled as transitive deps.** Must be explicitly excluded with `-gnome-tour -malcontent-control` in `%packages`.

**`livemedia-creator --resultdir` must NOT already exist.** Argparse accepts it; the build fails immediately if the directory already has contents (`The results_dir (...) should not exist`). Writing `vendor-packages-latest.txt` into `live-result/` before `livemedia-creator` trips this. Fix: log the vendor snapshot under `build-meta/`, `rm -rf` the resultdir, run lmc, then copy the snapshot next to the ISO.

**Derivative VHDX/VDI/VMDK jobs need `if: always()` when `build-disk-image` sets `continue-on-error: true`.** Without `always()`, GHA skips `build-vhdx` / `build-vdi` / `build-vmdk` even after a successful qcow2 (run `30849555777`: inputs showed `build_vhdx: true`, qcow2 succeeded, convert jobs stayed `skipped`, release then failed with `Artifact not found: azurelinux-desktop-live-vhdx`). The convert jobs still gate on `needs.build-disk-image.result == 'success'`.

**`fedora-logos` came in as a weak dep.** GRUB menu read "Start Azure Linux Desktop 44" (`--releasever` value leaking into the boot title). Fix: add `generic-logos` to `%packages`, exclude `-fedora-logos`. (Subsequently revisited — both ISOs now use `fedora-logos` from the `anaconda-webui` chain; see `anaconda-kickstart-patterns.md`.)

**GRUB menu version leak.** `@PRODUCT@ @VERSION@` in lorax's grub templates leaked `--releasever`. Fix: sed-patch `@PRODUCT@ @VERSION@` to `@PRODUCT@` in lorax templates before `livemedia-creator` runs.

**`fedora:45` container instability.** Daily-drifting prerelease replaced glibc/coreutils/rpm mid-container, causing `/workspace` bind-mount failures. Fix: pin to `Fedora container` (`RELEASE_TYPE=stable`) in both live and installer workflows.

**`/workspace` mkdir race.** GitHub-hosted-runner/Docker bind-mount timing issue. Fix: run `mkdir -p /workspace` before `dnf5 install`, with a retry loop.

**`policycoreutils` missing from build container.** The live ISO build logged a nonfatal `missing /usr/sbin/load_policy` exception in anaconda's exit handler. Fix: add `policycoreutils` to the live ISO, disk-image, local qcow2, and test qcow2 build environments.

**`livesys_session` must be set.** `livesys-main`'s dispatch logic is a no-op when `livesys_session=""`. The kickstart must `sed -i 's/^livesys_session=.*/livesys_session="gnome"/' /etc/sysconfig/livesys`.

### Disk-image build bugs (bugs 1–9)

**Bug 1 — wrong flag.** `--disk-image` points `livemedia-creator` at an *existing* image to reinstall onto. Use `--image-name`; let kickstart partition sizes determine disk size.

**Bug 2 — `umount of /tmp failed (32)`.** `--make-disk` bind-mounts `/tmp` into the target root; teardown tries to propagate to a peer group it never asked for. Fix: `mount --make-rprivate /` before `livemedia-creator`.

**Bug 3 — `kpartx` needs udevd.** `kpartx -a -s` depends on live udev. Fix: install `systemd-udev`, start `systemd-udevd --daemon`, then `udevadm trigger`/`udevadm settle`.

**Bug 4 — `--boot-drive=vda` invalid in `--no-virt`.** No virtio devices in `--no-virt`. Drop `--boot-drive=` entirely.

**Bug 5 — `verify_bootloader()` "You have not created a bootable partition" (resolved by switching to UEFI/GPT).**
Two independent gates:
- *Gate 1: EFI-vs-BIOS misdetection.* `blivet.arch.is_efi()` checks `os.path.exists("/sys/firmware/efi")`. The privileged container shares the GitHub runner's UEFI kernel — this path exists. A BIOS/MBR kickstart layout then fails the bootloader check.
- *Gate 2: xfs module not loaded.* `blivet.FS.mountable` checks `/proc/filesystems`, snapshotted at blivet **import time**. The Ubuntu runner kernel never autoloads xfs; xfs isn't in `/proc/filesystems` at import; the root partition is not mountable; `boot_device` is `None`.
- Fix: `sudo modprobe xfs` on the runner before the container starts. Then: switch to UEFI/GPT (runner is UEFI, Azure Gen2 VMs are UEFI — BIOS was never the right target). This also resolves bug 6.
- Logs: `logs/live-disk-image-build-failure-2026-07-18.log`, `logs/live-disk-image-build-failure-5b-2026-07-18.log`, `logs/live-disk-image-storage-log-run29638688163.log`.

**Bug 6 — `grub2-install` refuses BIOS install inside EFI chroot.** Resolved by the UEFI/GPT switch above. `EFIGRUB.install()` only calls `efibootmgr()`, which no-ops for image installs.

**Bug 7 — `efibootmgr()` returns `""` instead of `0` (Fedora packaging bug, now patched).**
`_add_single_efi_boot_target()` does `if rc != 0: raise`. In Python, `"" != 0` is always `True` (cross-type comparison). The installed Anaconda's `efi.py` has an older skip path that returns `""` (string) rather than `0` (int). Upstream `main` is already fixed. Workaround: `scripts/patch-anaconda-efi-skip-bug.py` — idempotent, asserts on exact source text so a future backport fails loudly.

**Bug 8 — EFI stub written to wrong vendor directory.**
The Anaconda profile defaulted to `efi_dir = fedora` even though AZL shim/grub place binaries in `EFI/azurelinux`. Fix: `scripts/configure-anaconda-efi-vendor.py` changes the profile setting with an exact-source guard.

**Bug 9 — `virt-sparsify --in-place` on compressed qcow2 erased guest data.**
Running sparsify after converting to compressed qcow2 left a tiny virtual disk with all-zero allocation. Fix: sparsify the **raw image** first (`LIBGUESTFS_BACKEND=direct virt-sparsify --in-place`), then convert to compressed zstd qcow2, then resize. Log: `logs/local-disk-image-efi-and-sparsify-2026-07-20.log`.

### growroot service ordering bug

`sed` inserted `systemctl enable azl-growroot.service` *before* the unit file's `cat > ... << 'EOF'` block had run. Fix: place a sentinel comment (`# AZL_GROWROOT_ENABLE_MARKER`) immediately after the unit file creation; the sed rule substitutes that marker.

### VHDX converted from pre-resize raw image

VHDX was sourced from the original raw `.img` (16.5 GB), not the resized qcow2 (64 GB). VHDX/VDI/VMDK don't support post-conversion resize. Fix: always convert from the already-resized qcow2.

### `actionlint` silently skips `run:` blocks without `shellcheck`

`actionlint` only checks shell in `run:` blocks if `shellcheck` is on `PATH`. Without `shellcheck`, it exits 0 with no output. Always confirm `shellcheck` is installed before trusting a clean `actionlint` run.

### `workflow_dispatch` boolean inputs are strings

GitHub Actions `workflow_dispatch` boolean inputs arrive as the strings `"true"` / `"false"`, not booleans. Comparisons must use string equality.

### `unsquashfs -e` misuse

`unsquashfs -e <path>` takes a file containing a list of paths to extract, not a path to extract directly. Use the path as a plain trailing argument: `unsquashfs -d out squashfs.img path/to/file`.

### Installer CI failure sequence (summary)

See `kiwi-ng-installer-build.md` for the full KIWI bug chain. Key issues: `kiwi-ng-3` binary name, `isomd5sum` required, `python3-kiwi` DNF5 compat patch, Fedora repo needed for Plymouth runtime, `--arch=x86_64 --arch=noarch` (repeated, not comma-joined), `EXTRA_REPO_PKGS` for Anaconda support packages, `libselinux`/`libseccomp` in bootstrap, `@@PACKAGES@@` in template comments, apostrophes in `bash -c '...'` regions.

### Offline download retry and diagnostics

`config.sh` writes complete DNF output to an internal log, prints the last 200 lines on failure, and retries the offline repo download up to three times with short backoff. The workflow also prints the last 500 lines of `kiwi-build.log` before marking the job failed. `dnf5 --assumeno` exits nonzero after a successful solve (user declined transaction) — validate by checking for explicit resolver error strings, not exit code.

## Release asset format

Every release asset runs over GitHub's 2 GiB per-asset cap, so each ships as split parts (`<name>.split.00.part`, `.01.part`, …) plus a `<name>.sha256` manifest. VHDX/VDI/VMDK also ship 7z-compressed (no native compression at the `qemu-img` level; `qemu-img -c` is qcow2-only).

**`Get-AzureLinuxDesktop.ps1`:** downloads parts with `aria2c` (15 connections) if found on PATH, falls back to `Invoke-WebRequest`. For 7z step: tries native `7z`/`7zz`/`7za` first; on Windows falls back to `7Zip4Powershell` module. `7Zip4Powershell` is Windows-only (P/Invoke wrapper around 7-Zip DLLs); it throws `DllNotFoundException` on Linux/macOS pwsh.

**qcow2 compression:** `-c -o compression_type=zstd`. Requires QEMU ≥ 5.1 to read; irrelevant since only this project's own tooling opens the qcow2.

**VHDX block_size:** `subformat=dynamic,block_size=2M` (tighter allocation granularity than the auto-calculated default, reducing size gap vs. VMDK).

**Sparse threshold:** `-S 4k` on all three non-qcow2 conversions.

### Live package-list artifact path (fixed 2026-08-02)

`build-live-iso.yml` uploads `azurelinux-desktop-live-package-list` from
`live-result/final-package-list.txt`. The extract step used to run
`unsquashfs … var/log/azl-desktop-package-list.txt` on
`LiveOS/squashfs.img`. That fails: the squashfs only contains
`LiveOS/rootfs.img` (ext4). The list file is inside the rootfs and is
present on the ISO (confirmed on release `2026.08.02` live ISO).

Fix: unsquash `LiveOS/rootfs.img`, loop-mount it read-only, copy
`var/log/azl-desktop-package-list.txt`. Extract failure fails the job
(list is required).

### Auto-commit package lists

After a successful live or installer ISO build, CI runs
`scripts/ci-commit-package-list.sh` and pushes:

- `findings/live-package-list.txt` (live ISO rootfs list)
- `findings/installer-package-list.txt` (installer runtime `rpm -qa`)

Both build workflows use `contents: write` for that push. Artifact upload
stays in place as a backup. Concurrent live + installer finishes rebase
and retry on push. Builds are `workflow_dispatch` / `workflow_call` only,
so the bot commit does not re-trigger an ISO build.

## CI hygiene

- Only re-run the specific build (ISO vs disk images, and within disk images the specific format) that actually needs iterating. Cancel premature runs immediately.
- Delete failed/cancelled runs after their relevant log excerpt is retained in `findings/logs/`. Actions list stays useful.
- Nightly publishes live ISO, qcow2, VHDX, VDI, VMDK, installer ISO, and canary. For iterative debugging outside nightly, build only the formats you need. Derivative convert jobs must actually run (see `always()` note above) or release upload fails looking for missing artifacts.
- Canary uses its own concurrency group (`azurelinux-desktop-canary`), never the kmod Pages group.
- Canary GHCR path: `ghcr.io/sirredbeard/azurelinux-desktop/canary`. Schedule: every 3 days plus nightly and manual.
- Nightly calls `build-live-iso.yml` **once** with all format flags (ISO and disk jobs already parallel inside that workflow). Do not call it twice for ISO vs disk; that was the spaghetti graph.

## References

- `logs/live-disk-image-build-failure-2026-07-18.log` — bug 1 disk-image wrong flag
- `logs/live-disk-image-build-failure-5b-2026-07-18.log` — bug 5 storage log
- `logs/live-disk-image-storage-log-run29638688163.log` — blivet EFI/xfs debug
- `logs/disk-build-run-29641568473-storage-log-excerpt.log` — storage debug excerpt
- `logs/local-disk-image-efi-and-sparsify-2026-07-20.log` — bug 9 sparsify sequence
- `logs/gha-run29625540225-installer-first-success.log` — first successful installer build
- `kiwi-ng-installer-build.md` — KIWI-specific build chain
- `live-iso-installer-parity.md` — artifact parity, format conversion rules
- `asset-download-details.md` — superseded; download script flag reference preserved
- `local-build-environment-boundaries.md` — superseded; local SELinux boundary documented in `kiwi-ng-installer-build.md`