# Screencast fails: PipeWire user units not enabled

**Status:** Fixed and **confirmed on bare metal** (2026-08-03 G1 gather).
`pipewire.socket`, `pipewire-pulse.socket`, and `wireplumber.service` were
active in the `azurelinux` session; runtime sockets under `/run/user/1000`.
Image paths still carry the preset + wants for new installs.

## Observed

Bare-metal nested install, 2026-08-03 afternoon session:

* GNOME Screen Capture notification: **Screencast failed to start**
* Screenshot: `~/Pictures/Screenshots/Screenshot From 2026-08-03 13-11-55.png`
  (copied from nested `azurelinux` home)

## Evidence (journal, boot `ad23be53…`, 13:09 session)

```
xdg-desktop-portal: Failed connect to PipeWire: Couldn't connect to PipeWire
org.gnome.Shell.Screencast: Failed to start recorder: ... Couldn't connect pipewire context
gnome-shell: Screencast failed during phase STARTUP: ... Couldn't connect pipewire context
```

Packages **are** installed: `pipewire`, `pipewire-pulseaudio`,
`wireplumber`, `xdg-desktop-portal-gnome` (Fedora 43 builds). Unit files
exist under `/usr/lib/systemd/user/` (`pipewire.socket`,
`pipewire-pulse.socket`, `wireplumber.service`).

What is missing on the installed system: the **enablement symlinks** that
Fedora creates under `/etc/systemd/user/`:

| Host Fedora (works) | Nested AZL (broken) |
| --- | --- |
| `sockets.target.wants/pipewire.socket` | only `dbus.socket` |
| `sockets.target.wants/pipewire-pulse.socket` | (absent) |
| `pipewire.service.wants/wireplumber.service` | (absent) |

No `pipewire` / `wireplumber` lines appear in the user journal at all —
the daemon never starts.

## Root cause

User unit presets come from **Azure Linux** `azurelinux-release-common`,
not from Fedora's `redhat-systemd-presets-common`:

`/usr/lib/systemd/user-preset/90-default-user.preset` on AZL only has:

```
enable dbus.socket
enable dbus-broker.service
```

Fedora's preset (host) also has:

```
enable pipewire.socket
enable pipewire-pulse.socket
enable wireplumber.service
```

Combined with `99-default-disable.preset` → `disable *`, PipeWire user
sockets stay disabled unless something explicitly enables them.

RPM `%post` scriptlets call
`systemd-update-helper install-user-units pipewire.socket` etc., but on
this image those links are still absent under `/etc/systemd/user/` after
install — preset policy wins / helper does not leave the Fedora-style
wants links. Result: GNOME session has no PipeWire socket, portals and
Screencast fail immediately.

## Fix (proposed)

Carry Fedora's PipeWire user preset enables into every image path
(live, disk, installer `%post` / KIWI `config.sh`), without replacing the
whole AZL preset file:

```bash
mkdir -p /etc/systemd/user/sockets.target.wants \
         /etc/systemd/user/pipewire.service.wants
ln -sf /usr/lib/systemd/user/pipewire.socket \
  /etc/systemd/user/sockets.target.wants/pipewire.socket
ln -sf /usr/lib/systemd/user/pipewire-pulse.socket \
  /etc/systemd/user/sockets.target.wants/pipewire-pulse.socket
ln -sf /usr/lib/systemd/user/wireplumber.service \
  /etc/systemd/user/pipewire.service.wants/wireplumber.service
# optional alias used on Fedora:
ln -sf /usr/lib/systemd/user/wireplumber.service \
  /etc/systemd/user/pipewire-session-manager.service
```

Or drop a small `/usr/lib/systemd/user-preset/80-azurelinux-desktop-pipewire.preset`
(higher priority than 90/99) with the three `enable` lines.

## Verify

On installed system after fix + new user session:

```bash
systemctl --user is-enabled pipewire.socket wireplumber.service
systemctl --user is-active pipewire.service wireplumber.service
ls -l /run/user/$UID/pipewire-0
# GNOME Screen Capture → Record should start without the failure toast
```

## Related logs

* `findings/logs/azl-screencast-pipewire-20260803.txt`
* Full diag dir: `~/azl-work/bt-diag-20260803-132241/` (shared session pull)
