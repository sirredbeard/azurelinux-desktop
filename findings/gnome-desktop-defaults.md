# GNOME desktop defaults

**Status:** implemented in kickstart/kiwi assets

## Context

The project configures GNOME with dark mode, custom wallpaper, a specific dock favorites list, autologin, and keyring unlocking. The live ISO applies settings at session time via `livesys-gnome`; the qcow2 and installed system need those settings persisted at image-build time into the system dconf database and configuration files. The two mechanisms do not overlap — `livesys-gnome` is conditioned on `rd.live.image` and will not run on disk images or installed systems.

## Known issues and root causes

### dconf system database

- **Profile file required.** `/etc/dconf/profile/user` must exist and reference the `local` system db (one line: `system-db:local`). Without the profile, user dconf reads ignore the system database entirely.
- **Database location.** Write defaults to `/etc/dconf/db/local.d/<filename>` (naming matters for merge order; `00-` prefix for global defaults, `01-` for per-project overrides). After writing, run `dconf update` in the chrooted `%post` to compile the text files into the binary database. The compiled database is what GNOME actually reads.
- **Schema key paths:** `org.gnome.desktop.interface color-scheme`, `org.gnome.desktop.background picture-uri` and `picture-uri-dark`, `org.gnome.shell favorite-apps`.
- **Live ISO dconf:** `livesys-gnome` applies settings at live boot via `gsettings set` or sed/dconf; does not use the system db path. Disk images and installed targets need the explicit system db.

### Wallpaper

- **Both `picture-uri` and `picture-uri-dark` must be set.** GNOME uses `picture-uri` in light mode and `picture-uri-dark` in dark mode. Setting only one causes a blank desktop in the other mode.
- **Image files must be staged.** `adwaita-d.jpg` and `adwaita-l.jpg` are staged to `/usr/share/backgrounds/azurelinux/` in all targets. The dconf URIs reference that path: `file:///usr/share/backgrounds/azurelinux/adwaita-d.jpg`.
- **Wallpaper staging was initially missing from live ISO and live-disk kickstarts** (fixed in commit `8eb3e17`). dconf in `00-dark-mode` already pointed at those paths (commits `28dd697`, `0f1c41d`) but only `kiwi/azl-install.ks.in` had `mkdir` + `install -m 0644`. Live desktop therefore showed stock GNOME blue until staging landed on live/live-disk. Confirmed on run `29990996437` and QEMU wallpaper match (winner `adwaita-d`, corr_mean≈0.048 vs light negative; center RGB deep blue).
- **Do not introduce a new RPM solely for wallpaper** while closing polish issues. Research documented Fedora's three-package pattern (`*-backgrounds-base`, `*-backgrounds-gnome`, gschema override) and JXL preference, but product policy is existing assets + dconf only. A future branded default can still use Option A (inline assets) without a new RPM.
- Early product note: matching stock Adwaita is configuration-correct but visually generic. Staging the chosen JPEGs is still required so the URI is not a broken path.

### GDM autologin

- **Exactly one `[daemon]` section in `/etc/gdm/custom.conf`.** Appending a second `[daemon]` block creates ambiguous duplicate settings; GDM receives conflicting directives and may not autologin reliably.
- **Correct content:**
  ```ini
  [daemon]
  AutomaticLoginEnable=true
  AutomaticLogin=liveuser
  ```
- **`InitialSetupEnable=False` also belongs in `[daemon]`** as belt-and-suspenders for first-run suppression.
- **Live ISO:** `liveuser` created by `livesys-scripts` (hardcoded; not renameable without patching multiple scripts). GDM autologin set in kickstart `%post`.
- **qcow2:** `liveuser` pre-created at build time by the disk-image-specific `%post` block in the workflow (`useradd`/`passwd`). GDM autologin written to `/etc/gdm/custom.conf`. `livesys.service` has `ConditionKernelCommandLine=rd.live.image` and will **not** run from a disk image.
- **Installed system:** account created interactively by Anaconda TUI. No `rootpw` or `user --name` directive in rendered kickstarts. `kiwi/anaconda-launcher.sh` injects `--shell=/usr/bin/pwsh` into the generated `user` kickstart directive for the installer-created admin account.

### gnome-initial-setup suppression

- **File:** `/var/lib/gnome-initial-setup/.gnome-initial-setup-done` (empty file, user-specific path or system-wide depending on version). Create this in the `%post` for the target user account.
- **GDM side:** `InitialSetupEnable=False` in `[daemon]` section of `/etc/gdm/custom.conf`.
- **`livesys-gnome` creates the marker** for live sessions. Disk images and installed targets need it explicitly for `liveuser`/admin.

