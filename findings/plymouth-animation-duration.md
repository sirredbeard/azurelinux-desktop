# Plymouth animation brief on live and installer ISOs

**Status:** Open (likely expected fast-boot behavior; not confirmed as a bug)

## Observed failure

On both the live ISO and the installer ISO, the animated glowing-dots
Plymouth splash appears briefly, then switches to the static Azure Linux
logo. In QEMU the animated phase is short.

## Current understanding

QEMU boots quickly. Plymouth's scripted theme moves to the static "done"
state once boot targets are reached. That can look like a truncated
animation even when the theme is correct.

Not confirmed as a product bug versus expected fast-boot behavior.

## Next checks

- Time the animated phase on real hardware, or on a deliberately slowed VM.
- Confirm theme assets and `ScaleLogoToFit` path still match
  `plymouth-boot-animation.md` (logo scale is a separate resolved issue).
- Do not change theme timing until hardware or slow-boot evidence shows the
  script ends early for a wrong reason.

## Related

- `plymouth-boot-animation.md` - theme packaging, serial console, logo scale
- Manual QA 2026-07-25 nightly notes (animation short in QEMU; logo correct)
