# Live ISO, qcow2, and installer parity audit

## Status

The first pass of this audit was from a known-good live ISO and an earlier
qcow2 artifact. The fixes were committed in `633cab7`.

The released `2026.07.20` qcow2 was then downloaded through
`scripts/Get-AzureLinuxDesktop.ps1`, reassembled, and verified against the
published SHA-256. Its mounted root, boot initramfs, package state, update
solver, and UEFI boot path are now verified below.

The released installer ISO was downloaded and verified the same way. Its
nested runtime root contains both rendered kickstarts, which have been
checked directly. An actual installed target from that ISO has not yet been
booted, so the installer result is configuration-verified rather than
runtime-verified.

The current released live ISO, qcow2, and installer ISO were downloaded
through `scripts/Get-AzureLinuxDesktop.ps1` and each passed its published
SHA-256 verification. The mounted live ISO and qcow2 have the same base
identity. Their canonical RPM inventories differ only by
`grub2-tools-extra` and `mtools`, both disk-image boot tooling.

The shared repository, Flatpak, polkit, GDM, and dark-mode configuration
trees match. The live ISO retains its `livesys` setup, while the qcow2
contains the disk-only EFI and one-shot grow-root setup plus the persisted
GNOME favorites override. Those are expected lifecycle differences, not
configuration drift.

The live ISO is not the same kind of system as the qcow2 or an installed
system. It boots with `rd.live.image` and runs `livesys` setup services.
The qcow2 and installer target are ordinary installed systems, so anything
that `livesys-gnome` does at boot must instead be persisted during image
construction.

## What was already the same

The earlier qcow2 had the shared static content expected from the live ISO:

- Azure Linux graphical assets and Plymouth theme files in the root
  filesystem.
- Flatpak configuration and Flathub setup.
- Custom desktop launchers and MIME defaults.
- Dark-mode defaults.
- Keyring setup.
- Most package content.

The gaps were not broad missing-content failures. They were mostly
configuration timing and lifecycle failures: settings present in the live
boot path but never persisted into the disk image.

## Flatpak SELinux compatibility across image formats

**Current installer fix:** a real standard installation attempt exposed that
the offline repository was missing Flatpak's matching SELinux module. The
installer package list now explicitly includes it, and the constrained
offline transaction resolves with Azure's policy utility closure. The fix
still requires a published ISO build and a complete QEMU installation before
it can be called runtime-verified.

The installer failure exposed a package-boundary problem that is broader than
the installer. Azure Linux supplies the SELinux base and targeted policy,
while the desktop layer currently obtains Flatpak from Fedora.

Fedora's selected Flatpak build has an exact conditional dependency on its
matching `flatpak-selinux` package whenever `selinux-policy-targeted` is
installed. Its policy module is format 24. Azure Linux 4's policy tooling
accepts module formats 4 through 23, so the Fedora policy package cannot
be used safely with the Azure Linux policy base:

```text
libsepol.policydb_read: policydb module version 24 does not match my
version range 4-23
```

This is not limited to Anaconda. Direct inspection of the mounted live ISO
found the same Fedora `flatpak`, `flatpak-session-helper`, and
`flatpak-selinux` packages beside Azure Linux
`selinux-policy-43.4-4.azl4` and `selinux-policy-targeted-43.4-4.azl4`.
That makes the live image subject to the same incompatible package boundary,
even though its boot path has not yet exposed it as an installer transaction
failure. The installer runtime correctly contains the Azure policy packages
and Fedora Flatpak packages in its offline repository; it fails when
Anaconda attempts the target transaction.

Fedora 43's published Flatpak family was evaluated as a no-custom-RPM
alternative. Its `flatpak-selinux-1.16.1-1.fc43` module is format 22 and
matches Azure Linux's SELinux policy format. A narrow solver test also
resolved that Flatpak family with Azure's FUSE 3 packages.

