# GitHub Actions build

**Status:** historical CI lessons; still accurate for lorax/disk path

## Context

Workflow surface (keep this small):

| Workflow | Role |
| --- | --- |
| `release.yml` | Only human-facing publication path. Schedule = full wipe + all artifacts + canary test. Manual flags select live ISO, installer ISO, qcow2, VHDX, VDI, VMDK, canary, kmods, and optional `replace_release`. |
| `publish-desktop-kmods.yml` | GitHub Pages DNF kmod repo. Own nightly kernel-drift check; also called from `release.yml`. |
| `build-live-iso.yml` | Reusable only (called by `release.yml`) |
| `build-installer-iso.yml` | Reusable only (called by `release.yml`) |

Removed separate entry points: `nightly-release.yml`, `release-live-iso.yml`, `release-installer-iso.yml`, `canary-container.yml`, and any build-only dispatch path. Canary is no longer on a 3-day schedule; it builds and tests as part of `release.yml`. Local package-policy scripts under `scripts/` remain for ad-hoc checks. Builds run inside a Fedora stable container on `ubuntu-24.04` with `--privileged` Docker where needed.

## Workflow structure

### Live ISO and disk images (`build-live-iso.yml`)

- Runs inside `registry.fedoraproject.org/Fedora container` (`RELEASE_TYPE=stable`) on `ubuntu-latest`.
- Installs lorax/anaconda/livemedia-creator, checks out to `/workspace`, runs `livemedia-creator --no-virt` against `kickstart/azurelinux-desktop-live.ks`.
- `build-disk-image` job runs `livemedia-creator --make-disk --no-virt`; produces only the qcow2.
- `build-vhdx`, `build-vdi`, `build-vmdk`: independent jobs, each `needs: build-disk-image`, each downloads the qcow2 artifact and runs `qemu-img convert`. None touches Fedora container or Anaconda.
- Each format is selected by flags on `release.yml` (passed into this reusable workflow).

### Installer ISO (`build-installer-iso.yml`)

- Same container/runner shape. Runs `kiwi-ng system build` instead of `livemedia-creator`.
- `scripts/patch-kiwi-dnf5.sh` removes the obsolete `--disable-plugin=priorities,versionlock` argument from the installed KIWI Python backend before any build step.
- See `kiwi-ng-installer-build.md` for the full KIWI bug chain.

### Release workflows and artifacts

- **One workflow:** `release.yml` is the only human-facing publication
  path. Schedule wipes prior releases, mints a UTC-date tag, applies
  `.github/release-notes-template.md`, builds the full set, and uploads.
  Manual dispatch uses the same file with per-artifact flags plus optional
  `replace_release`.
- **No build-only dispatch.** `build-live-iso.yml` and
  `build-installer-iso.yml` are reusable only. Mid-run Actions artifacts
  still exist for debugging a job.
- **Download released artifacts:** `scripts/Get-AzureLinuxDesktop.ps1 -Live`
  or `-Install` (uses `/releases/latest`).
- **Download mid-run Actions artifacts:** `aria2c -x 16` with
  `--header="Authorization: Bearer $(gh auth token)"` against
  `https://api.github.com/repos/sirredbeard/azurelinux-desktop/actions/artifacts/<id>/zip`.
- **Concurrency:** live ISO, installer ISO, and qcow2 build in parallel.
  VHDX/VDI/VMDK convert from qcow2 afterward and stay 7z-compressed.
  Canary build+test runs beside the image builds. Each upload job is
  independent with `continue-on-error`. A canary miss must not block the
  installer; a live ISO miss must not block qcow2/VM uploads when those
  artifacts still exist.
- **Focused attach rule:** with `replace_release` off, `release.yml` calls
  `scripts/resolve-release-tag.sh`, prefers the latest existing release, and
  only creates a dated tag plus notes when none exists. Asset uploads use
  `gh release upload --clobber`.
