# Pre-populate GNOME Software catalog (first open “…” tiles)

**Status:** implemented (issue #6).  
**Issue:** https://github.com/sirredbeard/azurelinux-desktop/issues/6

## Observed

Opening GNOME Software and browsing curated sections (for example **Learn**,
**Editor’s Choice**, **New & Updated**) on first launch showed dark placeholder
tiles with `…` instead of icons and titles.

This is a **first-open UX** problem when Flathub AppStream is missing at
session start. After metadata lands and the per-user xmlb cache is rebuilt,
the same pages fill in. On a live session or a slow link, that wait is very
visible. Empty `~/.cache/gnome-software/.../components.xmlb` files (~40
bytes) built *before* AppStream existed can stick and keep results empty.

## What Software needs on open

| Layer | Path / source | Role in UI |
| --- | --- | --- |
| RPM / distro AppStream | `/usr/share/swcatalog/xml/` from `appstream-data`, `gnome-app-list`, RPM Fusion `*-appstream-data` | Installed/RPM apps, curated chrome tags |
| Flatpak AppStream | `/var/lib/flatpak/appstream/<remote>/<arch>/active/` | Flathub catalog, icons, most “store” content |
| Per-user GNOME Software cache | `~/.cache/gnome-software/` (libxmlb `.xmlb`) | Fast second open; empty silos stick if built too early |

Curated chrome (`GnomeSoftware::popular` / `FeatureTile` in `gnome-app-list`)
still needs matching Flatpak AppStream records and icons to paint real tiles.

## Implementation

### A. Bake Flathub AppStream at image build (primary)

Shared path: `scripts/install-copilot-desktop-flatpak.sh` (used by prestage,
canary, and any installroot that pulls the Copilot Flatpak tree).

After Flathub remote + Copilot app install:

```bash
flatpak update --user --appstream flathub
# assert:
#   $FLATPAK_USER_DIR/appstream/flathub/x86_64/active/appstream.xml[.gz]
#   $FLATPAK_USER_DIR/appstream/flathub/x86_64/active/icons/
```

`scripts/prestage-copilot-flatpak-system.sh` fail-closes if the AppStream
tree is missing after copy to `DEST`.

| Artifact | Delivery |
| --- | --- |
| Live ISO / disk | CI runs prestage → `%post --nochroot` copies `/workspace/prestage/flatpak-system` into `/var/lib/flatpak` and asserts AppStream |
| Installer ISO | KIWI stages same tree under offline extras; Anaconda nochroot copies to target and asserts |
| Canary OCI | `build-canary-container.sh` runs install helper into installroot; asserts; `test-canary-container.sh` checks baked tree |

**Size:** ~**100–102 MiB** uncompressed under
`/var/lib/flatpak/appstream/flathub` (xml ~47 MiB + icons ~46 MiB + gz).
Squashfs compresses; still a real live ISO bump. Metadata ages with the ISO
date; background refresh remains available.

### B. RPM AppStream parity

Explicit packages on live kickstart and installer offline set (`kiwi/config.sh`):

- `appstream-data`
- `gnome-app-list`

(These already resolved on live via weak deps historically; listing them
avoids silent drop.)

### C. Fallback oneshot + sticky cache cleanup

`azl-flatpak-appstream.service` still enabled on live + installer:

- `ConditionPathExists=!/var/lib/flatpak/appstream/flathub/x86_64/active`
  → no-ops when bake succeeded.
- `ExecStart=/usr/libexec/azl-flatpak-appstream-refresh` runs
  `flatpak update --appstream` then deletes `components.xmlb` under
  `/home/*/.cache/gnome-software/` smaller than 100 bytes.

Installer `%post` only runs `flatpak update --appstream` if the active
symlink is still missing after the prestaged copy.

## What we did not do

- Vendor entire Flathub apps/runtimes into the ISO for browse-only tiles.
- Disable Flathub GPG verify.
- Headless `gnome-software --gapplication-service` cache warmup in CI.
- Custom curation XML (optional product polish later).

## Validation

1. Prestaged tree / squashfs / canary root:
   `test -e /var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml`
   and `.../active/icons`.
2. Fresh live boot offline: Software Learn / Editor’s Choice show real tiles
   within a few seconds (no wait on network oneshot).
3. After first open: `find ~/.cache/gnome-software -name '*.xmlb' -size +1k`
   (no 40-byte flatpak silos).
4. Simulate missing bake: remove `appstream/flathub/.../active` → oneshot
   pulls on network-online.
5. ISO size: record delta on next live build (~100 MiB before squashfs).

Metal reference host (this session): system AppStream already ~102 MiB after
prior `flatpak update --appstream`; empty 40-byte user xmlb cleaned when
found under `~/.cache/gnome-software/flatpak-user-user/`.

## Relation to prior work

| Topic | File |
| --- | --- |
| Empty Flatpak results + wrong Fedora gschema + oneshot | `gnome-software-flatpak-empty.md` |
| Live Flatpak free space / DM snapshot | `flatpak-live-session-space.md` |
| Copilot Flatpak GPG / polkit | `flatpak-untrusted-non-gpg-remote.md` |

## Code touchpoints

- `scripts/install-copilot-desktop-flatpak.sh` — bake + assert
- `scripts/prestage-copilot-flatpak-system.sh` — DEST assert
- `kickstart/azurelinux-desktop-live.ks` — packages, copy assert, refresh unit
- `kiwi/config.sh` — packages + EXTRAS assert
- `kiwi/azl-install.ks.in` — target copy assert + refresh unit
- `scripts/build-canary-container.sh` / `test-canary-container.sh` — assert