The full rendered-installer solver rejected the combination. Fedora's
GNOME Software, XDG Desktop Portal, GVFS, GNOME Connections, and GRUB tools
all require the FUSE 4 ABI, while Fedora 43 Flatpak requires FUSE 3. Both
ABIs use mutually exclusive versions of the `fuse3-libs` RPM. GNOME Software
also requires the Fedora `flatpak-libs` package. The Fedora 43 fallback
therefore cannot coexist with the current Fedora desktop stack and was
reverted before release builds could consume it.

Azure Linux has an upstream `flatpak.spec`, but the public Azure Linux 4.0
repositories do not publish its RPMs. With custom RPMs ruled out, a safe
Flatpak-enabled image requires a published Azure-native Flatpak stack or a
supported upstream alignment of the Azure SELinux and FUSE bases. Until then,
the existing Fedora Flatpak stack remains an unresolved cross-image
compatibility issue and no release should claim it is fixed.

## Plymouth

**Observed problem:** the qcow2 showed the generic splash or text path even
though `/usr/share/plymouth/themes/azurelinux` existed in the installed root.

**Root cause:** the qcow2 initramfs contained Plymouth binaries but not the
Azure Linux theme assets or the Plymouth script renderer. The live ISO boot
initrd contained the theme `.plymouth` and `.script` files, logo, dots,
`script.so`, and virtio GPU support. ISO construction has a later
Lorax/dracut phase after kickstart `%post`; `livemedia-creator --make-disk`
did not.

**Fix:** the disk-image-only workflow now runs
`plymouth-set-default-theme azurelinux --rebuild-initrd` after the shared
post-install configuration. This puts the selected theme and renderer into
the image that actually boots.

**Verified in the released qcow2:** the boot initramfs contains
`usr/lib64/plymouth/script.so`, the Azure Linux `.plymouth` and `.script`
files, logo, and dots. The root has the same five Azure Linux Plymouth
assets as the live ISO.

## GDM autologin

**Observed problem:** GDM displayed `liveuser`, but did not reliably log in
automatically.

**Root cause:** the configuration appended a second `[daemon]` section to
`/etc/gdm/custom.conf`. GDM therefore received ambiguous duplicate settings.

**Fix:** the shared kickstart and both installer templates now replace the
configuration with one clean `[daemon]` section containing the automatic
login settings.

**Verified in the released qcow2:** `/etc/gdm/custom.conf` has one
`[daemon]` section and the expected `AutomaticLogin=liveuser`. The UEFI
smoke test reached and started `gdm.service`. Graphical autologin still needs
an interactive desktop session.

## Dock, welcome tour, and first-run behavior

**Observed problem:** the qcow2 dock fell back to stock favorites and could
show first-run behavior that the live USB did not.

**Root cause:** the live image writes GNOME Shell favorites, welcome-tour
suppression, GNOME Software preferences, and the initial-setup marker from
`livesys-gnome`. That service is correctly conditioned on `rd.live.image`,
so it never runs on a normal qcow2 or a system installed from the ISO.

**Fix:** the disk-image workflow now persists the equivalent dconf data and
`gnome-initial-setup-done` marker for `liveuser`. Both installer templates
received the same persistent configuration.

**Package policy:** `gnome-tour`, `gnome-user-docs`, `yelp`, `yelp-libs`,
and `malcontent-control` are explicitly excluded. Direct inspection showed
the known-good live ISO and earlier qcow2 did not contain Tour or Help.

`malcontent` remains installed. It is a required backend dependency of
GNOME Control Center. Removing it broke the local dependency solver. The
unwanted parental-controls UI is `malcontent-control`, which remains
excluded.

**Verified in the released qcow2:** the persistent dconf database contains
the five custom favorites and welcome suppression. The first-run marker
exists for `liveuser`. The unwanted Tour, Help, Yelp, and parental-controls
UI packages are absent.

**Still runtime-only:** start a GNOME session and confirm the dock and
welcome behavior render as expected.

## GNOME Software authentication and updates

