# Rebuilding the Fedora desktop layer for Azure Linux in COPR

## Short version

This is technically possible, but it is not a small packaging project.
Rebuilding the Fedora packages used by Azure Linux Desktop would create a
downstream desktop distribution with its own ABI, security, and update
obligations. The right first step is a narrow COPR pilot, not a blanket
rebuild.

The important constraint is glibc. Azure Linux 4 ships glibc 2.42, while
the current GTK4 stack requires `GLIBC_2.43`. That is why the current image
intentionally takes the complete glibc family from Fedora. Rebuilding
GTK/GNOME "natively" means first owning and maintaining a newer glibc,
which is core operating-system work rather than ordinary desktop packaging.

No COPR project, package rebuild, or repository configuration was created
as part of this investigation.

## What we know

Azure Linux 4 is currently [preview-only and intended for evaluation and
testing](https://learn.microsoft.com/en-us/azure/azure-linux/whats-new-azure-linux-4).
It uses dnf5, rpm 6.0.1, systemd 258.4, and glibc 2.42.

The current image policy deliberately keeps Azure Linux's kernel, systemd,
NetworkManager, SELinux, boot chain, firmware, and core userspace where
those packages can coexist with the Fedora desktop stack. The
[package-sourcing work](package-sourcing-clawback.md) documents the
exceptions that could not safely move back:

- GTK4 requires the newer Fedora glibc ABI.
- `wpa_supplicant` has no Azure Linux provider.
- Fedora `fwupd` is required alongside Fedora `freerdp-libs` because of the
  incompatible `libcbor` sonames.
- Fedora and Azure Linux fuse3 libraries coexist because they provide
  different sonames.

This is already a mixed ABI environment. COPR could make the Fedora portion
source-built against Azure Linux, but it cannot make the ABI question go
away. It moves responsibility for that question here.

The current image is also much larger than a few GNOME packages. The tested
live closure contains roughly 1,173 binary RPMs, including the GNOME/GTK
stack, portals, PipeWire, Flatpak, media support, hardware support,
installer dependencies, Microsoft and GitHub applications, RPM Fusion
codecs, and side-loaded tools. Binary RPM count is not source RPM count.
The actual rebuild scope needs a binary-to-SRPM lockfile and a separate
`BuildRequires` closure before it can be estimated honestly.

## COPR is plausible, not yet proven

[COPR](https://docs.pagure.org/copr.copr/user_documentation.html) supports
uploaded SRPMs, SCM builds, Fedora DistGit builds pinned to a branch or
commit, dependency-ordered build batches, and large mass rebuilds. Its
[API v3](https://copr.fedorainfracloud.org/api_3/docs/) can drive that from
CI.

Upstream Mock has an
[Azure Linux 4 template](https://github.com/rpm-software-management/mock/blob/main/mock-core-configs/etc/mock/templates/azure-linux-4.tpl).
That establishes that the buildroot mechanics exist upstream. It does not
establish that Fedora's public COPR service exposes an official Azure Linux
4 chroot today. If it does not, COPR's custom chroot support is the likely
path, using Azure Linux 4 base and SDK repositories plus an explicit
bootstrap package set.

That distinction matters. A custom chroot will not automatically inherit
Mock's Azure Linux template, macros, bootstrap container, or setup package
choices. We need to prove a small buildroot works before designing a
production repository around it.

## The repository model

Three logical sources are reasonable:

1. Azure Linux 4 owns the retained base and platform packages.
2. A COPR desktop repository owns the rebuilt glibc, GTK/GNOME stack, and
   other specifically approved Fedora-derived packages.
3. Fedora remains a low-priority source for approved extra GUI
   applications only.

In practice the installed system would still have Microsoft, GitHub, RPM
Fusion, and Flathub sources too. That is not automatically a problem, but
it means package ownership must be explicit. Repository cost is not enough.
The current project already found that a newer Fedora NEVRA can replace an
Azure package unless Fedora is explicitly excluded.

The project would need a tracked ownership manifest for every shared package
name: source package, owning repository, allowed fallback, and reason.
Release CI should fail if the installed closure contains an unapproved
Fedora provider for a package the COPR desktop repository owns.

## What a real rebuild requires

1. Lock every Fedora RPM to its source RPM, Fedora DistGit commit, source
   checksum, and repository.
2. Resolve the build dependency graph, not just the runtime image closure.
   Build dependencies will include packages absent from the current image.
3. Bootstrap cycles in order, beginning with the newer userspace floor and
   tooling needed to build it.
4. Build in COPR batches against a development repository, then publish
   only complete, tested sets.
5. Give rebuilt RPMs Azure Linux-specific release identity, rather than
   presenting unchanged Fedora packages as native builds.
6. Treat glibc as a first-class maintained fork with CVE, ABI, regression,
   and upgrade policy.

COPR should build and publish RPMs. GitHub Actions should generate the
source lock, submit and monitor batches, build the live and installer
images, and run installroot, origin-policy, upgrade, boot, and QEMU tests.
Moving image construction into COPR would not simplify the existing Lorax,
Anaconda, and KIWI work.

## Recommended pilot

Start with a custom Azure Linux 4 COPR chroot only if the public service
does not offer one.

1. Build a trivial Azure Linux RPM, then one Fedora desktop leaf package.
2. Verify `%dist`, vendor, GPG handling, source retrieval, and repository
   consumption from an Azure Linux 4 installroot.
3. Lock and build a narrow ABI pilot: glibc, GTK4, mutter, gnome-shell,
   GDM, portals, and their source/build dependency closure.
4. Build an image with Fedora disabled for packages owned by the pilot.
5. Test GNOME login, Flatpak, networking, firmware, updates, and upgrade
   behavior before expanding the source graph.

If that pilot cannot be rebuilt and updated reproducibly, a full desktop
rebuild would be a maintenance trap. If it works, the resulting source lock,
ownership manifest, and COPR batches provide a path to expand without
guessing at the scope.

## Risks that remain even if the pilot works

- A rebuilt glibc creates a permanent core-platform support obligation.
- Fedora specs may assume Fedora macros, compilers, Rust crates, and build
  dependencies that Azure Linux does not provide.
- Keeping Fedora enabled for extra applications can reintroduce library and
  ownership conflicts unless it is tightly constrained.
- Microsoft, GitHub, RPM Fusion, and Flathub content are separate sourcing
  and licensing questions. Rebuilding Fedora SRPMs does not absorb them
  into COPR.
- Public COPR hosting has its own source and license requirements. Each
  package must be suitable for public hosting.

This could give Azure Linux Desktop a reproducible, source-built desktop
layer and a clearer base-versus-desktop boundary. It is worthwhile to
investigate. It should be approached as creating and maintaining a
distribution layer, because that is what it is.
