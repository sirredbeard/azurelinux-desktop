# Evaluate EROFS for the live ISO

**Status:** research only (issue #4). No build change yet.
**Issue:** https://github.com/sirredbeard/azurelinux-desktop/issues/4

## What this is about

Fedora moved live media from SquashFS to EROFS. We still build the live ISO
with Lorax/`livemedia-creator` and `--rootfs-type squashfs-ext4`. The question
is whether matching Fedora is worth it here: size, boot feel, CI time, and
how much of our tooling has SquashFS baked into the name.

Installer ISO stays out of scope. KIWI still uses `flags="dmsquash"`. Leave it
alone unless we open a separate evaluation.

## What we do today

Live path (`.github/workflows/build-live-iso.yml`):

* Build container installs `squashfs-tools`.
* `livemedia-creator ... --rootfs-type squashfs-ext4`
* ISO layout is the usual nested form:

```text
LiveOS/squashfs.img          # outer SquashFS
  └── LiveOS/rootfs.img      # inner ext4
```

Workflow comments already note ~16-17 GB intermediate rootfs pressure on the
runner, then a multi-GB squash. Package-list CI and
`scripts/validate-live-iso*.sh` extract with `xorriso`/`7z` + `unsquashfs` and
then loop-mount the inner ext4.

Installer path (`kiwi/azl-desktop-installer.kiwi`): `flags="dmsquash"`. Different
tool, different artifact. Not part of this switch.

## What Fedora did and why

Fedora Change: [EROFS for Live Media](https://fedoraproject.org/wiki/Changes/EROFSforLiveMedia)
(owners Neal Gompa, Dusty Mabe; live media from F42-era work onward).

Reasons they give, in plain terms:

1. **EROFS is still moving.** SquashFS is stable and mostly frozen. EROFS gets
   kernel and userspace work (Gao Xiang et al.).
2. **Random reads matter more than bulk sequential.** Live desktops open lots of
   small files. EROFS tends to decompress smaller aligned chunks; SquashFS often
   pays for a large compressed block to answer one small read.
3. **Build time.** Their published KDE live numbers (wiki table): SquashFS+XZ
   ~15.4 min compress vs EROFS+LZMA with fragment packing ~9.6 min, image size
   essentially a wash (EROFS slightly smaller in that run).
4. **Downstream alignment.** RHEL-class live media moving the same direction;
   Fedora finds the bugs first.
5. **Tooling already there.** Lorax accepts `--rootfs-type erofs`. Dracut gained
   live EROFS support in the v103 line. `erofs-utils` ships `mkfs.erofs`.

Lorax docs: https://weldr.io/lorax/livemedia-creator.html  
(`--rootfs-type` includes `erofs` alongside the squashfs variants.)

Typical Fedora-style mkfs flags from the change write-up:

```text
mkfs.erofs -zlzma,6 -Eall-fragments,fragdedupe=inode -C1048576
```

We do not need to hand-invoke that if Lorax owns the image; it is the shape of
what "EROFS live" means in their benchmarks.

## Cost / benefit for this repo

### Benefit

| Area | Expectation | Confidence |
| --- | --- | --- |
| Live boot / app open feel | Better random read behavior vs large-block SquashFS; more noticeable on USB and slow disks than on NVMe | Medium (Fedora + external benches; we have not timed our ISO) |
| CI compress step | On the order of Fedora's ~30-40% faster compress phase for a big desktop root | Medium |
| ISO size | Near parity; possible small win with fragment dedupe | Medium |
| Maintenance | Track Fedora live layout instead of being the odd SquashFS holdout as Rawhide/Workstation move on | Low-medium (soft benefit) |
| Nested layout | Lorax EROFS live is often a flatter root image (no outer squash wrapping inner ext4). Fewer moving parts at boot if it works | Medium |

### Cost

| Area | Cost | Notes |
| --- | --- | --- |
| Workflow flag + packages | Small | Swap `--rootfs-type`, install `erofs-utils`, drop or keep `squashfs-tools` only if something else still needs it |
| Validate / package-list scripts | Real but bounded | Every `unsquashfs` / `LiveOS/squashfs.img` assumption breaks. Fix paths and use `mount -t erofs` or `fsck.erofs` extract |
| Dracut / live cmdline | Must smoke-test | Live initrd is built in the Fedora 43 Lorax container today. Confirm `rd.live.*` still matches what we pass and that any `patch-dracut-livenet-hook.sh` assumptions still hold |
| AZL dracut on the *installed* system | Low for live-only | Spot check: Azure Linux 4.0 beta repo has `dracut-107-9.azl4` (above the v103-era live EROFS line). Live boot uses the Lorax-built initrd anyway. Installed system is not the live squash/erofs root |
| Debug muscle memory | Low | Everyone knows `unsquashfs`. EROFS is one more tool on the belt |
| Installer ISO | None if we keep scope | KIWI `dmsquash` unchanged |
| Risk of a bad first landing | Medium until one green live build + QEMU boot | Wrong rootfs type or missing erofs in initrd fails closed (no desktop) |

### What does *not* improve much

* Intermediate ~16 GB rootfs on the runner. Compression format does not remove
  Anaconda/Lorax's need for a full tree before packing.
* Disk image (`--make-disk`) path. Separate from live rootfs type.
* Guest agent / kmod / GNOME issues. Unrelated surface.

## Performance in more detail

**Build (Fedora wiki KDE example, not our tree):**

* SquashFS + XZ, 1M: ~15.4 min, ~2877 MB  
* EROFS + LZMA-6 + fragment dedupe, 1M: ~9.6 min, ~2868 MB  

Our live job is GNOME + side-loads, not KDE Fedora spins, so treat the ratio as
directional. The expensive part we care about is still "pack the live root on a
GitHub runner," not mkfs trivia.

**Runtime (order-of-magnitude from public EROFS vs SquashFS embedded/live
comparisons, e.g. ProteanOS 2026 write-up and the Fedora change discussion):**

* Sequential throughput: often similar or modestly better for EROFS depending on
  codec.
* Random 4K-class I/O: EROFS commonly wins by a large margin when SquashFS uses
  large compressed blocks. That is the live-desktop case (GNOME, fonts, schemas,
  shared libs).
* Mount overhead: usually lower for EROFS in those tables.

We should not claim a specific boot-second number for Azure Linux Desktop until
we time the same ISO content SquashFS vs EROFS on the same USB/QEMU host.

## Practicality

Lorax in our `fedora:43` build image already speaks `--rootfs-type erofs`. The
mechanical product change is small. The real work is:

1. One experimental live workflow (or a temporary branch flag) building EROFS.
2. QEMU boot with existing `scripts/qemu-*.sh` live helpers.
3. Update validate + package-list extraction so CI does not lie.
4. Compare wall time of the compress step and ISO size on Actions artifacts.
5. Keep installer KIWI on dmsquash.

Gate that is already looking fine: AZL `dracut` 107.x in beta base. Still run a
real live boot before calling it done. Theory is cheap; Lorax+dracut live paths
are where we have been burned before.

## Alternatives if we do not switch

* Stay on `squashfs-ext4`. Known good. Pay Fedora's old compress cost and random
  read profile.
* Stay SquashFS but push a faster codec if Lorax exposes it (zstd). Less upside
  than EROFS on random I/O, fewer script renames.
* Only change installer later via KIWI overlay/EROFS. Separate decision; issue #4
  said preserve installer behavior.

## Recommendation

Worth a **single experimental live build**, not a multi-week project. Fedora's
reasons are sound and map onto our pain (runner time, live desktop I/O). Cost is
mostly script and CI path updates, not a new architecture.

Do not flip main to EROFS until:

* Live ISO boots in QEMU (and ideally USB once).
* Package-list + validate scripts understand the new layout.
* Size and compress-step timing are written back into this file from a real run.

Installer stays SquashFS/dmsquash until we care enough to open that can of worms.

## Repo anchors

* `.github/workflows/build-live-iso.yml` - `--rootfs-type squashfs-ext4`, squashfs extract for package list
* `scripts/validate-live-iso.sh`, `scripts/validate-live-iso-filesystem.sh` - `unsquashfs` / `squashfs.img`
* `kiwi/azl-desktop-installer.kiwi` - `flags="dmsquash"` (out of scope for #4)

## External anchors

* https://fedoraproject.org/wiki/Changes/EROFSforLiveMedia  
* https://weldr.io/lorax/livemedia-creator.html  
* https://github.com/coreos/fedora-coreos-tracker/issues/1852 (CoreOS live EROFS discussion)  

## Decision log

* 2026-08-07: Research recorded. No implementation. Issue #4 left open for a
  trial build when someone wants the CI cycle.
