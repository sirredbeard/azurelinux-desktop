# Flatpak: untrusted non-GPG remote + polkit for system updates

**Status:** Resolved for product path as of Copilot Flatpak **0.1.15**
(Pages GPG + sign-before-deltas) and azurelinux-desktop polkit rule
`assets/polkit-1/rules.d/10-azurelinux-desktop-flatpak.rules`. Nested hostpart
QA: Software catalog pull clean after 0.1.15; unprivileged Deploy still needs
an active local wheel session (not SSH).

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
4. **Install path:** `scripts/install-copilot-desktop-flatpak.sh` prefers
   GPG from the live `.flatpakrepo` and asserts `gpg-verify=true` when
   `GPGKey=` is published. Canary checks the same on the system remote.

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
- Template twin: `github-pages-flatpak-repo` (sign-then-delta scripts)


## GNOME Software error after enabling GPG (0.1.13)

```
While pulling appstream2/x86_64 from remote copilot-desktop-gtk:
Commit …: GPG verification enabled, but no signatures found
```

**Cause:** `flatpak build-sign` only signed `app/*` commits. Pages had
`summary.sig` and app `.commitmeta`, but **appstream2** tips only had
`.commitmeta2` (`xa.reachable`), not GPG `.commitmeta`. Software refreshes
appstream first and fails the whole UI.

**Fix (copilot-desktop-gtk):** after `build-update-repo`, `ostree gpg-sign`
every ref tip (app, appstream, appstream2, screenshots), resign summary,
fail CI if any tip lacks `ostree.gpgsigs`. Ship as 0.1.14+.

**Polkit note:** still required for unprivileged Deploy, but cannot replace
GPG for system HTTPS remotes.


## 0.1.14: signatures published, Flatpak still failed

Pages had `.commitmeta` with `ostree.gpgsigs` and `summary.sig`.
`ostree pull --disable-static-deltas` verified Good signature.
Default pulls (static deltas) and Flatpak install failed with the same
"no signatures found" error.

**Cause:** static deltas were generated **before** tips were signed.
Delta pulls do not apply detached `.commitmeta`, so clients never see
the GPG signatures even though HTTP objects exist.

**Fix (0.1.15+):** sign every tip, **then** `build-update-repo
--generate-static-deltas`, and CI proves a delta pull of app +
appstream2 succeeds before Pages deploy.

## Product decision

Prefer GPG on the Pages remote for system installs. Polkit alone is not
enough for Flatpak trust on HTTPS system remotes. Keep both: GPG for
trust, polkit `app-update` for unprivileged Deploy in an active local
wheel session.
