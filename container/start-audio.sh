#!/bin/sh
# Sequenced pipewire stack for the XFCE session: core first, then the
# session manager, then the pulse shim, then the xrdp sink module loader
# (XDG autostart ordering is nondeterministic, so the loader runs here,
# after the daemon is provably up). sesman's XRDP_* env vars are inherited.
pipewire &
sleep 1
wireplumber &
sleep 1
pipewire-pulse &
sleep 2

for s in /usr/libexec/pipewire-module-xrdp/load_pw_modules.sh \
         /usr/local/libexec/pipewire-module-xrdp/load_pw_modules.sh; do
    if [ -x "$s" ]; then
        sh "$s"
        break
    fi
done

# Keep the autostart entry's process alive as the stack's parent.
wait
