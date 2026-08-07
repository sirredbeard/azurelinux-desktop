# GitHub Actions build

**Status:** historical CI lessons; still accurate for lorax/disk path

## Workflow surface

Keep this small:

- `release.yml`: only human-facing publication path. Schedule = full wipe
  + all artifacts + canary test. Manual flags select live ISO, installer
  ISO, qcow2, VHDX, VDI, VMDK, canary, kmods, and optional
  `replace_release`.
- `publish-desktop-kmods.yml`: GitHub Pages DNF kmod repo. Own kernel-drift
  schedule; also called from `release.yml`.
- `build-live-iso.yml`: reusable only (called by `release.yml`)
- `build-installer-iso.yml`: reusable only (called by `release.yml`)

No separate build-only or canary-only workflow. Local package-policy
scripts under `scripts/` remain for ad-hoc checks. Builds run inside a
Fedora stable container on `ubuntu-24.04` with privileged Docker where
needed.

## Architecture decisions (resolved)

These are the durable product choices. Do not re-litigate without a
strong reason.

1. **Live ISO:** Lorax + `livemedia-creator --make-iso` driven by
   `kickstart/azurelinux-desktop-live.ks`. Nested live root is
   `--rootfs-type squashfs-ext4` (DM snapshot free space for Flatpak).
2. **Installer ISO:** KIWI-NG (`python3-kiwi`), adapted from Microsoft's
   Azure Linux installer path. Different tool on purpose.
3. **Disk images:** same live kickstart through
   `livemedia-creator --make-disk`, then `qemu-img convert` for
   VHDX/VDI/VMDK. **UEFI/GPT only.** BIOS/MBR was the wrong target and
   failed Anaconda `verify_bootloader()` on UEFI runners.
4. **No Image Customizer / losetup -P on GitHub-hosted runners.**
   Partition-scanning loop devices are broken there. That is why
   Microsoft's own Image Customizer CI uses self-hosted runners. This
   project does not.
5. **Convert from resized qcow2 only.** VHDX/VDI/VMDK do not support
   post-conversion resize. Never convert from the pre-resize raw image.
6. **Publication:** one workflow owns releases. Focused manual runs leave
   `replace_release` off and clobber only the assets they built. Schedule
   always replaces. Upload assets inside build jobs via
   `scripts/ci-upload-release-asset.sh`.

## Workflow structure (short)

### Live ISO and disk images (`build-live-iso.yml`)

- Fedora container + lorax/anaconda/livemedia-creator
- `build-disk-image` produces qcow2 only
- `build-vhdx` / `build-vdi` / `build-vmdk` download that qcow2 and convert
- Format flags come from `release.yml`

### Installer ISO (`build-installer-iso.yml`)

- Same container shape; `kiwi-ng system build`
- `scripts/patch-kiwi-dnf5.sh` removes obsolete DNF plugin args from the
  installed KIWI backend
- Details: `kiwi-ng-installer-build.md`

### Release attach rule

With `replace_release` off, `scripts/resolve-release-tag.sh` prefers the
latest existing release and only creates a dated tag when none exists.
Asset uploads use `gh release upload --clobber`. Avoid minting a new
UTC-date release that leaves `/releases/latest` incomplete.

Downloads:

- Released: `scripts/Get-AzureLinuxDesktop.ps1 -Live` / `-Install`
- Mid-run Actions artifacts: `aria2c` against the artifacts API with a
  bearer token

## Lessons (condensed)

Keep these; drop the blow-by-blow of each failed run.

- `grub2-efi-x64-cdboot` is required for Lorax EFI templates. Missing it
  silently skips EFI and fails later in xorrisofs.
- Exclude toxic transitive deps in `%packages` (`-mdatp`, and similar)
  when repo excludepkgs is not enough.
- `livemedia-creator --resultdir` must not already exist with contents.
  Log vendor snapshots under `build-meta/`, then copy next to the ISO.
- Derivative convert jobs need `if: always()` when the qcow2 job uses
  `continue-on-error: true`, still gated on qcow2 success. Otherwise
  convert jobs stay skipped and release upload fails.
- Pin the build container to Fedora stable. Prerelease containers drift
  mid-job.
- Start udevd before `kpartx` in disk builds. Make `/` rprivate before
  livemedia-creator to avoid umount teardown failures.
- Disk path: UEFI/GPT; `modprobe xfs` on the runner before the container
  so blivet sees xfs as mountable.
- Patch Anaconda EFI skip bug and efi_dir vendor when Fedora packaging
  returns `""` instead of `0` or defaults to `fedora` while we need
  `azurelinux` (guarded scripts under `scripts/`).
- Sparsify the **raw** image first, then convert to compressed zstd
  qcow2, then resize. Sparsify after compressed qcow2 wiped guest data.
- growroot enable must run after the unit file exists (sentinel marker).
- `actionlint` is silent on `run:` blocks without `shellcheck` on PATH.
- `workflow_dispatch` booleans arrive as strings `"true"` / `"false"`.
- Two-layer live ISO: extract package lists from inner `rootfs.img`, not
  the outer squashfs alone.
- Offline DNF solve: do not trust `dnf5 --assumeno` exit code alone;
  look for real resolver errors. Retry offline downloads with logged
  tails.

## Release asset format

Assets over GitHub's 2 GiB cap ship as split parts plus a `.sha256`
manifest. VHDX/VDI/VMDK also ship 7z-compressed. qcow2 uses
`-c -o compression_type=zstd`.

After successful live/installer builds, CI may commit
`findings/live-package-list.txt` and
`findings/installer-package-list.txt` via
`scripts/ci-commit-package-list.sh`.

## CI hygiene

- Re-run only the artifact that needs iteration. Cancel premature runs.
- After diagnosis, copy key lines into the matching `findings/*.md` and
  delete the run.
- Canary concurrency group is separate from kmod Pages.
- Call `build-live-iso.yml` once with the selected format flags. Do not
  call it twice for ISO vs disk.

## Related

- `kiwi-ng-installer-build.md`
- `live-iso-installer-parity.md`
- `flatpak-live-session-space.md`
