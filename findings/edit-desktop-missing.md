# `edit` installed but missing from GNOME

**Status:** Resolved

## Observed failure

Microsoft Edit (`edit`) was installed on the image, but no Edit entry
appeared in GNOME overview or dock.

## Root causes considered

Research (`GNOME Shell` application discovery) listed several ways a valid
binary still disappears from the overview:

- Desktop file not under an `XDG_DATA_DIRS` component
- Missing or wrong `Categories=`
- `NoDisplay=true` / `Hidden=true` / `OnlyShowIn=` mismatch
- `Terminal=true` + `ConsoleOnly` patterns that hide from the GUI
- Stale `mimeinfo.cache` / need `update-desktop-database`
- Mode 600 desktop file (installer umask issue; see
  `anaconda-kickstart-patterns.md`)

## Resolution

`assets/desktop/edit.desktop` updated to a GUI-visible shape:

- `Icon=` pointing at the staged pixmap (project uses the edit icon asset)
- `MimeType=text/plain;`
- `Categories=Utility;TextEditor;`
- No `ConsoleOnly` flag
- World-readable mode via `install -m 0644` in kickstarts

On-disk checks on rebuilt artifacts:

- `/usr/share/applications/edit.desktop` present, root-owned, mode 0644
- Passes `desktop-file-validate`
- `/usr/local/bin/edit` present (not RPM-owned; side-loaded tool)
- Manual QA 2026-07-25: Edit launches from the desktop environment

## References

- `assets/desktop/edit.desktop`
- `gnome-desktop-defaults.md`
- `powershell-dock-identity.md` (shared discovery research)
