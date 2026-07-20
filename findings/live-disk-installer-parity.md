# Live ISO, qcow2, and installer parity audit

## Status

The findings below are from direct inspection of the known-good live ISO and
the earlier qcow2 artifact. The fixes were committed in `633cab7`, but a
fresh local qcow2 has not yet completed the full mounted-filesystem and boot
verification. Treat the fixes as implemented, not yet fully validated in a
new artifact.

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

**Fresh-image verification pending:** inspect the new qcow2 initramfs and
boot it in QEMU.

## GDM autologin

**Observed problem:** GDM displayed `liveuser`, but did not reliably log in
automatically.

**Root cause:** the configuration appended a second `[daemon]` section to
`/etc/gdm/custom.conf`. GDM therefore received ambiguous duplicate settings.

**Fix:** the shared kickstart and both installer templates now replace the
configuration with one clean `[daemon]` section containing the automatic
login settings.

**Fresh-image verification pending:** inspect the rendered file, then verify
the graphical login path in QEMU.

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

**Fresh-image verification pending:** inspect dconf and package manifests,
then verify the first GNOME session.

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

**Fresh-image verification pending:** run `dnf5 check-upgrade` or an
equivalent solver query in the new qcow2 root and confirm no Azure-owned
package has a Fedora replacement candidate.

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

## Validation still required

1. Finish the fresh local Podman qcow2 build.
2. Mount the qcow2 read-only and compare its root and initramfs with the
   live ISO.
3. Verify GDM, dconf, initial-setup, GNOME Software, polkit, persistent
   Fedora exclusions, GRUB, and Plymouth from the mounted image.
4. Run the existing UEFI qcow2 QEMU smoke test.
5. Render both installer kickstarts and compare all non-storage content.
6. Verify the qcow2-only GitHub Actions release artifact independently
   after it finishes.

This audit is deliberately explicit about what has been observed and what
is still pending. The previous qcow2 showed the defects. The code now
contains targeted fixes for each one. A fresh artifact still has to prove
them.
