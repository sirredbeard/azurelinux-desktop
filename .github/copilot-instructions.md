# Instructions for AI agents working on this repo

Read this before doing anything else. It exists so project goals,
conventions, and hard-won technical context survive across sessions and
context resets, not just in one person's head or one chat window.

## What this project is

A GNOME desktop on top of Microsoft's [Azure Linux](https://github.com/microsoft/azurelinux)
4.0, built as a live ISO, an installer ISO, and (in progress) qcow2/VHDX/VDI/VMDK
disk images. Personal side project, explored for fun, not affiliated with or
endorsed by Microsoft, the Fedora Project, Red Hat, the GNOME Foundation, or
GitHub. Bare-metal follow-up to an earlier wslc/.NET-based version - see the
README for the full backstory.

## Guiding principles

1. **Prefer Azure Linux tooling and packages first.** Where Azure Linux's own
   ecosystem doesn't cover something (desktop environment, GUI apps), fall
   back to the Fedora/RHEL ecosystem next. Only reach for a package or a
   system-level change outside Azure Linux/Fedora when it's genuinely
   necessary. This applies to build tooling too, not just runtime packages -
   see "Build tooling" below for why that's more constrained than it sounds.
2. **Don't maintain parallel, hand-synced environment definitions.** If the
   live ISO, the installer ISO, and the disk images each need their own
   from-scratch package list and post-install config, they will drift out of
   sync with each other over time, silently. One source of truth, or a
   generated/derived second one, beats three hand-maintained ones. This is
   an active, unresolved architecture question as of this writing - see
   "Current known issues" below.
3. **Keep the live and installer ISOs aligned with each other** in package
   set and configuration wherever the two can reasonably share anything.
4. **Findings survive.** Every real bug, dead end, or piece of research goes
   in `findings/*.md` - written for the next person (human or LLM) who hits
   the same wall, not just as a changelog. Findings get pruned for
   relevance over time, not left to grow forever, but the actual lessons
   learned are preserved even when a specific bug's blow-by-blow is cut.
5. **Logs earn their place.** `findings/logs/` holds only logs that are
   actually referenced by something in `findings/*.md`, trimmed to the
   relevant excerpt where the full log isn't needed. It is not a dumping
   ground for every CI run's raw output.
6. **Scripts are real, tested artifacts**, not one-off snippets. Anything
   written to help build, test, or download this project's images goes in
   `/scripts/`, gets documented, and gets actually run (not just written) as
   part of whatever task produced it.
7. **README.md documents the system, not superlatives.** Focus on what's
   actually included and what packages/components come from Azure Linux
   directly, not package counts or percentages, and not marketing language.

## Repository conventions

- **Commits**: squash aggressively, keep the commit count small and each
  commit meaningful. Never add a `Co-authored-by: Copilot` trailer to any
  commit in this repo - this is a hard rule for this user's personal repos.
- **Writing voice**: everything user-facing (README, findings, code
  comments, commit messages, PR text) is written in this repo owner's
  personal writing style. The style guide this is based on is private -
  don't publish it, quote from it, link to it, or describe its contents in
  any file in this repo or in any public-facing text. If you need the
  guide's content, it's supplied as private context per-session; treat it
  the same way you'd treat any other instruction that isn't meant to become
  part of the repo itself.
- **Model selection for agents/research**: match the model to the task.
  Use a lighter/faster model (e.g. Haiku-tier) for mechanical, well-defined
  work (log pruning, simple lookups, straightforward doc updates). Use a
  deeper-reasoning model (e.g. Opus-tier) for genuinely hard problems -
  tracing bugs through unfamiliar source trees, architecture decisions with
  real tradeoffs, anything where a shallow pass has already failed once.
  Dispatch research agents liberally for "has someone already solved this"
  questions before doing trial-and-error debugging.
- **CI hygiene**: only re-run the specific build (ISO vs disk images, and
  going forward the more granular qcow2/VHDX/VDI/VMDK split) that actually
  needs iterating on. Delete diagnosed/superseded CI runs once their logs
  are captured into `findings/logs/`, so the Actions run list stays useful.

## Build architecture (as of this writing)

