# GNOME desktop defaults

**Status:** Implemented in kickstart/kiwi assets

## Context

The project configures GNOME with dark mode, custom wallpaper, a
specific dock favorites list, autologin, and keyring unlocking.

* Live ISO applies settings at session time via `livesys-gnome`
* qcow2 and installed system need those settings at image-build time in
  the system dconf database and config files

The two mechanisms do not overlap. `livesys-gnome` is conditioned on
`rd.live.image` and will not run on disk images or installed systems.

## dconf system database

* Profile file required: `/etc/dconf/profile/user` must exist and
  reference the `local` system db (`system-db:local`). Without it, user
  dconf ignores the system database.
* Write defaults to `/etc/dconf/db/local.d/<filename>` (`00-` for global
  defaults, `01-` for project overrides). Run `dconf update` in the
  chrooted `%post` to compile the binary database.
* Schema key paths: `org.gnome.desktop.interface color-scheme`,
  `org.gnome.desktop.background picture-uri` and `picture-uri-dark`,
  `org.gnome.shell favorite-apps`.
* Live ISO: `livesys-gnome` applies settings at live boot. Disk images
  and installed targets need the explicit system db.

## Wallpaper

* Both `picture-uri` and `picture-uri-dark` must be set. GNOME uses one
  in light mode and one in dark mode. Setting only one causes a blank
  desktop in the other mode.
* Image files must be staged: `adwaita-d.jpg` and `adwaita-l.jpg` go to
  `/usr/share/backgrounds/azurelinux/`. dconf URIs reference that path.
* Wallpaper staging was initially missing from live ISO and live-disk
  kickstarts (fixed in commit `8eb3e17`). dconf already pointed at those
  paths but only the installer kickstart had the install step. Live
  desktop showed stock GNOME blue until staging landed.
* Do not introduce a new RPM solely for wallpaper. Product policy is
  existing assets + dconf only.

## GDM autologin

* Exactly one `[daemon]` section in `/etc/gdm/custom.conf`. Appending a
  second block creates ambiguous duplicate settings.
* Correct content:

  ```ini
  [daemon]
  AutomaticLoginEnable=true
  AutomaticLogin=liveuser
  ```

* `InitialSetupEnable=False` also belongs in `[daemon]`.
* Live ISO: `liveuser` created by `livesys-scripts` (hardcoded). GDM
  autologin set in kickstart `%post`.
* qcow2: `liveuser` pre-created at build time. `livesys.service` has
  `ConditionKernelCommandLine=rd.live.image` and will not run from a
  disk image.
* Installed system: account created interactively by Anaconda TUI.
  `kiwi/anaconda-launcher.sh` injects `--shell=/usr/bin/pwsh` into the
  generated `user` kickstart directive.

## gnome-initial-setup suppression

* File: `/var/lib/gnome-initial-setup/.gnome-initial-setup-done`
* GDM side: `InitialSetupEnable=False` in `[daemon]`
* `livesys-gnome` creates the marker for live sessions. Disk images and
  installed targets need it explicitly for `liveuser`/admin.

## GNOME dock favorites

* Key: `org.gnome.shell favorite-apps` (array of `.desktop` file names)
* Current dock order (left to right):
  `com.github.sirredbeard.copilot-desktop-gtk.desktop`,
  `microsoft-edge-canary.desktop`,
  `code-insiders.desktop`,
  `org.azurelinux.PowerShell.desktop`,
  `GitHub Copilot.desktop` (space in the id is real),
  `org.gnome.Nautilus.desktop`
* Live ISO: `livesys-gnome` sed-patches the favorites list at session
  time. The kickstart must set `livesys_session="gnome"` in
  `/etc/sysconfig/livesys` or the dispatch is a no-op.
* qcow2 and installed system: write dconf at
  `/etc/dconf/db/local.d/00-azl-desktop-defaults` (or disk `%post`
  equivalent) and run `dconf update`.
* `.desktop` files must be mode 644. Mode 600 causes GNOME Shell to
  silently drop the entry. See `anaconda-kickstart-patterns.md`.
* Microsoft Copilot Flatpak: system-wide OSTree. Do not
  `flatpak install` into Anaconda `/mnt/sysimage` during
  `%post --nochroot` (hung 90+ minutes on GHA). Pattern:
  `scripts/prestage-copilot-flatpak-system.sh` fills a prestage tree
  before livemedia/kiwi; kickstart only copies into target
  `/var/lib/flatpak`.

## Microsoft Copilot hardware key

* Firmware chord: `KEY_LEFTMETA` + `KEY_LEFTSHIFT` + `KEY_F23`
  (scancode `0x6e`). Not a lone keycode. Newer xkeyboard-config maps it
  to `XF86Assistant`; GNOME has no built-in handler.
* Binding: system dconf custom shortcut under
  `org.gnome.settings-daemon.plugins.media-keys`:
  * path: `/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/`
  * `binding='<Shift><Super>F23'`
  * `command='flatpak run com.github.sirredbeard.copilot-desktop-gtk'`
* Written in live `00-dark-mode` dconf, installer
  `00-azl-desktop-defaults`, and disk-image favorites file.
  User-overridable in Settings.

## GNOME Software: polkit and update suppression

