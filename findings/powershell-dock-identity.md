# PowerShell dock identity

**Status:** Resolved for launcher/app-id wiring. Known cosmetic remainder:
window can still group under the ordinary Terminal icon in some sessions.

## Observed failure

PowerShell opened a terminal titled `PowerShell`, but the live-session dock
active indicator sat under the ordinary Terminal icon. It looked like GNOME
Terminal owned the window instead of the PowerShell favorite.

On the **installed** system, PowerShell was sometimes missing from the dash
entirely even though `favorite-apps` listed it. That second failure was a
different root cause (mode 600 desktop file). See Asset permissions below
and `anaconda-kickstart-patterns.md`.

## Root cause A - D-Bus activation race (identity)

GNOME Terminal on Wayland sets the window app id from the server process
(`gnome-terminal-server --app-id ...` → `xdg_toplevel.set_app_id` → Mutter
WM_CLASS). GNOME Shell matches that to a desktop file via `StartupWMClass`
first (`shell-window-tracker.c` / `shell-app-system.c`).

The old helper backgrounded the custom server and immediately started the
client:

```bash
/usr/libexec/gnome-terminal-server --app-id org.azurelinux.PowerShell &
exec gnome-terminal --app-id org.azurelinux.PowerShell --title=PowerShell -- /usr/bin/pwsh
```

If the server had not registered on the session bus yet and no D-Bus service
file existed, activation failed and the client fell back to the default
`org.gnome.Terminal` server. Mutter then advertised `org.gnome.Terminal`,
and the dock grouped under Terminal.

This is a race / activation problem, not a wrong `StartupWMClass` string.

## Root cause B - mode 600 desktop file (missing from installed dash)

Installer builds packed assets through `assets.tar.gz` inside a Fedora 43
container with umask 077. Kickstart used `cp -v`, which preserved mode 600.
GNOME Shell runs as the user, cannot read the desktop file, and silently
drops it from favorites/overview.

Live ISO was unaffected (workspace checkout keeps 644). Fix: `install -m
0644` / `install -m 0755` everywhere. Full note in
`anaconda-kickstart-patterns.md`.

## Resolution (identity)

D-Bus session service + simplified launcher (Option A):

```ini
# /usr/share/dbus-1/services/org.azurelinux.PowerShell.service
[D-BUS Service]
Name=org.azurelinux.PowerShell
Exec=/usr/libexec/gnome-terminal-server --app-id org.azurelinux.PowerShell
```

```sh
# /usr/local/bin/azl-powershell-terminal
exec gnome-terminal --app-id org.azurelinux.PowerShell --title=PowerShell -- /usr/bin/pwsh
```

```ini
# org.azurelinux.PowerShell.desktop
Exec=/usr/local/bin/azl-powershell-terminal
StartupWMClass=org.azurelinux.PowerShell
```

Changed files:

- `assets/dbus/org.azurelinux.PowerShell.service` (new)
- `assets/bin/azl-powershell-terminal`
- live, live-disk, and installer kickstart templates

dconf lock for `favorite-apps` is **not** required for a fresh installed
user. System-db default + `dconf update` is enough for new accounts. A lock
would only freeze existing-user overrides.

## What did not work / not pursued

- Replacing GNOME Terminal with another emulator only to fix dock grouping.
- Assuming `StartupWMClass` alone was wrong without checking D-Bus ownership.
- Relying on QEMU screendump to prove the running-app dot (too small / low
  contrast under software rendering).

## Verification

- Static: helper, desktop entry, D-Bus service present; `shellcheck` clean.
- QEMU: window title bar shows `PowerShell` (app-id path live).
- Installed dash: all five favorites after permission fix
  (`dconf read` / `gsettings get` over SSH).
- Manual QA 2026-07-25: still can open as a separate Terminal-looking window
  rather than grouping under the PowerShell favorite. Documented cosmetic
  remainder given gnome-terminal's D-Bus architecture. Left as-is.

## Runtime debug checklist (if grouping regresses)

In a running Wayland session:

1. Confirm D-Bus owner for `org.azurelinux.PowerShell`.
2. Inspect `gnome-terminal-server` command line for the custom app-id.
3. Read the window application id from GNOME Shell / introspection tools.
4. Confirm desktop file mode is world-readable and listed in
   `favorite-apps`.

## References

- GNOME Mutter `meta-wayland-xdg-shell.c` (`xdg_toplevel_set_app_id`)
- GNOME Shell `shell-window-tracker.c`, `shell-app-system.c`
- `gnome-desktop-defaults.md`
- `anaconda-kickstart-patterns.md` (asset modes)
- Logs: `logs/live-iso-vnc-behavior-2026-07-22.log`