**Observed problem:** GNOME Software asked for authorization after login and
the earlier qcow2 offered Fedora updates that would replace Azure Linux base
packages such as `sudo` and `systemd`.

**Root cause, authorization:** the existing polkit rule permitted
`org.freedesktop.packagekit.*`, but this image uses DNF5. GNOME Software's
actual authorization actions are `org.rpm.dnf.v0.*`; PackageKit is not
installed.

**Fix:** the polkit rule now permits both namespaces for active local wheel
users. The default account is configured for passwordless sudo, so this does
not create a password prompt it cannot satisfy.

**Root cause, updates:** Fedora repository priority/cost is not package
ownership. Fedora's newer builds remained valid candidates for installed
Azure Linux package names because the persisted Fedora repository file had
no `excludepkgs` list.

**Fix:** the complete verified Fedora exclusion list is now persisted into
the installed repo file. The build-time exclusions were expanded too. Solver
testing against the earlier qcow2 found and removed the remaining eligible
Azure replacements, including version-locked systemd, D-Bus, sudo,
firewalld, util-linux, and firmware siblings.

This intentionally leaves Fedora-owned desktop families, including glibc,
where Azure Linux cannot satisfy their ABI requirements. See
[package-sourcing-clawback.md](package-sourcing-clawback.md) for the
documented boundary decisions.

**Verified in the released qcow2:** a disposable, read-only
`dnf5 repoquery --upgrades` query was run against the mounted image with
`releasever=4.0`. It found only `cockpit-ws` and `cockpit-ws-selinux` from
Fedora updates. There were no Azure-owned base-package replacement
candidates.

The first solver attempt used `releasever=4` and received Azure repository
404 responses. That was a bad test invocation, not a broken image. The
image's repository template correctly expands to `4.0`.

## Cockpit

Cockpit is present because the live-media installation dependency chain is:
`anaconda-live` -> `anaconda-webui` -> `slitherer` -> `cockpit-ws`.
Removing `cockpit-ws` removes the live installer stack and a large dependent
set. It remains installed by design.

## Installer template parity

The standard and encrypted installer templates share the same desktop and
post-install configuration. Their intended difference is storage only:

- Standard defines EFI, `/boot`, LVM, swap, and root explicitly.
- Encrypted uses `autopart --type=lvm --encrypted`.

Both templates now receive the clean GDM configuration, persisted Fedora
package boundary, dconf favorites, welcome suppression, GNOME Software
preferences, initial-setup marker, and DNF5 polkit authorization.

The templates were compared outside their storage stanza and found to have
no other functional drift before the most recent changes. Rendered
kickstart validation remains pending.

## GRUB

An earlier disk image showed Ubuntu GRUB entries. `os-prober` had scanned
GitHub Actions runner disks during the privileged build.

The disk-image path now disables `os-prober`, regenerates `grub.cfg`, and
brands current and future BLS entries as Azure Linux Desktop. This was fixed
and committed separately in `29f8ab0`.

## Released qcow2 validation

The `2026.07.20` qcow2 validates the persistent disk-image path:

| Customization | Source and lifecycle | Released qcow2 result |
| --- | --- | --- |
| Plymouth | Lorax/dracut handles the live ISO; disk post-install rebuilds the initramfs | Azure theme and script renderer are in the boot initramfs |
| GDM | Live user is created at live boot; disk user is created in disk post-install | One valid autologin section for persistent `liveuser`; GDM started in QEMU |
| Dark mode, dock, welcome | `livesys-gnome` applies them at live boot; disk writes persistent dconf | Dark-mode database and favorites/welcome database are present |
| GNOME Software | Live setup changes session behavior; disk compiles the matching schema override and removes background entry points | Both update settings resolve to `false`; autostart is absent and the search provider is disabled |
| First-run behavior | Live account is ephemeral; disk account needs an explicit marker | `gnome-initial-setup-done` is present for `liveuser` |
| Keyring | Shared keyring unlock helper and autostart entry | Both files are present; session prompt behavior remains runtime-only |
| Flatpak and Flathub | Shared system configuration | Both roots contain the Flathub remote |
| Launchers and MIME | Shared system configuration | Edge, Code Insiders, PowerShell, Edit, and Copilot launchers exist; Edge Canary remains the HTTP/HTML default |
| Package boundary | Fedora excludes are persisted into the installed repo files | No Azure-owned replacement candidates in the released-image solver |
| Polkit | Shared DNF5 and PackageKit authorization rule | `49-azl-desktop-packagekit.rules` permits active local wheel users for both namespaces |
| Tour, Help, parental controls | Explicit package exclusions | Tour, user docs, Yelp, and `malcontent-control` are absent; required `malcontent` backend remains |
| GRUB and growroot | Disk-only configuration | No runner Ubuntu menu entries, BLS title is Azure Linux Desktop, and the growroot enablement symlink exists |