- **Live ISO** (`build-live-iso.yml`, `build-iso` job) uses `lorax` +
  `livemedia-creator --make-iso` inside a `Fedora container` container, driven by
  `kickstart/azurelinux-desktop-live.ks`. **Installer ISO**
  (`build-installer-iso.yml`) uses KIWI-NG (`python3-kiwi`) instead - the
  same tool Microsoft's own real Azure Linux installer ISO is built with
  (see `kiwi/azl-desktop-installer.kiwi`, `kiwi/config.sh`, both direct
  adaptations of Microsoft's `base/images/vm-iso-installer` files). These
  are two different build tools for two different ISOs, on purpose, not
  an inconsistency to fix - each one is what its upstream reference build
  actually uses. Both work reliably. Don't change either path without a
  strong reason.
- **Disk images** (`build-live-iso.yml`) use the same kickstart run through
  `livemedia-creator --make-disk`, then `qemu-img convert` for the
  non-qcow2 formats. This used to be the unstable part of this project -
  an anaconda `verify_bootloader()` bug ("You have not created a bootable
  partition.") blocked every BIOS/MBR attempt. Root cause and fix (full
  trace in `findings/gh-actions-live-iso-build.md`, "BUG #5 - RESOLVED"):
  switch the disk image to **UEFI/GPT**, matching what the installed
  system should be using anyway - BIOS was never the right target here.
  Two more bugs surfaced only after the first real QEMU boot test of the
  resulting image (see the "Disk image confirmed to genuinely boot"
  section onward): the root partition didn't grow to fill the resized
  disk (fixed with `azl-growroot.service`, `cloud-utils-growpart` +
  `xfs_growfs`), and the VHDX conversion was sourced from the pre-resize
  raw image instead of the resized qcow2 (fixed by reordering the
  conversion). Both confirmed fixed against two consecutive real CI runs.
- **mkosi migration: abandoned.** A pivot to `mkosi` was explored and
  partially attempted earlier in this project's history, but per explicit
  user preference ("I really don't want a massive migration... make the
  current approach work ideally") it was dropped once the anaconda/UEFI
  fix above actually worked. Any leftover mkosi-related files/branches are
  historical, not the current build path - don't resurrect this without
  the user asking for it again.
- **Why not just use Azure Linux's own Image Customizer/KIWI-NG for disk
  images**, which is what Microsoft's own Azure Linux release process
  actually uses: its own CI needs `losetup -P` (partition-scanning loop
  devices), which is confirmed broken on GitHub-hosted runners (see
  `findings/live-iso-and-bare-metal.md`) - that's why Image Customizer's own
  upstream CI runs on self-hosted runners, which this project doesn't have.
- **Disk image formats**: qcow2 is what `livemedia-creator --make-disk`
  produces and `qemu-img resize`s to its final size; VHDX (Hyper-V), VDI
  (VirtualBox), and VMDK (VMware) are all converted from that already-
  resized qcow2 via `qemu-img convert` - never from the raw pre-resize
  image, since none of the three target formats support a post-conversion
  resize (confirmed empirically). `build-disk-image` (the slow anaconda
  step) produces only the qcow2; `build-vhdx`/`build-vdi`/`build-vmdk` are
  independent jobs, each `needs: build-disk-image` and downloading its
  qcow2 artifact, so iterating on one conversion format never re-runs the
  anaconda build or the other conversions. All four confirmed working via
  real CI builds - qcow2/VHDX with a genuine QEMU boot test, VDI/VMDK with
  `qemu-img info` size/format checks only (no VirtualBox/VMware installed
  in this dev environment on purpose, so those two haven't been boot-
  tested, only conversion-tested).
- **Hybrid container image** (`build-container.yml`,
  `scripts/build-hybrid-container.sh`): publishes a small OCI image to
  GHCR straight from the kickstart's own repo/priority setup, the same
  idea as Azure Linux's own upstream `container-base` (systemd=false,
  non-bootable, tiny package set - see `microsoft/azurelinux`'s
  `base/images/container-base/container-base.kiwi` and `images.toml`).
  Not a containerized desktop (GNOME needs systemd/D-Bus/a display, none
  of which belong in a plain OCI container) - it's a fast, always-fresh
  proof that the Azure-Linux-base + Fedora-GNOME-layer repo priority
  split still resolves packages from the intended repo, publishable so
  it can be pulled and inspected without a full ISO/disk-image build.
- **Download script**: `scripts/Get-AzureLinuxDesktop.ps1` mirrors
  whatever image formats the release actually publishes - keep its
  `-Kvm`/`-Hyperv`/`-VirtualBox`/`-VMWare`-style options and README's
  documentation of them in sync with whatever the release workflow
  actually produces at any given time.

## Where things live

- `.github/workflows/` - `build-live-iso.yml` (live ISO + all disk-image
  formats, split into independent jobs), `build-installer-iso.yml`
  (installer ISO), `release-live-iso.yml` (publishes a GitHub Release from
  the above), `build-container.yml` (publishes the hybrid proof-of-repo-
  priority container to GHCR).
- `kickstart/` - the kickstart(s) driving the ISO builds, the disk-image
  build, and (indirectly, via `scripts/build-hybrid-container.sh` parsing
  its repo/package setup) the hybrid container.
- `kiwi/` - the installer ISO's KIWI-NG description (see "Build
  architecture" above) - this IS the current installer-ISO path, unlike
  the abandoned mkosi disk-image exploration.
- `scripts/` - the PowerShell download script and QEMU/podman test/build
  scripts this project publishes and dogfoods. Anything written here
  should actually get run against a real build, not just committed
  unverified.
- `findings/` - the project's institutional memory. Read the relevant file
  before debugging something that feels like it's been hit before.
- `findings/logs/` - trimmed, relevant log excerpts referenced by
  `findings/*.md` - not a general log archive.

## A note on continuity

This file, `README.md`, and `findings/*.md` together are meant to carry
enough real technical detail that a fresh agent session (after a context
reset/compaction) can pick this project back up without re-discovering
things that have already been debugged once. When you learn something
substantial - a root cause, a dead end, an architecture decision and why -
write it down in one of these three places before moving on, not just in
chat.
