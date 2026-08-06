# Pre-populate GNOME Software catalog (first open “…” tiles)

**Status:** research only — not implemented. Tracked as a GitHub issue.
Related (shipped partial fix): [`gnome-software-flatpak-empty.md`](gnome-software-flatpak-empty.md).

## Observed

Opening GNOME Software and browsing curated sections (for example **Learn**,
**Editor’s Choice**, **New & Updated**) on first launch shows dark placeholder
tiles with `…` instead of icons and titles. Screenshot evidence (2026-08-06):
empty Learn carousel and grid while metadata is still missing or still
compiling.

This is a **first-open UX** problem, not “Software is permanently broken.”
After Flatpak AppStream lands and the per-user xmlb cache is rebuilt, the same
pages fill in. On a live session or a slow link, that wait is very visible.

## What Software needs on open

Three layers, independent of each other:

| Layer | Path / source | Role in UI |
| --- | --- | --- |
| RPM / distro AppStream | `/usr/share/swcatalog/xml/` (+ icons), often from `appstream-data`, `gnome-app-list`, RPM Fusion `*-appstream-data` | Installed/RPM apps, some category chrome |
| Flatpak AppStream | `/var/lib/flatpak/appstream/<remote>/<arch>/active/` after `flatpak update --appstream` | Flathub catalog, icons, most “store” content |
| Per-user GNOME Software cache | `~/.cache/gnome-software/` (libxmlb `.xmlb` silos) | Fast second open; **empty 40-byte silos can stick** if built before AppStream exists |

Curated chrome (Editor’s Choice / featured tiles) comes largely from
`gnome-app-list` (`org.gnome.App-list.xml` under swcatalog) using tags such as
`GnomeSoftware::popular` and `GnomeSoftware::FeatureTile`. Those tags point at
app IDs; Software still needs matching Flatpak (or RPM) AppStream records and
icons to paint real tiles. Without Flathub AppStream, curation XML alone still
looks empty.

fwupd metadata does not drive Learn / Editor’s Choice.

Upstream vendor notes live in the GNOME Software tree (`doc/vendor-customisation.md`
in the gnome-software repo). Fedora ships gschema overrides for official/required
repos and packaging preference; this project already overrides those for AZL +
Flathub (see flatpak-empty finding).

## What this project already does

From live kickstart and installer kickstart template:

1. **GSettings override** — prefer `flatpak:flathub`, clear Fedora-only
   `required-repos`, list AZL official repos; updates disabled in Software.
2. **`azl-flatpak-appstream.service`** — oneshot after `network-online.target`,
   `ConditionPathExists=!/var/lib/flatpak/appstream/flathub/x86_64/active`,
   runs `flatpak update --appstream`.
3. **Installer `%post`** — tries `flatpak update --appstream` when network is up
   during install (best-effort).
4. **Live package set** already resolves `appstream-data`, `gnome-app-list`, and
   RPM Fusion appstream-data packages (see `live-package-list.txt`). Installer
   offline set historically tracked Azure Linux `appstream` without the full
   Fedora `appstream-data` snapshot — parity gap to re-check on the next
   package-list commit.

Live `%post` itself is **offline** for Flathub: comment in kickstart says
appstream refresh waits until first boot. That is why live first-open still
races the oneshot (and any slow network).

## Ideas (do not implement yet) — ranked

### A. Bake Flathub AppStream into the image at build time (best for live)

Same idea as thirdparty / Copilot Flatpak prestage: during the **build host**
step (has network), run:

```bash
flatpak remote-add --if-not-exists flathub …/flathub.flatpakrepo
flatpak update --appstream flathub
# then copy into the image root:
#   /var/lib/flatpak/appstream/flathub/
```

Or refresh inside a prepared installroot / KIWI root with a temporary Flatpak
system dir. Keep `azl-flatpak-appstream.service` as a fallback when the baked
tree is missing or intentionally stripped.

