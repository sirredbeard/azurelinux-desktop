# Installed system: skip text GRUB menu

**Status:** Design decision 2026-08-04. Staged in
`kiwi/post-bootloader.sh`. Needs installer rebuild or
`scripts/patch-nested-desktop-polish.sh`.

## Decision

On a fully installed Azure Linux Desktop (the system's own GRUB, not a
Fedora dual-boot host menu), do not show a text GRUB list on normal
boots. Hand off straight to the Azure Linux Plymouth theme.

## How

* `GRUB_TIMEOUT=0` / `set timeout=0`
* `GRUB_TIMEOUT_STYLE=hidden` / `set timeout_style=hidden`

Rescue and UEFI Firmware Settings stay in `grub.cfg` for recovery when
the menu is forced (Shift or Esc at handoff).
