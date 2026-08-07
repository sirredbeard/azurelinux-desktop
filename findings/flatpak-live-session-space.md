# Flatpak install fails in live session (free space)

**Status:** Resolved

## Observed failure

In a live ISO session, Flatpak refused installs with roughly ~495 MiB
free even on a VM with several GiB of RAM. Example:

```
/proc/cmdline: rd.live.overlay.overlayfs=1 rd.live.image quiet rhgb
df -h /: LiveOS_rootfs  783M  345M  438M  45%  /
/var/lib/flatpak/repo/config: min-free-space-size=500MB
Available: 438 MB < 500 MB guard → install blocked
```

## Root cause

Two Lorax/live overlay facts stacked:

1. `--live-rootfs-size` is ignored for `--make-iso`.
   livemedia-creator only consumes it for `--make-pxe-live`. The
   workflow flag never changed the ISO.

2. Overlay mode decides what `statvfs` reports. Flatpak calls
   `statvfs("/var/lib/flatpak")` and enforces `min-free-space-size`
   (default 500 MB) before download.

### Mode A: plain squashfs + OverlayFS (what broke)

Lorax default `--rootfs-type squashfs` produces a plain squashfs.
Dracut then forces OverlayFS. The upper layer is tmpfs (~19-50% of
RAM). At 4 GiB RAM that is only a few hundred MiB free under
`/var/lib/flatpak`, so OSTree's 500 MB guard fires immediately.

### Mode B: squashfs containing ext4 `rootfs.img` + DM snapshot

When squashfs contains `LiveOS/rootfs.img`, dracut uses a DM snapshot
on that ext4. `statvfs("/")` reports the ext4 free blocks, not COW
size and not RAM. A too-small `rootfs.img` also trips Flatpak.
Enlarging the DM COW file does not change ext4 `f_bavail`.

Fedora's KIWI live images use a nested block image for the same
reason: DM-snapshot path, large apparent free space.

## Resolution (shipped)

In `build-live-iso.yml`, use:

```
--rootfs-type squashfs-ext4
```

Lorax builds nested `LiveOS/rootfs.img` (ext4). Dracut uses
DM-snapshot. `statvfs` reports the ext4 virtual size. Remove
`rd.live.overlay.overlayfs=1` so it cannot force the tmpfs OverlayFS
path.

Verified after the change: DM-snapshot mode, about 4 GiB apparent free;
Flatpak install works in live session.

## What did not work

- Raising `--live-rootfs-size` without changing rootfs type (silently
  ignored for ISO).
- Relying on more RAM alone under OverlayFS without resizing `/run`.
- Lowering Flatpak `min-free-space-size` (workaround only).
- Assuming the squashfs "zero free blocks" reading was the Flatpak bug;
  the writable layer's `statvfs` is what matters.

## Inspection commands (live session)

```bash
dmsetup status        # live-rw snapshot → DM mode
mount | grep overlay  # OverlayFS mode
df -h / /var/lib/flatpak
cat /proc/cmdline
```

## References

- dracut `modules.d/70dmsquash-live/dmsquash-live-root.sh`
- weldr/lorax `creator.py`, `imgutils.py`
- Flatpak issues 3187 / 3188 (free-space checks)
- `.github/workflows/build-live-iso.yml`
