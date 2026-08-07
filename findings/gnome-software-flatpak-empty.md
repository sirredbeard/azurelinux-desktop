# GNOME Software shows no Flatpaks on installed system

**Status:** Root cause identified; image-side fix staged (needs rebuild +
retest). Nested install gschema + cache cleared for next dual-boot check.

## Observed

Installer ISO → nested bare-metal install:

* Software app opens; search for common Flatpak names returns
  "No Results Found"
* Curated / recent lists empty (`Only 0 apps for curated list`)
* `flatpak` + `gnome-software` + `libgs_plugin_flatpak.so` installed
* Flathub remote already present from install `%post` (user also ran
  `flatpak remote-add` manually; no-op)
* After session start, `flatpak` did pull appstream (~48 MiB
  `appstream.xml`, active symlink OK, ~4668 components)

## Evidence

| Check | Result |
| --- | --- |
| `/var/lib/flatpak/repo/config` | `[remote "flathub"]` from install time (08:39) |
| Appstream on disk | Populated 10:21 during session |
| `~/.cache/gnome-software/flatpak-system-default/components.xmlb` | **40 bytes empty** stamped 10:15, never rebuilt |
| Fedora gschema override | `packaging-format-preference = ['flatpak:fedora-testing', 'flatpak:fedora', 'rpm']` — **no flathub** |
| Same override | `required-repos = ['fedora', 'updates']` — those repos do not exist on Azure Linux |
| Our override | Only set `allow-updates` / `download-updates` |

Screenshots under `~/Pictures/Screenshots/`. Probes under
`~/azl-work/azl-boot-logs-20260803/`.

## Root cause (two layers)

1. **Fedora `org.gnome.software-fedora.gschema.override` is wrong on
   Azure Linux Desktop.** It prefers only Fedora Flatpak remotes and
   marks `fedora`/`updates` as required. This image uses Flathub + AZL
   DNF repos, not Fedora Flatpaks as the primary store.
2. **No appstream at first Software launch, and the empty Flatpak
   xmlb cache was not rebuilt** after appstream landed. Install `%post`
   adds the remote but does not run `flatpak update --appstream` (and
   live `%post` is offline anyway). First boot must refresh appstream
   once network is up.

Manual `flatpak remote-add` could not fix (1) or the stale empty cache.

## Fix

1. Expand `org.gnome.software.gschema.override` (sorts after the Fedora
   override file) on live, disk, and installer paths:

   ```
   packaging-format-preference=['flatpak:flathub', 'flatpak', 'rpm']
   required-repos=[]
   official-repos=['azl-base', 'azl-microsoft', 'azl-desktop-kmods']
   ```

   Keep `allow-updates=false` / `download-updates=false` and no
   Software autostart.

2. First-boot oneshot `azl-flatpak-appstream.service`: when Flathub
   appstream is missing, run `flatpak update --appstream` after
   `network-online.target`.

3. On installer `%post` (has network), also try
   `flatpak update --appstream` immediately after remote-add.

## Verify

```bash
flatpak remotes -d
test -e /var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml
gsettings get org.gnome.software packaging-format-preference
# expect flatpak:flathub first
rm -rf ~/.cache/gnome-software
gnome-software   # search "Calculator" / "Firefox" should list Flathub
```

## Related

* `flatpak-live-session-space.md` — live free-space / DM-snapshot (different issue)
* `gnome-software-catalog-preseed.md` — issue #6: bake Flathub AppStream at
  image build so curated tiles are not empty on first open (implemented)
* kickstart / kiwi Flathub remote-add comments ("no flatpaks in gnome-software")
