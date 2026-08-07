# UEFI firmware text (BdsDxe) before Plymouth

**Status:** Resolved

## Problem

Before Plymouth starts, the screen shows UEFI firmware lines such as
`BdsDxe: loading ...` and `BdsDxe: starting ...`, then GRUB text. The
boot path looks like a cloud or serial console boot instead of a clean
graphical desktop splash.

## Cause

The installer GRUB template used text-mode output:

```
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_output console serial
terminal_input console serial
```

`terminal_output console` keeps GRUB in VGA text mode. BdsDxe messages
come from firmware before GRUB loads and cannot be suppressed without
firmware vendor support. Keeping text mode through GRUB also means GRUB
never sets up EFI GOP, so the kernel does not inherit a clean
framebuffer for Plymouth.

The installed-system GRUB written by `kiwi/post-bootloader.sh` had the
same text-mode pattern, so the installed desktop matched the cloud
default rather than the installer ISO's own graphical GRUB.

## Fix

Switch GRUB to graphical mode, keep serial as input only, and clear the
screen after gfxterm starts.

Installer ISO (`kiwi/grub_template.cfg`):

```grub
insmod efi_gop
insmod efi_uga
insmod all_video
set gfxmode=auto
set gfxpayload=keep
terminal_output gfxterm
clear

serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
# Do NOT add serial to terminal_output - that reverts to text mode
```

Installed system: `kiwi/post-bootloader.sh` writes the same gfxterm
pattern into `/boot/grub2/grub.cfg`.

Key points:

* `terminal_output gfxterm` alone switches GRUB to graphical mode and
  clears BdsDxe text from the framebuffer.
* `set gfxpayload=keep` lets the kernel inherit the EFI GOP mode GRUB set.
* `terminal_input serial console` keeps serial usable for rescue without
  forcing text output.
* Remove decorative `echo 'Loading kernel...'` lines under gfxterm.
  They only add flicker.

## What did not work

* Leaving `serial` in `terminal_output` while also loading gfxterm.
  Serial in the output list pulls GRUB back toward text mode.
* Treating BdsDxe lines as a Plymouth bug. Plymouth never runs that early.

## Evidence

* Static checks on installer ISO runs `29984008922` and `29987725267`:
  `terminal_output gfxterm`, `gfxpayload=keep`, `efi_gop` present; no
  `terminal_output console serial` on the fixed path.
* QEMU boot: no product-level console text noise before Plymouth on the
  fixed GRUB path (2026-07-22).

## Follow-up (2026-08-03)

Installed-system reboot still showed text GRUB even with gfxterm in
`grub.cfg`. Root cause was missing `/boot/grub2/x86_64-efi/*.mod`
(modules only under `/usr/lib/grub`). See
`installed-grub-missing-efi-modules.md`.

Manual QA 2026-07-25: brief BdsDxe text still appears under QEMU OVMF.
That is QEMU firmware behavior, not the product GRUB path. Not present
the same way on real hardware with a graphical UEFI. Not actionable.

## Paths

* `kiwi/grub_template.cfg`, `kiwi/post-bootloader.sh`
* Related: `plymouth-boot-animation.md`
* Lorax reference:
  `weldr/lorax` `share/templates.d/99-generic/live/config_files/x86/grub2-efi.cfg`