- **Why the attach rule exists:** a manual installer dispatch finished at
  2026-08-04T02:13Z (still 2026-08-03 evening US EDT). It used `date -u`,
  created empty-notes release `2026.08.04` with only installer parts, and
  left live/disks on `2026.08.03`. `/releases/latest` became incomplete.
  Fix: one workflow, one current release, focused runs clobber in place.
  After deleting a mistaken newer tag, re-mark the surviving release with
  `gh release edit TAG --latest` if `/releases/latest` 404s. New creates
  set `make_latest: true`.

### Preflight workflow

- Package-policy canary is built and tested inside `release.yml` (GHCR publish + test). Local equivalents: `scripts/test-container-repos.sh`, `scripts/podman-test-azl4-fedora.sh`, `scripts/test-installer-runtime-resolve.sh`, `scripts/test-canary-container-local.sh`.

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
Evidence:
```
The disk image /workspace/live-disk-result/azurelinux-desktop-live.img is missing.
...
You have not created a bootable partition.
Installation Destination (Kickstart insufficient)
The following mandatory spokes are not completed:
Installation Destination.
```

**Bug 6 — `grub2-install` refuses BIOS install inside EFI chroot.** Resolved by the UEFI/GPT switch above. `EFIGRUB.install()` only calls `efibootmgr()`, which no-ops for image installs.

**Bug 7 — `efibootmgr()` returns `""` instead of `0` (Fedora packaging bug, now patched).**
`_add_single_efi_boot_target()` does `if rc != 0: raise`. In Python, `"" != 0` is always `True` (cross-type comparison). The installed Anaconda's `efi.py` has an older skip path that returns `""` (string) rather than `0` (int). Upstream `main` is already fixed. Workaround: `scripts/patch-anaconda-efi-skip-bug.py` — idempotent, asserts on exact source text so a future backport fails loudly.

**Bug 8 — EFI stub written to wrong vendor directory.**
The Anaconda profile defaulted to `efi_dir = fedora` even though AZL shim/grub place binaries in `EFI/azurelinux`. Fix: `scripts/configure-anaconda-efi-vendor.py` changes the profile setting with an exact-source guard.

**Bug 9 — `virt-sparsify --in-place` on compressed qcow2 erased guest data.**
Running sparsify after converting to compressed qcow2 left a tiny virtual disk with all-zero allocation. Fix: sparsify the **raw image** first (`LIBGUESTFS_BACKEND=direct virt-sparsify --in-place`), then convert to compressed zstd qcow2, then resize. Confirmed sequence:
```
virt-sparsify --in-place .../azurelinux-desktop-live.img
qemu-img convert -O qcow2 -c -o compression_type=zstd ...img ...qcow2
qemu-img resize ...qcow2 64G
```

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
- Delete failed/cancelled runs after the useful failure lines are copied into the matching `findings/*.md` topic file. Actions list stays useful.
- Nightly publishes live ISO, qcow2, VHDX, VDI, VMDK, installer ISO, and canary. For iterative debugging outside nightly, build only the formats you need. Derivative convert jobs must actually run (see `always()` note above) or release upload fails looking for missing artifacts.
- Canary uses its own concurrency group (`azurelinux-desktop-canary`), never the kmod Pages group.
- Canary GHCR path: `ghcr.io/sirredbeard/azurelinux-desktop/canary`. Built and tested from `release.yml` (full schedule or canary flag). No separate 3-day schedule.
- `release.yml` calls `build-live-iso.yml` **once** with the selected format flags (ISO and disk jobs already parallel inside that workflow). Do not call it twice for ISO vs disk; that was the spaghetti graph.

## References

Key failure signatures are inlined under the bug sections above (missing disk image path, bootable partition / Installation Destination, sparsify-before-convert sequence). First successful installer path later confirmed via KIWI Result files + published ISO.
- `kiwi-ng-installer-build.md` — KIWI-specific build chain
- `live-iso-installer-parity.md` — artifact parity, format conversion rules
- `asset-download-details.md` — superseded; download script flag reference preserved
- `local-build-environment-boundaries.md` — superseded; local SELinux boundary documented in `kiwi-ng-installer-build.md`