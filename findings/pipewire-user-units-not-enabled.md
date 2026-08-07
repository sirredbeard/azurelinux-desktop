# Screencast fails: PipeWire user units not enabled

**Status:** Fixed and confirmed on bare metal. `pipewire.socket`,
`pipewire-pulse.socket`, and `wireplumber.service` were active in the
`azurelinux` session; runtime sockets under `/run/user/1000`. Image
paths still carry the preset + wants for new installs.

## Observed

Bare-metal nested install:

- GNOME Screen Capture: "Screencast failed to start"
- Journal:

```
xdg-desktop-portal: Failed connect to PipeWire: Couldn't connect to PipeWire
org.gnome.Shell.Screencast: Failed to start recorder: ... Couldn't connect pipewire context
gnome-shell: Screencast failed during phase STARTUP: ... Couldn't connect pipewire context
```

Packages are installed: `pipewire`, `pipewire-pulseaudio`,
`wireplumber`, `xdg-desktop-portal-gnome`. Unit files exist under
`/usr/lib/systemd/user/`.

What was missing: enablement symlinks under `/etc/systemd/user/`.

- Host Fedora (works): `sockets.target.wants/pipewire.socket`,
  `pipewire-pulse.socket`, `pipewire.service.wants/wireplumber.service`
- Nested AZL (broken): only `dbus.socket`

No `pipewire` / `wireplumber` lines in the user journal. The daemon
never starts.

## Root cause

User unit presets come from Azure Linux `azurelinux-release-common`,
not from Fedora's `redhat-systemd-presets-common`.

`/usr/lib/systemd/user-preset/90-default-user.preset` on Azure Linux
only has:

```
enable dbus.socket
enable dbus-broker.service
```

Fedora's preset also has:

```
enable pipewire.socket
enable pipewire-pulse.socket
enable wireplumber.service
```

Combined with `99-default-disable.preset` to `disable *`, PipeWire user
sockets stay disabled unless something explicitly enables them.

## Fix

Carry Fedora's PipeWire user preset enables into every image path
(live, disk, installer `%post` / KIWI `config.sh`), without replacing
the whole AZL preset file:

```bash
mkdir -p /etc/systemd/user/sockets.target.wants \
         /etc/systemd/user/pipewire.service.wants
ln -sf /usr/lib/systemd/user/pipewire.socket \
  /etc/systemd/user/sockets.target.wants/pipewire.socket
ln -sf /usr/lib/systemd/user/pipewire-pulse.socket \
  /etc/systemd/user/sockets.target.wants/pipewire-pulse.socket
ln -sf /usr/lib/systemd/user/wireplumber.service \
  /etc/systemd/user/pipewire.service.wants/wireplumber.service
ln -sf /usr/lib/systemd/user/wireplumber.service \
  /etc/systemd/user/pipewire-session-manager.service
```

Or drop a small
`/usr/lib/systemd/user-preset/80-azurelinux-desktop-pipewire.preset`
with the three `enable` lines.

## Verify

```bash
systemctl --user is-enabled pipewire.socket wireplumber.service
systemctl --user is-active pipewire.service wireplumber.service
ls -l /run/user/$UID/pipewire-0
# GNOME Screen Capture → Record should start without the failure toast
```