* Polkit rule for DNF5 authorization:
  `/etc/polkit-1/rules.d/49-azl-desktop-packagekit.rules` must permit
  both `org.rpm.dnf.v0.*` (DNF5) and `org.freedesktop.packagekit.*`
  (PackageKit namespace, which GNOME Software also queries). Without
  this, GNOME Software shows "Authentication Required" after login for
  `liveuser` (who has no password).
* Suppress GNOME Software background update checks (remove autostart,
  disable search provider) via schema overrides in
  `/etc/dconf/db/local.d/`.
* The installed stack uses `dnf5` (`org.rpm.dnf.v0.*`). PackageKit is
  not installed. The live ISO previously only permitted the PackageKit
  namespace, which was wrong.

## Package exclusions

* Exclude from `%packages`: `gnome-tour`, `gnome-user-docs`, `yelp`,
  `yelp-libs`, `malcontent-control`.
* `malcontent` (the backend) must stay. It is required by GNOME Control
  Center. Only the parental-controls UI is excluded.
* `cockpit-ws` is present because `anaconda-live` → `anaconda-webui`
  pulls the cockpit stack. Removing it removes the live installer web UI
  path. Final exclude-list handling is in `fedora-azl-repo-mixing.md`.

## GNOME keyring / PAM

Root cause of "Choose password for new keyring" dialog: GDM autologin
skips the normal PAM auth stack. `pam_gdm.so`'s
`[success=ok default=1]` jumps past
`-auth optional pam_gnome_keyring.so` in `/etc/pam.d/gdm-autologin`, so
`pam_gnome_keyring.so` never runs in the auth stack. No password seeds a
login keyring. Microsoft Edge Canary then calls `CreateCollection` on an
empty Secret Service and triggers the dialog. Firefox handles a locked
Secret Service more gracefully.

Fix: add `auth optional pam_gnome_keyring.so` after where `pam_gdm.so`'s
skip lands (before `pam_permit.so`), plus
`session optional pam_gnome_keyring.so auto_start` in the session stack:

```bash
sed -i '/^auth.*pam_permit/i auth       optional    pam_gnome_keyring.so' /etc/pam.d/gdm-autologin
sed -i '/^session.*postlogin/i session    optional    pam_gnome_keyring.so auto_start' /etc/pam.d/gdm-autologin
```

## PowerShell dock identity

Full write-up: `powershell-dock-identity.md`.

* D-Bus session service: `assets/dbus/org.azurelinux.PowerShell.service`
* Helper: `gnome-terminal --app-id org.azurelinux.PowerShell ...`
* Wrong dock indicator: client fell back to `org.gnome.Terminal` when
  the custom server was not on the bus
* Installed dash missing PowerShell: mode 600 `.desktop` from umask 077
  + `cp -v`
* Known cosmetic remainder: may still open as a separate Terminal-looking
  window

## .NET launcher and Edit discovery

* .NET desktop entry: `dotnet-cli-first-run.md`
* Edit desktop entry: `edit-desktop-missing.md`
* Admin login shell: `admin-default-shell-pwsh.md`

## Fedora update filtering on installed systems

Fedora exclusion list must be persisted in installed repo files.
Build-time `excludepkgs=` on kickstart `repo` lines only applies during
image construction. Without the same exclusions in
`/etc/yum.repos.d/azl-desktop-fedora.repo`, GNOME Software offers Fedora
updates that replace AZL-owned packages. Inject the exclusion list into
the installed repo file in `%post`.

## fedora-logos vs azurelinux-logos

Both ISOs carry `fedora-logos` (from `anaconda-webui` → `anaconda-live`).
`azurelinux-logos` conflicts with `fedora-logos`. Current policy: both
paths align on `fedora-logos`. The live installer environment shows
Fedora branding; the installed system shows AZL branding. See
`anaconda-kickstart-patterns.md`.

## What did not work

* Persisting only `org.freedesktop.packagekit.*` in polkit: wrong
  namespace for DNF5
* Adding a second `[daemon]` section: unreliable autologin
* Using `livesys-gnome` to persist disk-image settings: never runs
  without `rd.live.image`
* Setting only `picture-uri` without `picture-uri-dark`: blank desktop
  in dark mode

## Current state

All three kickstarts and installer templates:

* `00-dark-mode` dconf: `color-scheme='prefer-dark'`, both picture URIs
  to staged Adwaita JPEGs
* Favorites dconf for disk/installed: custom favorites including
  PowerShell desktop ID
* `/etc/gdm/custom.conf`: single `[daemon]` section, autologin,
  `InitialSetupEnable=False`
* `gnome-initial-setup-done` marker for `liveuser`
* Polkit rule: both DNF5 and PackageKit namespaces for active local wheel
* PAM keyring past `pam_gdm.so`'s skip point
* Tour/docs/yelp/malcontent-control excluded from `%packages`
* `livesys_session="gnome"` for live ISO
* Wallpaper files staged under `/usr/share/backgrounds/azurelinux/`

## Related

* `powershell-dock-identity.md`
* `dotnet-cli-first-run.md`
* `edit-desktop-missing.md`
* `admin-default-shell-pwsh.md`
* `anaconda-kickstart-patterns.md`
* `fedora-azl-repo-mixing.md`
* `deliverable-polish-validation.md`