The headless UEFI test booted through shim, GRUB, kernel, systemd,
NetworkManager, and GDM. It timed out at the expected serial login prompt
without modifying the downloaded qcow2.

The current released qcow2 reached the serial login marker in 80 seconds
under KVM through `scripts/test-boot-smoke.sh`. The script is intentionally
qcow2-only: the live ISO's normal graphical boot entry does not enable a
serial console, so its graphical QEMU test is the appropriate validation
path rather than a serial-marker test.

## Released installer validation

The installer ISO has three nested layers:

```text
LiveOS/squashfs.img -> LiveOS/rootfs.img -> /root/azl-install{,-encrypted}.ks
```

Both rendered kickstarts are present in the final runtime root. Outside the
storage stanza, their functional configuration is identical. Standard uses
explicit EFI, `/boot`, LVM, swap, and root partitions. Encrypted uses
`autopart --type=lvm --encrypted`.

Both rendered kickstarts contain the same GDM, dconf, GNOME Software,
initial-setup, DNF5/PackageKit polkit, Fedora ownership, and package
exclusion configuration described above.

The installer launcher now matches its staged files exactly:

- `/usr/local/bin/install-azl` points to `anaconda-launcher.sh`.
- The launcher copies `/root/azl-install.ks` or
  `/root/azl-install-encrypted.ks` to `/run/install/ks.cfg`.
- Both released files exist and contain no unresolved `@@PACKAGES@@` marker.

This addresses the prior launcher failure, where the rendered filename did
not match the filename the launcher copied, leaving Anaconda without
`/run/install/ks.cfg`.

## Installer manual QA

The `2026.07.20` installer ISO was booted in QEMU with real OVMF firmware,
a fresh virtio target disk, GTK display, and serial logging.

The GRUB menu contained only `Install Azure Linux Desktop` and `Try Azure
Linux Desktop (Live)`. It did not contain Ubuntu entries from the build
runner. This confirms the `os-prober` hardening and Azure Linux Desktop
branding are reaching the installer boot path too.

Running `install-azl` and selecting the standard option printed the expected
EFI, `/boot`, LVM, swap, and root storage configuration before starting
Anaconda. The previous `cp: cannot stat '/root/azl-install.ks'` and missing
`/run/install/ks.cfg` errors did not recur.

## Build-container cleanup error

The new live ISO build completed Anaconda installation successfully but
logged a nonfatal exit-handler exception for missing `/usr/sbin/load_policy`.
That binary belongs to `policycoreutils`, which was absent from the minimal
Fedora build containers.

`policycoreutils` is now installed in the live ISO, disk-image, local qcow2,
and test qcow2 build environments. This removes the error at its source
without changing the image payload.

## Remaining runtime checks

1. Replace the pre-fix live ISO with the fresh release ISO and repeat the
   static live-to-qcow comparison.
2. Start a graphical qcow2 session to verify autologin, dock rendering,
   welcome suppression, keyring behavior, GNOME Software behavior, Flatpak,
   and DNF5 polkit in a real user session.
3. Run both installer selections to a target disk, then verify the resulting
   installed systems have the same persistent configuration and package
   boundary as the qcow2.
