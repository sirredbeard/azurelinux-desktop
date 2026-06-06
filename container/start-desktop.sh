#!/bin/bash
set -euo pipefail

mkdir -p /run/xrdp /run/dbus
chmod 1777 /run/xrdp
chown xrdp:xrdp /run/xrdp

# Session runtime dir, owned by the desktop user (dconf, pipewire sockets,
# WebKit all live here; a root-owned dir makes them fail or crash).
deskuid="$(id -u deskuser)"
mkdir -p "/run/user/$deskuid"
chown deskuser:deskuser "/run/user/$deskuid"
chmod 700 "/run/user/$deskuid"

if [ ! -S /run/dbus/system_bus_socket ]; then
    dbus-daemon --system --fork
fi

/usr/sbin/xrdp-sesman --nodaemon &
/usr/sbin/xrdp --nodaemon &

echo "XRDP desktop ready on port 3389"
wait -n