### GNOME dock favorites (GNOME Shell)

- **Key:** `org.gnome.shell favorite-apps` (array of `.desktop` file names).
- **Current dock order (left → right):** `com.github.sirredbeard.copilot-desktop-gtk.desktop` (Microsoft Copilot Flatpak), `microsoft-edge-canary.desktop`, `code-insiders.desktop`, `org.azurelinux.PowerShell.desktop`, `GitHub Copilot.desktop` (GitHub Copilot Tauri RPM; space in the id is real), `org.gnome.Nautilus.desktop`.
- **Live ISO:** `livesys-gnome` sed-patches the favorites list at session time. The kickstart must set `livesys_session="gnome"` in `/etc/sysconfig/livesys` — without this, `livesys-main`'s dispatch logic is a no-op (empty `livesys_session` skips `sessions.d/livesys-gnome`).
- **qcow2 and installed system:** write a dconf database file at `/etc/dconf/db/local.d/00-azl-desktop-defaults` (installer) / disk `%post` with the `favorite-apps` key. Run `dconf update` in `%post`.
- **`.desktop` files must be mode 644.** Mode 600 (from umask 077 in the Fedora 43 build container with `cp -v`) causes GNOME Shell to silently drop the entry from the dash. See `anaconda-kickstart-patterns.md`.
- **Microsoft Copilot Flatpak:** installed system-wide at image build via `scripts/install-copilot-desktop-flatpak.sh` (`org.gnome.Platform//50` from Flathub + app from the project's GitHub Pages remote). Live/qcow use `%post --nochroot` network; installer stages the OSTree under `/opt/azl-offline-extras/flatpak-system` and copies it into the target so offline install still gets the app and update remote.

### GNOME Software: polkit and update suppression

- **Polkit rule for DNF5 authorization.** `/etc/polkit-1/rules.d/49-azl-desktop-packagekit.rules` must permit both `org.rpm.dnf.v0.*` (DNF5, what this image uses) and `org.freedesktop.packagekit.*` (PackageKit namespace, which GNOME Software also queries). Without this, GNOME Software shows an "Authentication Required" dialog after login for `liveuser` (who has no password).
- **GNOME Software background update suppression.** Remove the GNOME Software autostart entry and disable the search provider to prevent background update checks that trigger the auth dialog. Write schema overrides in `/etc/dconf/db/local.d/`.
- **The `org.rpm.dnf.v0.*` namespace** is what the installed `dnf5` uses; PackageKit is not installed. The live ISO previously only permitted `org.freedesktop.packagekit.*`, which was the wrong namespace.

### Package exclusions

- **Exclude from `%packages`:** `gnome-tour`, `gnome-user-docs`, `yelp`, `yelp-libs`, `malcontent-control`.
- **`malcontent` (the backend) must stay.** It's a required dependency of GNOME Control Center; removing it breaks the local dependency solver. Only the parental-controls UI (`malcontent-control`) is excluded.
- **`cockpit-ws`** is present because `anaconda-live` → `anaconda-webui` pulls the cockpit stack. Removing it removes the live installer web UI path. Cockpit is Fedora-sourced here (not an AZL package). Final exclude-list handling is in `fedora-azl-repo-mixing.md` (including the 2026-07-26 correction that dropped the bad cockpit pin).

### GNOME keyring / PAM

- **Root cause of "Choose password for new keyring" dialog:** GDM autologin skips the normal PAM auth stack. `pam_gdm.so`'s `[success=ok default=1]` jumps past `-auth optional pam_gnome_keyring.so` in `/etc/pam.d/gdm-autologin`, so `pam_gnome_keyring.so` never runs in the auth stack. No password (not even empty) seeds a login keyring. Microsoft Edge Canary then calls `CreateCollection` on an empty Secret Service, triggering the dialog. Firefox handles a locked/unavailable Secret Service gracefully (in-memory fallback).
- **Fix:** add `auth optional pam_gnome_keyring.so` **after** where `pam_gdm.so`'s skip lands (before `pam_permit.so` line), plus `session optional pam_gnome_keyring.so auto_start` in the session stack:
  ```bash
  sed -i '/^auth.*pam_permit/i auth       optional    pam_gnome_keyring.so' /etc/pam.d/gdm-autologin
  sed -i '/^session.*postlogin/i session    optional    pam_gnome_keyring.so auto_start' /etc/pam.d/gdm-autologin
  ```

### PowerShell dock identity

Full write-up: `powershell-dock-identity.md`.

- **D-Bus session service file:** `assets/dbus/org.azurelinux.PowerShell.service`.
- **`azl-powershell-terminal`:** `gnome-terminal --app-id org.azurelinux.PowerShell --title=PowerShell -- /usr/bin/pwsh`.
- **Root cause of wrong dock indicator:** client fell back to `org.gnome.Terminal` when the custom server was not on the bus yet and no service file existed. Not a wrong `StartupWMClass` string.
- **Installed dash missing PowerShell entirely:** separate bug; mode 600 `.desktop` from umask 077 + `cp -v`. See `anaconda-kickstart-patterns.md`.
- **Known cosmetic remainder:** may still open as a separate Terminal-looking window rather than grouping under the PowerShell favorite.
- **Running-app dot** is hard to prove via QEMU screendump. Prefer SSH/title bar / D-Bus owner checks.
- **`intellihide`:** dash-to-dock hides when a window overlaps it.

### .NET launcher and Edit discovery

- `.NET` desktop entry: `dotnet-cli-first-run.md` (invalid `Exec` quoting fixed via `azl-dotnet-terminal`).
- Edit desktop entry: `edit-desktop-missing.md`.
- Admin login shell: `admin-default-shell-pwsh.md` (`anaconda-launcher.sh --shell=/usr/bin/pwsh`).

### Fedora update filtering on installed systems

- **Fedora exclusion list must be persisted in installed repo files.** Build-time `excludepkgs=` on kickstart `repo` lines only applies during image construction. Without persisting the same exclusions into `/etc/yum.repos.d/azl-desktop-fedora.repo`, GNOME Software offers Fedora updates that replace AZL-owned packages (e.g. systemd, sudo, D-Bus). Use `sed` to inject the exclusion list into the installed repo file in `%post`.

### Fedora `fedora-logos` vs `azurelinux-logos`

- Both ISOs carry `fedora-logos` (from Fedora's `anaconda-webui` → `anaconda-live` chain). `azurelinux-logos` conflicts with `fedora-logos`. Current policy: both paths align on `fedora-logos`. The live installer environment shows Fedora branding; the installed system shows AZL branding. See `anaconda-kickstart-patterns.md`.

## What didn't work

- **Persisting only `org.freedesktop.packagekit.*` in polkit:** wrong namespace for DNF5; GNOME Software still prompted for auth.
- **Adding a second `[daemon]` section to `gdm-autologin.conf`:** duplicate settings caused unreliable autologin.
- **Using `livesys-gnome` to persist disk-image settings:** conditioned on `rd.live.image`; never runs on qcow2 or installed system. All disk-image settings must be written explicitly at build time.
- **Setting only `picture-uri` without `picture-uri-dark`:** dark mode shows blank desktop background.

## Current state

All three kickstarts and installer templates:
- `00-dark-mode` dconf file: `color-scheme='prefer-dark'`, `picture-uri`, `picture-uri-dark` pointing to staged `adwaita-d.jpg`/`adwaita-l.jpg`.
- `01-azl-desktop-favorites` dconf file (disk/installed only): five custom favorites including PowerShell desktop ID.
- `/etc/gdm/custom.conf`: single `[daemon]` section, `AutomaticLoginEnable=true`, `AutomaticLogin=liveuser`, `InitialSetupEnable=False`.
- `gnome-initial-setup-done` marker for `liveuser`.
- Polkit rule: both `org.rpm.dnf.v0.*` and `org.freedesktop.packagekit.*` permitted for active local wheel users.
- PAM keyring: `pam_gnome_keyring.so` inserted past `pam_gdm.so`'s skip point.
- `gnome-tour`, `gnome-user-docs`, `yelp`, `yelp-libs`, `malcontent-control` excluded from `%packages`.
- `livesys_session="gnome"` set in `/etc/sysconfig/livesys` for live ISO.
- Wallpaper files staged to `/usr/share/backgrounds/azurelinux/`. QEMU boot confirmed: dark wallpaper avg=(12,30,70) matching `adwaita-d.jpg`.
- Static validation: live ISO 34/34 pass, qcow2 15/15 pass, installer ISO 10/10 pass (run 30118396215).

## References

On-device checks (2026-07-22): Super-key VNC diff ~45% pixels changed (session alive); boot OCR zero early-boot text until desktop UI; wallpaper match still dark Adwaita that iteration.
- `powershell-dock-identity.md` — full D-Bus/app-id analysis
- `dotnet-cli-first-run.md` — launcher Exec fix and first-run noise
- `edit-desktop-missing.md` — Edit overview discovery
- `admin-default-shell-pwsh.md` — installer admin shell
- `anaconda-kickstart-patterns.md` — asset staging permissions, %post patterns
- `fedora-azl-repo-mixing.md` — cockpit / Fedora update filtering
- `deliverable-polish-validation.md` - AQ sessions for this batch