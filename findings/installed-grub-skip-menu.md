# Installed system: skip text GRUB menu

**Status:** Design decision 2026-08-04. Staged in
`kiwi/post-bootloader.sh`. Verified on clean-room install from
`2026.08.07` installer ISO (LVM target): `timeout=0`,
`timeout_style=hidden`, `terminal_output gfxterm`, EFI modules under
`/boot/grub2/x86_64-efi/`. Hardened 2026-08-07: also
`GRUB_RECORDFAIL_TIMEOUT=0`, `unset recordfail` in static `grub.cfg`,
`GRUB_DISABLE_OS_PROBER=true` so a prior crash or os-prober cannot
force a text menu.

## Decision

On a fully installed Azure Linux Desktop (the system's own GRUB, not a
Fedora dual-boot host menu), do not show a text GRUB list on normal
boots. Hand off straight to the Azure Linux Plymouth theme.

## How

* `GRUB_TIMEOUT=0` / `set timeout=0`
* `GRUB_TIMEOUT_STYLE=hidden` / `set timeout_style=hidden`
* `GRUB_RECORDFAIL_TIMEOUT=0` and `unset recordfail` after `load_env`
* `GRUB_TERMINAL_OUTPUT=gfxterm` only (no serial/console as output)
* GRUB EFI modules copied next to `grub.cfg` so gfxterm actually loads
  (see `installed-grub-missing-efi-modules.md`)

Rescue and UEFI Firmware Settings stay in `grub.cfg` for recovery when
the menu is forced (Shift or Esc at handoff).
