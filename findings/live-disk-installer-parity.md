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

The live ISO, disk image, and installer all request `grub2-tools-extra` and
select its complete Fedora GRUB family. The Fedora update repository remains
enabled for security fixes to that family; only the Azure copy is excluded to
prevent a version-locked mix of GRUB siblings.

Before publishing this policy, the project package canary installed the live
kickstart's complete package set into a disposable Podman installroot. The
transaction completed with 1,169 packages and selected the Fedora
`grub2-tools-extra`, `grub2-common`, and `grub2-tools-minimal` family. The
container reported non-fatal dracut xattr-copy warnings, a local filesystem
limitation already covered in
[local-build-environment-boundaries.md](local-build-environment-boundaries.md);
the resulting package transaction and RPM inventory completed normally.

The live ISO is not the same kind of system as the qcow2 or an installed
system. It boots with `rd.live.image` and runs `livesys` setup services.
The qcow2 and installer target are ordinary installed systems, so anything
that `livesys-gnome` does at boot must instead be persisted during image
construction.

## First installer-created qcow2 smoke test

The first complete standard installation was run in QEMU from the successful
installer workflow artifact built from `723e956`. This is important evidence,
but it is not a test of every current source change: the artifact predates the
working-tree installer-runtime Plymouth and GNOME background-default changes.

Anaconda completed storage setup, copied the offline package transaction, ran
its target configuration, created the bootloader and user, generated the
target initramfs, and rebooted. Its progress display described the local
transfer as "Downloading 1024 RPMs, 1.93 GiB"; the installer kickstart points
DNF at `file:///opt/azl-offline-repo/`, so that wording means copying the
embedded ISO payload into DNF's transaction cache, not a network download.

The Flatpak SELinux step emitted brief installation output but did not stop
the transaction. After restarting QEMU without the installer ISO attached,
the installed qcow2 mounted its target filesystems, completed the expected
first-boot SELinux relabel, and reached GDM. This is the first runtime proof
that the artifact's embedded `flatpak-selinux-1.16.6-1.fc43.noarch.rpm`
allows the standard offline installation path to continue past software
selection.

Read-only inspection after shutdown completed that verification. The target
contains `flatpak-selinux-1.16.6-1.fc43`, and `semodule` reports its `flatpak`
policy module active at priority 200. Its module header is version 23, which
is within the Azure policy tooling's accepted range. The fast Flatpak output
seen during installation was not a failed policy-module load.

The installed target has 1,025 RPMs, compared with 1,173 in the published
live qcow2. The 148-name gap is mostly deliberate live-media and installer
tooling: Anaconda, `livesys`, live-dracut, block-device provisioning,
Cockpit, and their dependencies. The installed target instead has its
persistent LVM/EFI layout and a minimal language-pack baseline. It also
uses a different autologin account by design. This is lifecycle separation,
not a broad desktop package loss.

Two real target-side side-load defects were found:

- The staged `microsoft/edit` archive could not be extracted because the
  target package set omitted `tar`, but the post-install script still set
  `EDITOR` and `VISUAL` to the missing `/usr/local/bin/edit`.
- The staged Copilot file was only an installer script. It attempted a second
  network download while configuring the target, rejected that result as an
  invalid archive, and the script discarded the failure.

The current installer source adds `tar`, stages and checksums the actual
Copilot archive during the build's networked phase, installs both executables
locally, and fails the installation if either required artifact is missing or
cannot be installed. The installed target's initramfs already contains the
Azure Plymouth script renderer and theme assets, and its BLS entry includes
`rhgb quiet`; the older artifact's text-heavy first boot was therefore not
evidence that target Plymouth content was absent.

The sanitized evidence retained for this checkpoint is in
[`logs/installer-first-installed-target-2026-07-21.log`](logs/installer-first-installed-target-2026-07-21.log).

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

The published installer ISO omitted Flatpak's matching SELinux module even
though its Fedora Flatpak package requires it when `selinux-policy-targeted`
is installed. The later installer artifact includes
`flatpak-selinux-1.16.6-1.fc43`, and the first completed installation proves
the dependency and policy configuration work with the selected Azure Linux
policy base: its policy payload is module format 23 and the target's active
module store contains `flatpak` at priority 200.

