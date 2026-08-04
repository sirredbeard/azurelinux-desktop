# Flatpak: untrusted non-GPG remote + polkit for system updates

**Status:** GPG signing shipped on Pages (0.1.13). Nested install verified
update path. Polkit `app-update` rule staged for images.

## Observed (installed nested system, 2026-08-04)

- GNOME Software bounced Copilot versions; user `flatpak update` failed:

  ```
  Error: Can't pull from untrusted non-gpg verified remote
  ```

- `sudo flatpak update` worked.
- After enabling GPG on the remote, unprivileged update failed with:

  ```
  Error: Flatpak system operation Deploy not allowed for user
  ```

  over **SSH** (not an active logind session). Upstream
  `org.freedesktop.Flatpak.rules` allows install/uninstall/modify-repo for
  active local **wheel**, but not `app-update` / `runtime-update`.

## Root causes (two layers)

1. **Unsigned Pages remote:** non-root system installs use the system
   helper; Flatpak refuses to stage HTTPS pulls when `gpg-verify=false`
   (`FLATPAK_ERROR_UNTRUSTED`). Root skips the helper.
2. **Polkit:** even with GPG, Deploy needs an allowed action. Stock rules
   miss `org.freedesktop.Flatpak.app-update`. SSH never has
   `subject.active`, so GUI/session testing is required for unprivileged
   proof.

## Fix

1. **copilot-desktop-gtk:** GPG-sign OSTree; `GPGKey=` in
   `.flatpakrepo` / `.flatpakref`; CI secret `FLATPAK_GPG_PRIVATE_KEY`.
2. **Existing installs:**

   ```bash
   curl -fsSL https://sirredbeard.github.io/copilot-desktop-gtk/flatpak-signing-key.asc \
     -o /tmp/fp-key.asc
   sudo flatpak remote-modify --system --gpg-import=/tmp/fp-key.asc copilot-desktop-gtk
   sudo flatpak remote-modify --system --gpg-verify copilot-desktop-gtk
   # ensure config has gpg-verify=true (not no-gpg-verify)
   flatpak update   # from a logged-in desktop session as wheel
   ```

3. **azurelinux-desktop:** `assets/polkit-1/rules.d/10-azurelinux-desktop-flatpak.rules`
   grants active local wheel the full Flatpak action set including
   `app-update`. Staged from live kickstart + installer kickstart.

## Nested QA 2026-08-04

- Pages 0.1.13 has `GPGKey=`.
- Nested remote switched to `gpg-verify=true` + key import.
- `sudo flatpak update` → **0.1.13**.
- Unprivileged over SSH still denied Deploy (expected: not active).
- Polkit rule installed on nested for GUI Software / terminal-in-session.

## Related

- `findings/gnome-software-flatpak-empty.md`
- `scripts/install-copilot-desktop-flatpak.sh`
- `~/copilot-desktop-gtk/packaging/flatpak-gpg/`
