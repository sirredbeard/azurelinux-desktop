# dnf update Avahi and Remmina conflict

**Status: fixed and verified**

## Symptom

On 2026-10-06, `sudo dnf update` stopped with an Avahi family conflict:

```text
installed package avahi-ui-gtk3-0.9~rc2-6.fc43.x86_64 requires avahi-glib = 0.9~rc2-6.fc43
installed package remmina-1.4.41-1.fc43.x86_64 requires libavahi-ui-gtk3.so.0
Azure Linux offers avahi-glib and avahi-libs 0.9~rc2-9.azl4
```

`avahi-ui-gtk3` is Fedora-only in the mixed desktop repositories. Its exact
EVR dependency keeps the Avahi libraries on the Fedora build as well.

## Fix

Treat the shared Avahi package family as Fedora-owned by excluding it from
the Azure Linux base repository. The list covers the runtime, tools, and
development siblings so a later update cannot split the family:

```text
avahi,avahi-autoipd,avahi-compat-howl,avahi-compat-howl-devel,
avahi-compat-libdns_sd,avahi-compat-libdns_sd-devel,avahi-devel,
avahi-dnsconfd,avahi-glib,avahi-glib-devel,avahi-gobject,
avahi-gobject-devel,avahi-libs,avahi-tools
```

The exclusion is carried in the live kickstart, the installer `kiwi/config.sh`,
the canary/shared repo asset, and the installed Azure repo rewrite. The Fedora
exclusion list does not change.

## Verification

The host already had the Fedora Avahi family installed, so the policy change
needed no package transaction. After adding the Azure repo exclusion,
`sudo dnf update` completed successfully:

```text
Repositories loaded.
Nothing to do.
```

The installed packages remain on Fedora's matching builds:

```text
avahi           0:0.9~rc2-6.fc43    Fedora Project
avahi-glib      0:0.9~rc2-6.fc43    Fedora Project
avahi-libs      0:0.9~rc2-6.fc43    Fedora Project
avahi-ui-gtk3   0:0.9~rc2-6.fc43    Fedora Project
remmina         0:1.4.41-1.fc43     Fedora Project
```
