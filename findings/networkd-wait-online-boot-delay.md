# systemd-networkd-wait-online blocks boot for 2 minutes

## Symptom

On a bare metal install, `systemctl --failed` always shows
`systemd-networkd-wait-online.service` failed, and
`systemd-analyze` shows it as the single largest boot-time cost:

```
Startup finished in 6.450s (firmware) + 1.433s (loader) + 766ms (kernel) + 4.395s (initrd) + 2min 26.418s (userspace) = 2min 39.464s
graphical.target reached after 2min 6.153s in userspace.
```

```
2min 108ms systemd-networkd-wait-online.service
```

`journalctl` confirms the unit times out waiting for connectivity it
was never going to get:

```
systemd-networkd-wait-online[914]: Timeout occurred while waiting for network connectivity.
systemd-networkd-wait-online.service: Failed with result 'exit-code'.
```

## Root cause

This image uses NetworkManager for networking, not systemd-networkd.
The kickstart already said so in a comment
(`kickstart/azurelinux-desktop-live.ks`: "NetworkManager only, not
systemd-networkd") and only lists `NetworkManager` in
`services --enabled=`. But `--enabled=`/`--disabled=` on the `services`
kickstart command only adds to or removes from systemd's own preset
list - it does not touch units that ride in enabled by the preset on
their own. `systemd-networkd.service` and
`systemd-networkd-wait-online.service` are both enabled by systemd's
default preset regardless of this being a NetworkManager-only image,
so the wait-online unit runs on every boot, has nothing to wait for
(networkd never configures any interface here), and burns its full
2 minute timeout before `graphical.target` can be reached.

This was previously seen and noted as "QEMU/user-net noise" during
installer verification (`findings/installer-iso-2026.08.07-verify.md`)
but not root-caused or fixed. On real bare metal hardware it is not
noise - it reproduces on every single boot and roughly doubles time to
desktop.

## Fix

Explicitly disable both units instead of only enabling NetworkManager:

- `kickstart/azurelinux-desktop-live.ks`: added
  `systemd-networkd,systemd-networkd-wait-online` to the `services
  --disabled=` list (live ISO + disk images).
- `kiwi/config.sh`: `systemctl disable` for both units in the
  installer's own live/offline tree build (installer ISO's live
  environment).
- `kiwi/post-install.sh`: `systemctl disable` for both units on the
  installed target after Anaconda runs.

The canary container has no systemd runtime (`systemd=false`,
non-bootable) and never enables or runs services, so there is nothing
to change there.

A follow-up review caught two more places the installed target was
still contradicting the NetworkManager-only intent:

- `kiwi/azl-install.ks.in` (the installed target's own Anaconda
  kickstart, run via `%post`) explicitly listed `systemd-networkd` in
  its `services --enabled=` line - enabling the unit in the same
  pipeline that `post-install.sh` then disables. Removed it from that
  list; `systemd-resolved` stays (NetworkManager uses it as the DNS
  stub resolver backend, confirmed via `resolv.conf` -> `/run/systemd/
  resolve/stub-resolv.conf` on a running install).
- `post-install.sh` was installing a real networkd `.network` file
  (`20-wired-dhcp.network`, DHCP for `en*`/`eth*`) into the installed
  target's `/etc/systemd/network/`. With the unit disabled this file
  was inert, but it was still a live risk: any future change that
  re-enables `systemd-networkd` (a preset refresh, a package
  reinstall) would immediately have it fighting NetworkManager over
  the same wired interface. Dropped the install step and the
  now-orphaned `assets/systemd/network/20-wired-dhcp.network` source.

This `.network` file and the `systemd-networkd`/`systemd-resolved`
package set are unrelated to the *installer's own* live/build
environment (`kiwi/azl-desktop-installer.kiwi`'s own package and file
staging) - that environment is out of scope for this fix and was left
unchanged, matching Microsoft's own upstream installer pattern it was
adapted from.

## Verified

- `systemd-analyze` isolated `systemd-networkd-wait-online.service` as
  the ~2 minute cost on a running bare metal install.
- `bash -n` clean on `kiwi/config.sh` and `kiwi/post-install.sh` after
  the edits.

## Status

Fix shipped for live ISO/disk images and the installer target. Not yet
re-verified end to end on a fresh image build/install (would need a
new ISO build + boot timing comparison to confirm the ~2 minute
recovery in practice).
