# Installer ISO GRUB: "Test this media" entry missing

**Status:** Resolved

## Observed failure

The installer ISO GRUB menu had no "Test this media & install" entry, even
though `mediacheck="true"` was set in `kiwi/azl-desktop-installer.kiwi`.

## Root cause

Custom `kiwi/grub_template.cfg` fully overrides KIWI's auto-generated GRUB
config. KIWI's `mediacheck="true"` therefore had no effect on the final menu.

`rd.live.check` is handled by dracut's `dmsquash-live` module, which calls
`checkisomd5` from the `isomd5sum` package. `dracut-live` alone does not pull
`isomd5sum` on Fedora 43.

## Resolution

1. Added a "Test this media & install Azure Linux Desktop" menu entry with
   `rd.live.check` to `kiwi/grub_template.cfg`.
2. Added `isomd5sum` to the KIWI package list.

Azure Linux upstream's own installer ISO does not ship a media-check entry.
This project carries the Fedora-style entry on purpose.

## References

- `kiwi/grub_template.cfg`
- `kiwi/azl-desktop-installer.kiwi`
