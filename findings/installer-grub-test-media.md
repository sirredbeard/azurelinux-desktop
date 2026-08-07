# Installer ISO GRUB: Test this media entry

**Status:** Resolved

## Problem

The installer ISO GRUB menu had no "Test this media & install" entry,
even with `mediacheck="true"` in `kiwi/azl-desktop-installer.kiwi`.

## Cause

Custom `kiwi/grub_template.cfg` fully replaces KIWI's auto GRUB config.
`mediacheck="true"` never reaches the menu.

`rd.live.check` is handled by dracut's `dmsquash-live` module, which
calls `checkisomd5` from `isomd5sum`. `dracut-live` alone does not pull
`isomd5sum` on Fedora.

## Fix

1. Add a "Test this media & install Azure Linux Desktop" menu entry with
   `rd.live.check` to `kiwi/grub_template.cfg`.
2. Add `isomd5sum` to the KIWI package list.

Azure Linux upstream's installer ISO has no media-check entry. This
project keeps the Fedora-style entry on purpose.

## Paths

* `kiwi/grub_template.cfg`
* `kiwi/azl-desktop-installer.kiwi`
