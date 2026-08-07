# Pre-populate GNOME Software catalog

**Status:** implemented (issue #6). Scripts assert AppStream at
prestage/canary/installroot paths. Treat this as the topic note, not a
release sign-off by itself.
**Issue:** https://github.com/sirredbeard/azurelinux-desktop/issues/6

## Observed

Opening GNOME Software and browsing curated sections (Learn, Editor's
Choice, New & Updated) on first launch showed dark placeholder tiles
with `…` instead of icons and titles.

This is a first-open UX problem when Flathub AppStream is missing at
session start. After metadata lands and the per-user xmlb cache is
rebuilt, the same pages fill in. Empty
`~/.cache/gnome-software/.../components.xmlb` files (~40 bytes) built
before AppStream existed can stick and keep results empty.

## What Software needs on open

- RPM / distro AppStream: `/usr/share/swcatalog/xml/` from
  `appstream-data`, `gnome-app-list`, RPM Fusion `*-appstream-data`
- Flatpak AppStream:
  `/var/lib/flatpak/appstream/<remote>/<arch>/active/`
- Per-user GNOME Software cache: `~/.cache/gnome-software/` (libxmlb
  `.xmlb`). Empty silos stick if built too early.

Curated chrome still needs matching Flatpak AppStream records and icons
to paint real tiles.

## Intended approach

### A. Bake Flathub AppStream at image build (primary)

Shared path: `scripts/install-copilot-desktop-flatpak.sh` (used by
prestage, canary, and any installroot that pulls the Copilot Flatpak
tree).

After Flathub remote + Copilot app install:

```bash
flatpak update --user --appstream flathub
# assert appstream.xml and icons under appstream/flathub/...
```

`scripts/prestage-copilot-flatpak-system.sh` fail-closes if the
AppStream tree is missing after copy to `DEST`.

Delivery:

- Live ISO / disk: CI prestage, then `%post --nochroot` copies into
  `/var/lib/flatpak` and asserts AppStream
- Installer ISO: KIWI stages same tree under offline extras; Anaconda
  nochroot copies to target and asserts
- Canary OCI: build helper runs install helper; test checks baked tree

Size: about 100 MiB uncompressed under
`/var/lib/flatpak/appstream/flathub`. Squashfs compresses; still a real
live ISO bump. Metadata ages with the ISO date; background refresh
remains available.

### B. RPM AppStream parity

Explicit packages on live kickstart and installer offline set:

- `appstream-data`
- `gnome-app-list`

### C. Fallback oneshot + sticky cache cleanup

`azl-flatpak-appstream.service` still enabled on live + installer:

- No-ops when bake succeeded
  (`ConditionPathExists=!.../appstream/flathub/.../active`)
- Otherwise runs `flatpak update --appstream`, then deletes tiny
  `components.xmlb` under `/home/*/.cache/gnome-software/`

Installer `%post` only runs `flatpak update --appstream` if the active
symlink is still missing after the prestaged copy.

## What we did not do

- Vendor entire Flathub apps/runtimes into the ISO for browse-only tiles
- Disable Flathub GPG verify
- Headless `gnome-software` cache warmup in CI
- Custom curation XML

## Validation

1. Prestaged tree / squashfs / canary root has
   `appstream/flathub/.../active/appstream.xml` and icons.
2. Fresh live boot offline: Software curated pages show real tiles
   within a few seconds.
3. After first open: no 40-byte flatpak xmlb silos.
4. Simulate missing bake: oneshot pulls on network-online.
5. Record ISO size delta on next live build.

## Relation to prior work

- `gnome-software-flatpak-empty.md`: empty Flatpak results + wrong
  Fedora gschema + oneshot
- `flatpak-live-session-space.md`: live Flatpak free space / DM snapshot
- `flatpak-untrusted-non-gpg-remote.md`: Copilot Flatpak GPG / polkit

## Code touchpoints

- `scripts/install-copilot-desktop-flatpak.sh`
- `scripts/prestage-copilot-flatpak-system.sh`
- `kickstart/azurelinux-desktop-live.ks`
- `kiwi/config.sh`, `kiwi/azl-install.ks.in`
- `scripts/build-canary-container.sh` / `test-canary-container.sh`
