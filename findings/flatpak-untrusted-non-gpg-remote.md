# Flatpak: untrusted non-GPG remote blocks user updates

**Status:** Root cause confirmed. Fix is GPG-sign the Copilot Pages
OSTree remote (copilot-desktop-gtk). Nested/installed systems need a
signed Pages publish + remote re-add/import before unprivileged updates
work in GNOME Software.

## Observed (installed nested system, 2026-08-04)

- GNOME Software offers Copilot 0.1.12, appears to update, shows Open,
  then bounces back to Updatable (0.1.10 ↔ 0.1.12).
- As the desktop user:

  ```
  flatpak update
  Error: Can't pull from untrusted non-gpg verified remote
  ```

- `sudo flatpak update` succeeds.
- Live ISO earlier updates used **sudo** for the system remote as well
  (same restriction); Flathub apps are fine (GPG-signed).

## Root cause

System install under `/var/lib/flatpak` + non-root client uses
`flatpak_dir_use_system_helper()`. Before calling the helper, Flatpak
refuses to stage a network pull into a user-owned child repo when the
remote has `gpg-verify=false`:

```
Can't pull from untrusted non-gpg verified remote
```

Root bypasses the helper and pulls directly, so sudo works. Polkit
passwordless rules do **not** help: the check is client-side before D-Bus.

GNOME Software maps `FLATPAK_ERROR_UNTRUSTED` to a generic failure and
runs state-recover → version bounce in the UI.

Pages metadata was unsigned on purpose (`stage-flatpak-pages.sh`).

## Fix

1. **copilot-desktop-gtk:** GPG-sign the OSTree repo at build time, embed
   `GPGKey=` in `.flatpakrepo` / `.flatpakref`, CI secret
   `FLATPAK_GPG_PRIVATE_KEY`. Public key in `packaging/flatpak-gpg/`.
2. **azurelinux-desktop:** prestage prefers signed remote when `GPGKey=`
   is present.
3. **Existing installs** after signed Pages publish:

   ```bash
   sudo flatpak remote-delete --system copilot-desktop-gtk || true
   sudo flatpak remote-add --system \
     https://sirredbeard.github.io/copilot-desktop-gtk/copilot-desktop-gtk.flatpakrepo
   flatpak update
   ```

## Related

- `findings/gnome-software-flatpak-empty.md`
- `scripts/install-copilot-desktop-flatpak.sh`
