# Flatpak install fails in live session (free space)

**Status:** Resolved

## Observed failure

In a live ISO session, Flatpak refused installs with roughly ~495 MiB free
even on a VM with several GiB of RAM. Example debug log:
live session evidence:
```
/proc/cmdline: rd.live.overlay.overlayfs=1 rd.live.image quiet rhgb
df -h /: LiveOS_rootfs  783M  345M  438M  45%  /
/var/lib/flatpak/repo/config: min-free-space-size=500MB
Available: 438 MB < 500 MB guard → install blocked
GNOME Platform runtime: ~410 MB download
```

## Root cause (confirmed 2026-07-22)

Two Lorax/live overlay facts stacked:

1. **`--live-rootfs-size` is ignored for `--make-iso`.**  
   livemedia-creator only consumes it in `make_live_images()` for
   `--make-pxe-live` (`weldr/lorax` `creator.py`). The workflow flag
   `--live-rootfs-size 8` never changed the ISO.

2. **Overlay mode decides what `statvfs` reports.**  
   Flatpak calls `statvfs("/var/lib/flatpak")` and enforces
   `min-free-space-size` (default 500 MB) before download.

### Mode A - plain squashfs + OverlayFS (what broke)

Lorax default `--rootfs-type squashfs` produces a plain squashfs with
`proc/` at the root (no nested `LiveOS/rootfs.img`). Dracut
`dmsquash-live-root.sh` then forces OverlayFS. The upper layer is tmpfs
(~19-50% of RAM). At 4 GiB RAM that is only a few hundred MiB free under
`/var/lib/flatpak`, so OSTree's 500 MB guard fires immediately.

`rd.live.overlay.overlayfs=1` in grub.cfg was redundant: dracut already
forced OverlayFS for plain squashfs.

### Mode B - squashfs containing ext4 `rootfs.img` + DM snapshot (fixed path)

When squashfs contains `LiveOS/rootfs.img`, dracut uses a DM snapshot on
that ext4. `statvfs("/")` reports the **ext4 free blocks**, not COW size
and not RAM. A too-small `rootfs.img` (for example 4 GiB with ~3.5 GiB
installed) also yields ~500 MiB free and trips Flatpak. Enlarging the DM
COW file does not change ext4 `f_bavail`.

Fedora's KIWI live images use a nested block image (erofs) for the same
reason: DM-snapshot path, large apparent free space, no special Flatpak
config.

## What Fedora does

- `filesystem="erofs"` → `LiveOS/rootfs.img` inside squashfs
- Kernel cmdline without forced OverlayFS
- Dracut finds `rootfs.img` → DM snapshot → large `statvfs` free space

## Resolution (shipped)

In `build-live-iso.yml`, replace the ineffective size/overlay flags with:

```
--rootfs-type squashfs-ext4
```

Lorax then builds nested `LiveOS/rootfs.img` (ext4). Dracut uses
DM-snapshot. `statvfs` reports the ext4 virtual size (enough headroom for
Flatpak). Remove `rd.live.overlay.overlayfs=1` so it cannot force the
tmpfs OverlayFS path over the nested image.

Verified on nightly after squash merge `b085d15`: DM-snapshot mode, about
4 GiB apparent free; Flatpak install works in live session (manual QA
2026-07-25).

## Remediation options researched (ranked)

| Option | Idea | Notes |
|---|---|---|
| A | Larger `--live-rootfs-size` / ext4 image | Correct for nested ext4; size flag alone was a no-op on `--make-iso` until rootfs-type changed |
| B | OverlayFS mode with larger `/run` | Works but free space tracks RAM; worse UX on small VMs |
| C | Pre-install Flatpaks in the live root | Best offline UX; higher build cost |
| D | Persistent USB overlay | USB-only |
| E | Lower Flatpak `min-free-space-size` | Workaround only; not preferred |
| F | `rd.writable.fsimg=1` full RAM extract | Heavy RAM use |

Shipped choice: Option A architecture via `--rootfs-type squashfs-ext4`.

## Inspection commands (live session)

```bash
dmsetup status        # live-rw snapshot → DM mode
mount | grep overlay  # OverlayFS mode
df -h / /var/lib/flatpak
# DM COW usage example:
# live-rw: 0 8388608 snapshot used/total 512-byte sectors
cat /proc/cmdline
```

## What did not work

- Raising `--live-rootfs-size` without changing rootfs type (silently ignored
  for ISO).
- Relying on more RAM alone under OverlayFS without resizing `/run`.
- Assuming the squashfs "zero free blocks" reading was the Flatpak bug; the
  writable layer's `statvfs` is what matters.

## References

- dracut `modules.d/70dmsquash-live/dmsquash-live-root.sh`
- weldr/lorax `creator.py`, `imgutils.py`
- Flatpak issues 3187 / 3188 (free-space checks)
- `.github/workflows/build-live-iso.yml`