- **Size:** on a reference host, Flathub appstream tree ~**100 MiB** on disk
  (xml + icons). Squashfs will compress; still a real live ISO bump.
- **Staleness:** metadata ages with the ISO date; first boot can still refresh
  in the background. Prefer “good enough at open” over perfect freshness.
- **Scope:** strongest win on **live ISO** (short session, first impression).
  Disk images / installed target can keep oneshot-only or also bake if parity
  is desired.

### B. Confirm RPM-side AppStream packages on every artifact

- Live: keep `appstream-data` + `gnome-app-list` (+ RPM Fusion appstream-data if
  Fusion apps are shown).
- Installer offline repo / installed target: ensure the same packages are in the
  resolved set, not only bare `appstream`.
- Optional `%post`: `appstreamcli refresh-cache --force` so system swcatalog
  cache exists; note Software still builds **per-user** xmlb on first GUI open.

### C. Avoid empty sticky user caches on first session

Prior bug: `~/.cache/gnome-software/flatpak-system-default/components.xmlb` at
**40 bytes** built before AppStream existed and was not rebuilt. Mitigations to
evaluate later:

- Do not start Software (or a silent refresh) until
  `/var/lib/flatpak/appstream/flathub/.../active` exists.
- Drop empty/stale xmlb after oneshot completes (tmpfiles or oneshot
  `ExecStartPost`).
- Live-only: seed a **liveuser** home cache only if we can generate it
  non-interactively without a full Wayland session (fragile; prefer A).

### D. Optional live-only warmup (higher risk)

Some live builders run `gnome-software --gapplication-service` briefly under a
fake session to warm caches. Fragile under headless lorax/KIWI, easy to flake
CI, and may still need A first. Treat as last resort.

### E. Custom curation XML (product polish, not first fix)

Optional `assets/` AppStream merge file to feature Copilot / project apps in
Editor’s Choice. Does not fix empty tiles without AppStream + icons for those
IDs. Defer until A/B work.

## What not to do

- Do **not** vendor the entire Flathub app/runtime set into the ISO “so Software
  looks full.” Metadata-only is enough for browsing; installs still need
  network (and live free space — see `flatpak-live-session-space.md`).
- Do **not** leave Fedora’s `required-repos = ['fedora','updates']` active on
  this image (already overridden).
- Do **not** disable gpg-verify on Flathub to speed refresh.
- Do **not** delete the first-boot oneshot if baking AppStream: keep it as
  repair/refresh when the baked tree is absent.

## Suggested validation (when implementing)

1. Fresh live boot **without** waiting: open Software → Learn / Editor’s Choice
   show real tiles within a few seconds offline (if AppStream was baked).
2. `test -e /var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml`
   (or `.gz`) on the squashfs / qcow before first boot.
3. After first open:
   `find ~/.cache/gnome-software -name '*.xmlb' -size +1k` (no 40-byte silos).
4. Installed system: oneshot no-ops when baked path exists; still works when
   path is missing (simulate by removing appstream tree).
5. ISO size delta recorded in the PR (before/after).

## Relation to prior work

| Topic | File |
| --- | --- |
| Empty Flatpak results + wrong Fedora gschema + oneshot | `gnome-software-flatpak-empty.md` |
| Live Flatpak free space / DM snapshot | `flatpak-live-session-space.md` |
| Copilot Flatpak GPG / polkit | `flatpak-untrusted-non-gpg-remote.md` |

## Key log / size notes

```text
# Host reference (Fedora) after normal use:
#   /var/lib/flatpak/appstream/flathub  ~102M
# Live package list includes:
#   appstream-data-43-*.fc43.noarch
#   gnome-app-list-*.fc43.noarch
# Prior nested install:
#   ~/.cache/gnome-software/.../components.xmlb  40 bytes empty if built too early
```

## Decision (pending implementation)

Prefer **A (bake Flathub AppStream at image build)** for live, keep oneshot as
fallback, **B (AppStream RPM parity)** on installer/installed, and only then
consider cache-warmup or custom curation. No code change in this research pass.
