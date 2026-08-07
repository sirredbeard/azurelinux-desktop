# Missing color emoji fonts

**Status:** Confirmed on bare metal in Microsoft Edge Canary on
GitHub.com. Fixed by installing Noto Color Emoji; added to live,
installer, and canary package lists.

## Symptom

GitHub emoji reaction picker and similar web UI show empty boxes (tofu)
for most emoji. A few glyphs may still appear from a text font or a
partial fallback.

## Cause

Image had text fonts only:

- `adwaita-sans-fonts`, `adwaita-mono-fonts`
- `liberation-fonts-all`, `dejavu-sans-fonts`
- `google-noto-fonts-common` (not color emoji)

No package provided Noto Color Emoji. Chromium/Edge need a color emoji
font (COLR/CPAL or CBDT) for modern emoji sequences. Without it, emoji
spans paint missing-glyph boxes.

## Fix

Install:

- `google-noto-color-emoji-fonts`: ships `Noto Color Emoji`
  (`Noto-COLRv1.ttf`)
- `default-fonts-core-emoji`: thin metapackage so fontconfig default
  emoji family resolves

Metal after install:

```
fc-list : family | grep -i emoji
# Noto Color Emoji

fc-list 'Noto Color Emoji' file
# /usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf
```

Restart Edge (or open a new window) so it rescans fonts.

## Product wiring

- `kickstart/azurelinux-desktop-live.ks` `%packages`
- `kiwi/config.sh` `TARGET_PKGS`
- `scripts/build-canary-container.sh` + `test-canary-container.sh`

Do not expect `google-noto-fonts-common` alone to cover emoji.

## Note on this metal host

Fedora repo `gpgkey=` pointed at
`/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-43-primary`, which was missing
until copied from `assets/pki/rpm-gpg/`. Image builds that run
`install-rpm-gpg-keys.sh` already stage vendor keys. Bare installs from
older media may need that key before `dnf install` of Fedora font
packages succeeds with `gpgcheck=1`.
