# Edit installed but missing from GNOME

**Status:** Resolved

## Problem

Microsoft Edit (`edit`) was on the image, but no Edit entry showed in
GNOME overview or the dock.

## What can hide a valid binary

* Desktop file not under an `XDG_DATA_DIRS` path
* Missing or wrong `Categories=`
* `NoDisplay=true`, `Hidden=true`, or `OnlyShowIn=` mismatch
* `Terminal=true` / ConsoleOnly patterns
* Stale desktop caches
* Mode 600 desktop file (installer umask). See
  `anaconda-kickstart-patterns.md`

## Fix

`assets/desktop/edit.desktop` is a normal GUI entry:

* `Icon=` to the staged pixmap
* `MimeType=text/plain;`
* `Categories=Utility;TextEditor;`
* No ConsoleOnly flag
* Staged with `install -m 0644` in kickstarts

On rebuilt images:

* `/usr/share/applications/edit.desktop` is root-owned, mode 0644
* Passes `desktop-file-validate`
* `/usr/local/bin/edit` is present (side-loaded, not RPM-owned)
* Manual QA 2026-07-25: launches from the desktop

## Paths

* `assets/desktop/edit.desktop`
* `gnome-desktop-defaults.md`
* `powershell-dock-identity.md`