That runtime result supersedes the earlier format-24 incompatibility theory.
Do not describe the current Fedora 43 Flatpak policy package as incompatible
with this Azure Linux target. Azure-native Flatpak packaging is still absent
from the public repositories, but it is not required for the verified
Fedora Flatpak path used here.

Azure Linux is also removing Anaconda's Flatpak source integration upstream:
[PR 16957](https://github.com/microsoft/azurelinux/pull/16957) drops its
Flatpak package requirements and [PR 17060](https://github.com/microsoft/azurelinux/pull/17060)
makes the module inert when its typelib is absent. The result is the same:
there is no Azure-native Flatpak path to switch to today. Keep the Fedora
Flatpak boundary called out as unresolved. Do not substitute a locally built
policy package or call the compatibility problem fixed.

## Fedora logo dependency and installer parity

The released live root contains `fedora-logos`. That is expected. Fedora's
live-media Anaconda package brings in its Web UI, and the current supported
package baseline still gives that Web UI a literal `fedora-logos`
requirement. The published installer ISO still renders `generic-logos`
instead. It also predates the current source's explicit `flatpak-selinux`
entry. Those are release-to-source differences, not evidence that the
published installer target already has the current policy fixes.

The next-build installer definition leaves the logo dependency to the same
Fedora live-media chain the live ISO already uses and includes
`flatpak-selinux` in its offline package input. This removes an
installer-only package difference without pretending a post-install overwrite
of RPM-owned logo files would survive an update. An upstream
[Anaconda change](https://github.com/rhinstaller/anaconda-webui/commit/fe65289689fd49f1a73c4b06e1b8dff8998ed6eb)
uses the `system-logos` virtual dependency for remixes, but that change is
not in the Fedora package this build currently consumes. Azure Linux's
source tree has the matching overlay, but its public package repository does
not publish an `anaconda-webui` package. The current practical policy is to
keep the next live and installer paths aligned on `fedora-logos`.

The failed pre-fix full package resolve is retained in
[`logs/release-canary-fedora-logos-2026-07-21.log`](logs/release-canary-fedora-logos-2026-07-21.log).

## Desktop session follow-up

The released live ISO was booted through the graphical QEMU path. Autologin,
the expected default applications, and the tray all worked. The desktop had
no wallpaper because the project set the dark-mode preference but never set
GNOME's background URI. The live kickstart, disk-image workflow, and both
installer templates now set light and dark background URIs to images shipped
by `gnome-backgrounds`.

The QEMU mouse problem is not a guest-agent problem. `qemu-guest-agent` is
for host-to-guest control and status, not graphical pointer integration. No
QEMU or SPICE guest package belongs in the image for this test-harness fix.

The behavior predates the Fedora-base reversion. That rules out the current
desktop package baseline as the cause and keeps the focus on the local host
input path.

## Direct live and VM boot

The installer keeps its menu because it must offer install and live modes.
The live ISO and prebuilt disk images do not need a normal visible GRUB menu.
Their normal path now uses GRUB's hidden timeout mode with a one-second
interrupt window. They boot directly into the kernel and Plymouth; pressing
Escape during that short window still exposes GRUB recovery entries.

### GTK cursor regression

The released live ISO was tested through the GTK helper with QEMU's xHCI USB
tablet attached. Pointer input works. The two graphical helpers now make that
input path their default, matching the existing VNC helpers. Set
`AZL_QEMU_INPUT_DEVICE` to select another supported USB or virtio input device
for a focused comparison.

The earlier GTK and SDL experiments established only that Wayland frontend
pointer grabbing is not a useful guest-input control. Cursor visibility and
keyboard-grab options do not repair a missing guest driver.

The VNC control and direct kernel comparison below settled the project issue:
the host can deliver QEMU pointer input, while the Azure guest lacks the USB
HID driver needed to consume the tablet device. The project-owned exact-kernel
module path is documented in [`azure-kernel-usbhid.md`](azure-kernel-usbhid.md).

### Fedora VNC control: host input path works

An unmodified Fedora workstation live image was downloaded from the official
release, checksum-verified, and booted with the same UEFI, KVM, q35, xHCI USB
tablet, localhost VNC, and GNOME Connections client path used for the Azure
live qcow2. Fedora accepted normal guest mouse input. The Azure guest on the
same VNC path accepted keyboard input but not mouse input.

This rules out the host's QEMU GTK/SDL frontend and its VNC server as
sufficient explanations. The remaining failure is in the Azure guest. The
reusable `scripts/qemu-vnc-disk-image.sh` and
`scripts/qemu-vnc-live-iso.sh` launchers preserve this comparison without
altering either test disk.

### Commit-history audit: no pointer-stack regression in source

A focused audit compared the known-working early proof-of-concept baseline
with every later source change through the first documented mouse report.
There is no commit that changed `libinput`, a pointer device, the kernel input
configuration, Mutter, GNOME Shell, or an input-related service after that
baseline.

The broadest package change was the desktop layer's move from a newer Fedora
baseline back to the supported Fedora package boundary. It is an imperfect
control, but the mouse report predates that move, so it cannot be the original
regression. The later GDM, dconf, Plymouth, GRUB, Flatpak, EFI, and QEMU
monitor changes either affect boot/session presentation or were added after
the report. They have no pointer-specific evidence.

The source policy has excluded the Fedora kernel family since the first
tracked proof-of-concept baseline. There is no source commit that introduced
the exclusion during this history window. The actual Azure kernel package
changed underneath that stable policy, so source history alone could not
identify its missing desktop input drivers. The next useful control was a
current Fedora Rawhide live image through the same UEFI/QEMU/VNC/USB-tablet
path.

### Rawhide VNC control: current graphics stack also works

The official current Fedora Rawhide Workstation live image was downloaded,
checksum-verified, and booted through the same UEFI, q35, KVM, xHCI USB
tablet, localhost VNC, and GNOME Connections path. Its guest mouse worked
normally, just as the Fedora 43 control did.

Current Fedora graphics and input packages are therefore not sufficient to
explain the Azure failure. Rawhide did not autologin and showed an
authentication prompt similar to the one previously handled in Azure Desktop.
That is a useful session-auth clue, but there is no evidence that it controls
mouse delivery.

A second independent review found QEMU's internal relative-pointer ownership
and GTK seat-grab handling consistent with this result. It is a known class
of Wayland/X11 grab failure, not a verified QEMU 11-only regression; the
closest open upstream report is
[QEMU issue #3192](https://gitlab.com/qemu-project/qemu/-/issues/3192).
The most useful next comparison is the unchanged command from a real GNOME
Xorg session. The full assessment and QEMU tracepoint names for an upstream
report are retained in
[`logs/qemu-pointer-wayland-research-2026-07-21.log`](logs/qemu-pointer-wayland-research-2026-07-21.log).
Relevant upstream sources are QEMU's
[GTK frontend](https://github.com/qemu/qemu/blob/master/ui/gtk.c),
[SDL frontend](https://github.com/qemu/qemu/blob/master/ui/sdl2.c), GTK's
[Wayland device implementation](https://gitlab.gnome.org/GNOME/gtk/-/blob/3.24.52/gdk/wayland/gdkdevice-wayland.c),
and SDL's [Wayland notes](https://wiki.libsdl.org/SDL3/README-wayland).
The focused research record is retained in
[`logs/qemu-pointer-wayland-research-2026-07-21.log`](logs/qemu-pointer-wayland-research-2026-07-21.log).

### Direct kernel comparison: missing desktop input drivers

The released Azure live root and current Rawhide live root were extracted and
compared directly. The Azure image contains 1,173 RPMs and uses
`kernel-6.18.31-1.6.azl4`, while Rawhide contains 1,967 RPMs and uses its
Fedora kernel. Both have the expected Fedora libinput desktop boundary, but
Azure supplies the kernel, systemd-udev, libevdev, and libwacom.

This is the relevant kernel difference:

```
Azure:   CONFIG_HID=m
Azure:   CONFIG_HID_GENERIC=m
Azure:   # CONFIG_USB_HID is not set
Azure:   # CONFIG_MOUSE_PS2 is not set
Azure:   CONFIG_VIRTIO_INPUT=m

Rawhide: CONFIG_HID=y
Rawhide: CONFIG_HID_GENERIC=y
Rawhide: CONFIG_USB_HID=y
Rawhide: CONFIG_MOUSE_PS2=y
Rawhide: CONFIG_VIRTIO_INPUT=m
```

Azure's module inventory has `virtio_input.ko`, `hid.ko`, and
`hid-generic.ko`, but no `usbhid.ko` or `psmouse.ko`. Rawhide includes both
USB HID and PS/2 mouse support. The QEMU VNC control used an xHCI USB tablet,
which requires the missing USB-HID driver. The GTK and SDL relative-mouse
tests depend on the likewise absent PS/2 mouse driver.

This was tested against the published Azure qcow2, not inferred from the
configuration file alone. The existing USB-tablet instance on VNC port 5901
still had no mouse. A second snapshot-backed instance was launched with
`virtio-tablet-pci` on VNC port 5904, and its pointer worked immediately.
The Azure `virtio_input` path is therefore intact. The failure is the Azure
kernel's missing USB HID and PS/2 mouse support.

This is more than a QEMU test-harness issue. A normal USB mouse uses the same
USB-HID path, so the current Azure kernel is not an appropriate desktop
kernel for physical input either. Using virtio input is a useful VM test
workaround, but it is not a product fix.

The Fedora kernel is now a disposable diagnostic control only. It will test
whether the existing Azure base and Fedora GUI boundary works when the missing
drivers are present, but it must not become an image dependency. Its complete
local installroot transaction passed with 1,169 packages: the Fedora kernel
family resolved to `6.17.1-300.fc43`, while `systemd` remained the Azure
build. The first disposable control run then resolved and downloaded almost
the entire image transaction in both ISO and disk paths, but Azure package
transport failed on the final `clevis-luks-21-13.azl4` RPM. Directly checking
that exact published RPM afterward returned the expected 35,146-byte object,
so this is a transient repository-download failure, not a kernel-policy or
dependency failure. The retained excerpt is in
[`logs/fedora-kernel-control-download-29893981896.log`](logs/fedora-kernel-control-download-29893981896.log).

The next evidence needed is the unchanged control build followed by its
USB-tablet and PS/2-mouse boot test, not another dependency experiment. The
product fix belongs upstream in Azure Linux's x86_64 kernel configuration:
[`base/comps/kernel/6.18-x86_64-azl.config`](https://github.com/microsoft/azurelinux/blob/4.0/base/comps/kernel/6.18-x86_64-azl.config).
That source explicitly disables `CONFIG_INPUT_MOUSE` and `CONFIG_USB_HID`.
The minimal Azure Linux change is `CONFIG_INPUT_MOUSE=y`,
`CONFIG_MOUSE_PS2=m`, and `CONFIG_USB_HID=m`, using Azure's existing kernel
and module packaging.

There is no kernel command-line setting that can enable this in the current
release. Kernel command-line options configure code that was compiled in or
built as a module; they cannot create `psmouse.ko` or `usbhid.ko` when the
Azure build omitted both. Do not describe the cursor problem as a GNOME,
libinput, VNC, or host Wayland failure going forward.

### Live-media livenet console noise

The released live ISO's boot initramfs includes both `livenet` and
`/lib/url-lib.sh`. The visible `get_url_handler: command not found` line is
therefore not a missing file or the reason the session has no mouse. Its
`parse-livenet.sh` calls `get_url_handler` once before it sources the file
that defines that function, then correctly sources it and continues.

This is a known dracut ordering bug, reported upstream in
[dracut-ng issue 1240](https://github.com/dracut-ng/dracut/issues/1240).
Current upstream `parse-livenet.sh` sources the URL helper before using the
function. The live builder now applies that narrow upstream-equivalent fix
before Lorax creates the boot initramfs. It retains `livenet`: the normal ISO
path does not need it, but retaining it avoids silently dropping supported
network-backed live-root and live-update scenarios.

The reusable patch is
[`scripts/patch-dracut-livenet-hook.sh`](../scripts/patch-dracut-livenet-hook.sh).
It was run against the local dracut hook and leaves no bare pre-source
`get_url_handler` call. Inspect the next ISO's initramfs and boot it before
calling the visual presentation fixed; this change removes the misleading
console error but does not itself restyle Plymouth.

## Plymouth

**Observed problem:** the qcow2 showed the generic splash or text path even
though `/usr/share/plymouth/themes/azurelinux` existed in the installed root.

**Root cause:** the qcow2 initramfs contained Plymouth binaries but not the
Azure Linux theme assets or the Plymouth script renderer. The live ISO's
dedicated boot initrd contained the theme `.plymouth` and `.script` files,
logo, dots, and `script.so`.

The published live ISO's stored root initramfs and the published qcow2 boot
initramfs both lack those files. The difference is that the ISO boots
`images/pxeboot/initrd.img`, which Lorax generates after the live root; the
qcow2 boots its root `/boot/initramfs-*`.

The initial disk workflow fix used
`plymouth-set-default-theme azurelinux --rebuild-initrd`. It was insufficient:
the helper runs bare `dracut -f`, which selects the build container's
`uname -r`, not the Azure kernel under `/usr/lib/modules` in the target
image. The release workflow logged that command, but the released qcow2
still lacked `script.so` and the Azure theme assets.

**Next-build fix:** select the Azure theme, then explicitly run
`dracut --force --kver` for every target kernel directory. This rebuilds the
initramfs that the qcow2 actually boots. This is a disk-image build-path
defect, not a qcow2 limitation. The concise release-artifact inventory and
logged failed rebuild approach are retained in
[`logs/plymouth-initramfs-release-2026-07-21.log`](logs/plymouth-initramfs-release-2026-07-21.log).

The published disk BLS entry also had only `console=ttyS0`, with no `rhgb`
or `quiet`. The disk workflow now writes those arguments into the existing
BLS entries and its kernel-install hook. Plymouth therefore has both a
complete target initramfs and the normal kernel request to start it.

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

Both also use the host-matched Adwaita light/dark background defaults and
the project PowerShell launcher. The launcher starts a GNOME Terminal server
with the `org.azurelinux.PowerShell` application ID before opening `pwsh`, so
the Wayland dock can distinguish it from ordinary Terminal windows.

Azure Linux does not bake an account into its installer templates. The
desktop renderer retains that behavior: both rendered kickstarts have no
`rootpw` or `user --name` directive, leaving account creation to Anaconda.
The source templates retain one masked legacy user line only because the
masked value cannot be safely changed through the project patch path; the
renderer strips it. That source-only cleanup does not affect generated ISO
behavior.

The templates were compared outside their storage stanza and found to have
no other functional drift. The remaining runtime validation is a graphical
first login after installation, including the PowerShell dock identity.

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

## Release 2026.07.22 static verification

The published installer ISO and live qcow2 were downloaded with
`scripts/Get-AzureLinuxDesktop.ps1`. The downloader reassembled both split
assets and verified their published SHA-256 manifests:

- `azurelinux-desktop-install.iso`:
  `e6609c5a08006bc878bdd4189fc92d5f415016d55e2a79104b30dbcc251b94f0`
- `azurelinux-desktop-live.qcow2`:
  `1a5caa170df853dae330a1f6f11e1ac3a2d829a4f72efae2a5ce28fdf5814545`

Read-only QCOW inspection confirmed the persistent live image includes the
PowerShell desktop entry and launcher helper. The helper starts
`/usr/libexec/gnome-terminal-server` with
`org.azurelinux.PowerShell`, then opens `pwsh` through the same application
ID. The shipped GNOME Terminal accepts that hidden `--app-id` option.

The live disk's compiled dconf database contains the host-matched Adwaita
light and dark backgrounds and the PowerShell desktop ID in GNOME favorites.
Both Adwaita files and the GNOME Terminal server are present. The disk still
uses the intended Fedora-style `liveuser` autologin and `pwsh` login shell.
Its Azure kernel, desktop policy RPM, and `usbhid` module all have matching
`6.18.31-1.6.azl4` identities.

The installer runtime carries the standard and encrypted rendered
kickstarts, plus the staged PowerShell helper and desktop entry. Neither
rendered kickstart has a `rootpw` or `user --name` directive. Both request
GNOME Terminal, GNOME backgrounds, PowerShell, and the desktop policy. The
embedded offline repository includes those RPMs and the matching `usbhid`
RPM. Their target post-install sections copy the helper and desktop file,
write the same Adwaita URIs and PowerShell favorite, and run `dconf update`.

This establishes published-artifact parity for the new files and rendered
configuration. It does not replace graphical validation: boot the qcow2 to
confirm dock grouping, and install each installer path to confirm first-login
behavior.

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

## Installer interaction correction

The first `2026.07.22` installer QA run exposed two separate problems before
an installation began:

- `scripts/qemu-test-install-iso.sh` sourced its OVMF helper but never
  attached the firmware. It therefore booted QEMU as BIOS while the standard
  kickstart requested an EFI partition. Anaconda correctly rejected that
  contradiction and asked for a BIOS boot partition.
- The upstream-derived launcher always runs Anaconda in text mode. With no
  account directive in the generated kickstart, that UI exposes separate
  storage, root-password, and user-creation spokes. That is not the intended
  desktop installer flow.

The standard template now uses `clearpart --all --initlabel` with
`autopart --type=lvm`, so the selected disk is cleared and partitioned
automatically. The encrypted option retains automatic LUKS/LVM provisioning.
The QEMU helpers now attach OVMF code and a per-test writable variable store,
matching the UEFI layout the ISO actually targets.

Before launching Anaconda, the installer asks for one administrator username
and a confirmed password. The launcher hashes that password in the installer
runtime, injects a temporary wheel-user directive into its generated
kickstart, and locks root. Anaconda therefore receives a complete account
configuration and does not require separate root or user spokes. OpenSSL is
included in both the installer runtime and offline target package set for
this hash step.

The template rendering test confirms each mode has exactly a locked root and
one generated administrator directive. A new installer ISO must still prove
the graphical interaction end to end.

## Build-container cleanup error

The new live ISO build completed Anaconda installation successfully but
logged a nonfatal exit-handler exception for missing `/usr/sbin/load_policy`.
That binary belongs to `policycoreutils`, which was absent from the minimal
Fedora build containers.

`policycoreutils` is now installed in the live ISO, disk-image, local qcow2,
and test qcow2 build environments. This removes the error at its source
without changing the image payload.

## Released artifact static parity

The current release ISO and QCOW2 were downloaded with the project downloader
and verified against their published checksums. Their resolved package
inventories contain the same 1,175 packages after normalized sorting.

Both roots contain the same exact kernel policy and USB HID module, the
persistent Pages repository, `/usr/local/bin/copilot`, `/usr/local/bin/edit`,
and the configured light and dark backgrounds. The QCOW2 module vermagic
matches its installed kernel.

The installer runtime is intentionally smaller. Its package inventory contains
426 packages. It carries 1,050 unique RPMs in its offline repository, with
121 direct package requests in the rendered kickstart. Anaconda resolves the
target system from that offline closure. The exact installed-target rpmdb is
therefore a runtime check after a real installation, not a property of the
installer squashfs.

The offline closure includes the policy and module RPMs, Edge Canary,
PowerShell, GitHub CLI and Desktop, the .NET preview runtime and SDK, and
GNOME backgrounds. Both installer choices request the policy package. The
target post-install script writes the Pages repository and the rendered
kickstart installs the GitHub Copilot application, Copilot CLI, edit, the
PowerShell dock launcher, and the background configuration on the target
disk.

The live ISO, QCOW2, and canary already contain the expected application
surface for their roles. The live and QCOW2 carry the exact policy/module
pair. The canary carries the same repository configuration and proves a fresh
policy/module transaction, but does not retain a kernel package because it is
not a bootable image.

## Remaining runtime checks

1. Boot the released live ISO and qcow2 through the normal USB-tablet path.
   The released ISO now has confirmed GTK pointer input. Confirm the same
   path in the QCOW2 after its next rebuild.
2. Provide a documented persistent live-storage path before treating large
   Flatpak installation as supported on an 8 GiB live session. Fedora's
   supported USB path is `livecd-iso-to-disk --overlay-size-mb` plus an
   optional `--home-size-mb`, which creates the named overlay file and
   `home.img` layout dracut expects. Azure's own LiveOS tooling is
   intentionally stateless. The live builder now also requests a 4 GiB
   live root: Flatpak checks the root filesystem's reported free space before
   consuming the separate RAM overlay, so the earlier smaller root rejected
   a runtime transaction despite the available overlay capacity. Verify this
   against the next ISO before calling live Flatpak installation fixed.
3. Run both installer selections to a target disk. Confirm each installed
   target retains the Pages repository and has the same paired kernel/module
   policy and relevant desktop package boundary as the qcow2.

## Installer interactive testing batch (2026-07-23) — fixes applied

### Asset permissions parity issue (installer only) — fixed

**Root cause:** `assets.tar.gz` is extracted in a Fedora 43 build container
with default umask 077. `cp -v` preserves source permissions verbatim, so
all asset files landed at mode 600 in the installed target. GNOME Shell
(running as the user, not root) silently drops any `.desktop` file it
cannot read, so PowerShell was absent from the dash despite dconf having
the correct `favorite-apps` value.

**Fix:** All `cp -v` replaced with `install -m 0644` (data files) and
`install -m 0755` (executables) in all three kickstarts. The live ISO was
unaffected (direct workspace checkout preserves 644), but the fix is applied
there too as belt-and-suspenders.

**Confirmed:** `dconf read /org/gnome/shell/favorite-apps` and `gsettings get
org.gnome.shell favorite-apps` from an SSH session inside the running installed
GNOME session both returned all 5 entries correctly.

### Plymouth serial console — fixed (installer)

Azure Linux inherits `console=ttyS0,115200 console=tty0` in its cloud/datacenter
origin kernel cmdline. `kiwi/post-bootloader.sh` was propagating this into the
installed system's BLS entry. Plymouth detects a serial console via
`/sys/class/tty/console/active` and switches to text/details mode regardless of
other configuration. Removed the serial console params from the normal boot BLS
entry. Azure Linux Plymouth boot splash (penguin + animated dots) confirmed at
~6s in QEMU test.

### EFI boot path mismatch — fixed

Our kickstart excludes AZL's `shim-x64` and `grub2-efi-x64`; Fedora's RPMs
install their EFI binaries to `EFI/fedora/`, but Anaconda creates the NVRAM entry
pointing to `EFI/azurelinux/shimx64.efi`. `post-bootloader.sh` now copies the
Fedora EFI binaries to `EFI/azurelinux/` when absent.

### Disk partitioning delegated to Anaconda TUI

Removed `clearpart --all --initlabel` and `autopart --type=lvm` from the installer
kickstart. Anaconda TUI handles storage; enforces minimum layout requirements.
Encryption is now a TUI choice.

### early-kms parity fix (live-disk)

`kickstart/azurelinux-desktop-live-disk.ks` `early-kms.conf` now loads
`virtio_gpu hyperv_drm bochs_drm` (matching live ISO and installer).

### Build status (2026-07-23)

Fresh builds triggered from `deliverable-polish-batch` HEAD `8b02468`:
- Live ISO + qcow2: run 29984033898 — qcow2 ✅ completed, live ISO ⏳ in progress
- Installer ISO: run 29984008922 — ⏳ in progress

Verification pending these builds completing.

### Build status update (2026-07-24)

Run 29984033898 (live ISO + qcow2) and run 29984008922 (installer ISO) both
completed successfully.

Static filesystem verification performed on installer ISO from run 29984008922:
all 2026-07-23 fixes confirmed present in the rootfs (permissions, Plymouth
theme, no clearpart/autopart, no ttyS0, no cinnamon).

Additional parity gap identified: `post-bootloader.sh` was writing
`terminal_output console serial` (Azure upstream text-mode GRUB) for the
installed system's `grub.cfg`. The installer ISO's own GRUB already used
`gfxterm`. Fixed in commit `b49ee12` — installed system now gets graphical
GRUB + `gfxpayload=keep`, matching the installer ISO's own menu. New installer
build: run `29987725267`.

### Final parity status (2026-07-24, nightly release 29993641061)

**Squash commit `b085d15` landed on `main`.** Nightly release completed:
- Installer ISO: published ✅ (2.9 GB, built from `b085d15`)
- Live ISO: published ✅ (2.75 GB, built from `b085d15`)
- Live QCOW2: published ✅ (3.1 GB, built from `b085d15`)

**Static parity checks passed on new live ISO (run 29990996437):**
- Wallpaper assets staged: `/usr/share/backgrounds/azurelinux/adwaita-{d,l}.jpg` ✅
- dconf picture-uri/dark pointing to staged JPEGs ✅
- early-kms: `virtio_gpu hyperv_drm bochs_drm` ✅
- All desktop files mode 644 ✅
- Plymouth azurelinux theme with ScaleLogoToFit ✅

**Installer gfxterm parity (commit b49ee12):**
- Installer ISO boot menu: `gfxterm` ✅
- Installed system's grub.cfg via post-bootloader.sh: `gfxterm + gfxpayload=keep` ✅

**Known parity items requiring GUI/interactive verification:**
- Plymouth graphical animation during installer boot (static: azurelinux theme present)
- Plymouth on first installed-target boot (static: gfxterm + no ttyS0 confirmed)
- Dock PowerShell icon in installed target (static: mode 644 confirmed)
- .NET launcher drop-to-shell behavior (static: azl-dotnet-terminal script correct)

These items require a real display. Static verification provides high confidence
all fixes are in place.
