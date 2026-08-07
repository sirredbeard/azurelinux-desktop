# Evaluate EROFS for the live ISO

**Status:** research only (issue #4). No build change yet.
**Issue:** https://github.com/sirredbeard/azurelinux-desktop/issues/4

## What this is about

Fedora moved live media from SquashFS to EROFS. We still build the live
ISO with Lorax/`livemedia-creator` and `--rootfs-type squashfs-ext4`.
The question is whether matching Fedora is worth it here: size, boot
feel, CI time, and how much of our tooling has SquashFS baked into the
name.

Installer ISO stays out of scope. KIWI still uses `flags="dmsquash"`.
Leave it alone unless we open a separate evaluation.

## What we do today

Live path (`.github/workflows/build-live-iso.yml`):

- Build container installs `squashfs-tools`
- `livemedia-creator ... --rootfs-type squashfs-ext4`
- ISO layout:

```text
LiveOS/squashfs.img          # outer SquashFS
  └── LiveOS/rootfs.img      # inner ext4
```

Workflow comments already note large intermediate rootfs pressure on the
runner, then a multi-GB squash. Package-list CI and
`scripts/validate-live-iso*.sh` extract with `xorriso`/`7z` +
`unsquashfs` and then loop-mount the inner ext4.

Installer path (`kiwi/azl-desktop-installer.kiwi`): `flags="dmsquash"`.
Different tool, different artifact. Not part of this switch.

## What Fedora did and why

Fedora Change: EROFS for Live Media (owners Neal Gompa, Dusty Mabe).

Reasons they give:

1. EROFS is still moving. SquashFS is stable and mostly frozen.
2. Random reads matter more than bulk sequential. Live desktops open
   lots of small files. EROFS tends to decompress smaller aligned
   chunks.
3. Build time. Their published KDE live numbers: SquashFS+XZ ~15.4 min
   compress vs EROFS+LZMA with fragment packing ~9.6 min; image size
   essentially a wash.
4. Downstream alignment. RHEL-class live media moving the same
   direction.
5. Tooling already there. Lorax accepts `--rootfs-type erofs`. Dracut
   gained live EROFS support in the v103 line. `erofs-utils` ships
   `mkfs.erofs`.

Typical Fedora-style mkfs flags from the change write-up:

```text
mkfs.erofs -zlzma,6 -Eall-fragments,fragdedupe=inode -C1048576
```

We do not need to hand-invoke that if Lorax owns the image.

## Cost / benefit for this repo

### Benefit

- Live boot / app open feel: better random read behavior vs large-block
  SquashFS; more noticeable on USB and slow disks than on NVMe
  (medium confidence; we have not timed our ISO)
- CI compress step: on the order of Fedora's ~30-40% faster compress
  phase for a big desktop root (medium)
- ISO size: near parity; possible small win with fragment dedupe
- Maintenance: track Fedora live layout instead of being the odd
  SquashFS holdout (soft benefit)
- Nested layout: Lorax EROFS live is often a flatter root image (no
  outer squash wrapping inner ext4)

### Cost

- Workflow flag + packages: small. Swap `--rootfs-type`, install
  `erofs-utils`
- Validate / package-list scripts: real but bounded. Every `unsquashfs`
  / `LiveOS/squashfs.img` assumption breaks. Fix paths and use
  `mount -t erofs` or `fsck.erofs` extract
- Dracut / live cmdline: must smoke-test. Confirm `rd.live.*` still
  matches and that any `patch-dracut-livenet-hook.sh` assumptions still
  hold
- AZL dracut on the installed system: low for live-only. Spot check: AZL
  beta has dracut above the v103-era live EROFS line. Live boot uses the
  Lorax-built initrd anyway
- Installer ISO: none if we keep scope (KIWI dmsquash unchanged)
- Risk of a bad first landing: medium until one green live build + QEMU
  boot

### What does not improve much

- Intermediate large rootfs on the runner. Compression format does not
  remove Anaconda/Lorax's need for a full tree before packing.
- Disk image (`--make-disk`) path. Separate from live rootfs type.
- Guest agent / kmod / GNOME issues. Unrelated surface.

## Practicality

Lorax in our Fedora build image already speaks `--rootfs-type erofs`.
The mechanical product change is small. The real work is:

1. One experimental live workflow (or a temporary branch flag) building
   EROFS.
2. QEMU boot with existing `scripts/qemu-*.sh` live helpers.
3. Update validate + package-list extraction so CI does not lie.
4. Compare wall time of the compress step and ISO size on Actions
   artifacts.
5. Keep installer KIWI on dmsquash.

## Alternatives if we do not switch

- Stay on `squashfs-ext4`. Known good. Pay Fedora's old compress cost
  and random read profile.
- Stay SquashFS but push a faster codec if Lorax exposes it (zstd).
  Less upside than EROFS on random I/O, fewer script renames.
- Only change installer later via KIWI. Separate decision.

## Recommendation

Worth a single experimental live build, not a multi-week project.
Fedora's reasons are sound and map onto our pain (runner time, live
desktop I/O). Cost is mostly script and CI path updates.

Do not flip main to EROFS until:

- Live ISO boots in QEMU (and ideally USB once)
- Package-list + validate scripts understand the new layout
- Size and compress-step timing are written back into this file from a
  real run

Installer stays SquashFS/dmsquash until we care enough to open that
separately.

## Repo anchors

- `.github/workflows/build-live-iso.yml`
- `scripts/validate-live-iso.sh`, `scripts/validate-live-iso-filesystem.sh`
- `kiwi/azl-desktop-installer.kiwi` (`flags="dmsquash"`, out of scope)

## External anchors

- https://fedoraproject.org/wiki/Changes/EROFSforLiveMedia
- https://weldr.io/lorax/livemedia-creator.html
- https://github.com/coreos/fedora-coreos-tracker/issues/1852

## Decision log

- 2026-08-07: Research recorded. No implementation. Issue #4 left open
  for a trial build when someone wants the CI cycle.
