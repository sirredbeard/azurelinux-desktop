#!/bin/bash
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
eval "$(dbus-launch --sh-syntax)"
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE

# Runtime dir for the session (pipewire sockets live here; the audio stack
# itself starts from /etc/xdg/autostart/azurelinux-audio.desktop).
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# WebKit (GNOME Web) cannot create its bubblewrap sandbox inside the
# container (no user namespaces); run it unsandboxed.
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export WEBKIT_FORCE_SANDBOX=0

exec startxfce4
