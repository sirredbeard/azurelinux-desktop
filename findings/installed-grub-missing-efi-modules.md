# Installed GRUB stays in text mode

**Status:** Fix staged in `kiwi/post-bootloader.sh`. Nested install
patched in place for reboot proof. Needs installer ISO rebuild for
release artifacts.

## Observed failure

After growroot/SELinux reboot of a fresh installer target:

1. UEFI `BdsDxe: loading/starting ...` text
2. Text-mode GRUB menu (GRUB 2.12, ASCII box)
3. Black frame
4. Then Plymouth (logo + spinner)
5. GDM

`/boot/grub2/grub.cfg` already had the intended gfxterm block from
`post-bootloader.sh`:

```
insmod efi_gop
insmod efi_uga
insmod all_video
set gfxmode=auto
set gfxpayload=keep
terminal_output gfxterm
```

So this was not a "forgot to switch off serial terminal_output"
regression in the menu script itself.

## Root cause

Fedora's `grubx64.efi` + ESP stub sets:

```
set prefix=($dev)/grub2
configfile $prefix/grub.cfg
```

`insmod` loads modules from `/boot/grub2/x86_64-efi/` on the boot
filesystem. On the nested install:

- `/usr/lib/grub/x86_64-efi/*.mod`: present (RPM `grub2-efi-x64-modules`)
- `/boot/grub2/x86_64-efi/`: missing (only `grub.cfg`, `grubenv`,
  `fonts/`)

With no modules next to `prefix`, `insmod efi_gop` / `gfxterm` fail and
GRUB keeps the firmware text console. Menu content still matches our
cfg; only the output device is wrong.

Secondary drift: Anaconda left cloud-style `/etc/default/grub`:

```
GRUB_TERMINAL_OUTPUT="console serial"
GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0"
```

Our static `grub.cfg` ignored that for the menu we write, but a later
`grub2-mkconfig` would reintroduce serial/text. BLS entries already used
`console=tty0 rhgb quiet` without `ttyS0`.

Related earlier work (`uefi-bdsdxe-text-before-plymouth.md`) fixed the
cfg text. This issue is the missing module payload on `/boot`.

## Fix

In `kiwi/post-bootloader.sh`, before writing `grub.cfg`:

1. Copy `$SYSROOT/usr/lib/grub/x86_64-efi/` (or `arm64-efi`) to
   `$SYSROOT/boot/grub2/<same>/`.
2. Rewrite `/etc/default/grub` for desktop: `GRUB_TERMINAL_OUTPUT=gfxterm`,
   `GRUB_CMDLINE_LINUX="rhgb quiet"`, `GRUB_GFXPAYLOAD_LINUX=keep`.
3. Add `clear` after `terminal_output gfxterm` (match installer
   `kiwi/grub_template.cfg`).

## Verification

- Nested before: `/boot/grub2/x86_64-efi` empty/absent; text GRUB on
  reboot path.
- Nested after in-place patch: modules including `efi_gop.mod` and
  `gfxterm.mod`; cfg has `clear`.
- Next QEMU reboot should show graphical GRUB (or a brief clear
  framebuffer) then Plymouth without the ASCII menu.
- Installer ISO rebuild must carry the post-bootloader change; live ISO
  path does not use this script.

## References

- `kiwi/post-bootloader.sh`, `kiwi/grub_template.cfg`
- `uefi-bdsdxe-text-before-plymouth.md`
