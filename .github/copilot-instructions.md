# Instructions for AI agents working on this repo

Read this before doing anything else. It exists so project goals,
conventions, and hard-won technical context survive across sessions and
context resets, not just in one person's head or one chat window.

## What this project is

A GNOME desktop on top of Microsoft's [Azure Linux](https://github.com/microsoft/azurelinux)
4.0, built as a live ISO, an installer ISO, qcow2/VHDX/VDI/VMDK disk images, and a
canary container. Personal side project, explored for fun, not affiliated with or
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
3. **Keep the release artifacts aligned on what matters.** The live ISO/VM,
   installer ISO, and installed target should stay aligned on package origin
   policy, custom tools, and user-facing behavior wherever their lifecycles
   can reasonably share it. The canary container is part of that parity check
   for repo/source priority and project-specific tools, but remains a canary:
   no full GNOME/GDM/Mutter desktop stack.
4. **Findings survive, and verification stays systematic.** Every real bug,
   dead end, or piece of research goes
   in `findings/*.md` - written for the next person (human or LLM) who hits
   the same wall, not just as a changelog. Findings get pruned for
   relevance over time, not left to grow forever, but the actual lessons
   learned are preserved even when a specific bug's blow-by-blow is cut.
   Work issue-by-issue: capture evidence, apply one scoped fix, verify on
   filesystem plus runtime behavior, record the result, then move to the next
   issue.
   Keep **one findings file per issue or durable topic** under `findings/`
   (search `findings/*.md` by symptom). Do not recreate `final_polish.md` /
   `final_polish_finished.md` megafiles. Do **not** create or restore a
   `findings/README.md` index. When an issue is confirmed resolved
   (filesystem + runtime/programmatic/manual confirmation), mark **Status:**
   in that issue file (or merge unique detail into the existing topic file)
   rather than archiving into a second megafile.
   **Findings style (hard):** keep files simple and readable. Basic
   markdown only: short headings, bullets, fenced code blocks for commands
   and log excerpts. No tables, no wide comparison grids, no HTML, no
   badge walls, no changelog novels. Write in the same plain voice as the
   main README. When editing an existing findings file, **do not drop
   durable facts** (root causes, paths, config knobs, verified fixes,
   key log lines). Tighten wording and cut stale blow-by-blow, but keep
   the lessons. Prefer symptom-oriented filenames agents can find via
   GitHub code search / MCP (`wifi-missing-on-bare-metal.md`,
   `ghcr-canary-prune.md`), not vague names like `notes.md` or
   `misc-debug.md`. Put searchable keywords (component, failure mode,
   package name) in the title and first paragraph.
5. **Key log lines live in the topic file.** When a CI run, journal, or
   local script fails or proves a fix, copy the smallest useful excerpt
   (command, error, or success signature) into the matching
   `findings/*.md` file. Do not keep a `findings/logs/` archive. Full CI
   dumps and unusable chunks do not belong in the repo.
6. **Scripts are real, tested artifacts**, not one-off snippets. Anything
   written to help build, test, or download this project's images goes in
   `/scripts/`, gets documented, and gets actually run (not just written) as
   part of whatever task produced it.
7. **README.md documents the system, not superlatives.** Focus on what's
   actually included and what packages/components come from Azure Linux
   directly, not package counts or percentages, and not marketing language.
8. **Split validation intentionally: local quick proofs first, intensive runs
   in Actions only when needed.** Start with the fastest meaningful local
   proof (container/overlay/package-resolve/config-render checks, then mount
   and inspect artifacts). Use GitHub Actions for rebuild-heavy, time-
   expensive, or environment-authoritative checks after local proof is
   complete. Do not spend open-ended time making Podman behave exactly like an
   Actions runner when the product fix is already demonstrated locally. If a
   local preflight run is stretching past ~15 minutes or repeatedly diverges
   from Actions behavior, stop extending that local loop and move the check
   into a workflow with artifact logs.
9. **Release artifacts are the final evidence.** Download every published ISO
   and disk image with the project downloader, verify its checksum, run the
   matching scripts in `/scripts/`, and compare mounted package/configuration
   state across the live, disk, and installer paths before calling a release
   complete.
10. **Package policy needs runtime coverage.** Keep the canary container and
   its tests current as an early warning for dependency drift. Test package
   updates and installation from both intended package sources, plus a Flatpak
   install, on the actual image before release.
11. **Keep the artifacts in reasonable parity.** The live ISO, disk images,
    installer ISO, and installed target should share packages and behavior
    wherever their different boot and install lifecycles allow it. The canary
    container is intentionally much smaller: it is a fast canary for the same
    repository mixing, source priority, project-specific RPMs, side-loaded
    tools, and Plymouth package policy, not a desktop test suite. Keep every
    custom package/repository/tool in that canary, but do not add GNOME, GDM,
    Mutter, or a desktop package group merely to make it look like an image.
    GUI library dependencies pulled by the selected tools are expected.

12. **Vendor tools stay on latest at build time.** Microsoft and GitHub
    yum packages are unversioned in kickstarts. Side-loads (Copilot GUI/CLI,
    microsoft/edit, Flathub repo file) go through
    `scripts/fetch-latest-thirdparty.sh` and fail the build if latest cannot
    be resolved. CI may snapshot NEVRAs with
    `scripts/log-latest-vendor-packages.sh`. See
    `findings/latest-vendor-packages.md`.
13. **Catalogs for agents.** Topic notes live as `findings/*.md` only
    (no central index, no `findings/README.md`). Filename + first
    heading are the catalog. `scripts/README.md` indexes build/test
    helpers. Prefer those over rediscovering paths by grep alone.


## Problem-solving approach

1. **Start with the product outcome.** Reproduce the failure enough to know
   whether it affects an image, installer, release artifact, or only the
   development harness. Do not mistake a local-tool failure for a product
   failure.
2. **Use the smallest meaningful proof.** Validate dependency resolution,
   configuration rendering, artifact construction, and runtime behavior in
   that order. Stop a line of investigation once it no longer increases
   confidence in the intended product behavior.
3. **Dispatch research agents before guessing.** When hitting any non-trivial
   issue — a behavior that isn't understood, a component whose internals
   aren't known, a config knob whose effect isn't certain — stop and dispatch
   a research agent first. Check what upstream Azure Linux (`microsoft/azurelinux`)
   does, what Fedora does, what the relevant man pages say, what public bug
   reports exist, and what sample code or CI configs show. Record the findings
   in `findings/`. Do not trial-and-error guess or rabbit-hole down on issues
   when a 5-minute research dispatch can establish the right answer. This
   applies to Plymouth config, dracut modules, dconf behavior, GNOME internals,
   kickstart syntax, KIWI behavior, and anything else where guessing risks
   wasted build cycles or wrong fixes landing in artifacts.
4. **Run a documented issue loop.** For each issue: state the observed
   failure, capture concrete evidence, apply one scoped fix, verify both
   on-disk and runtime behavior, then record pass/fail in `findings/` before
   moving on.
5. **Escalate repeated blockers early.** After multiple informed attempts,
   dispatch a research agent to find upstream reports, established fixes, and
   environmental constraints. Then step back and compare the cost of another
   workaround with the project's actual goal.
5. **Choose the authoritative path deliberately.** Local Podman testing is
   valuable preflight coverage. GitHub Actions is authoritative for its
   published artifacts. When a host-only difference remains after local
   product proof, build in Actions and test the resulting artifact locally
   instead of trying to reproduce every runner detail. Keep non-GUI package
   and repo-priority checks batchable in CI with per-check logs/artifacts so
   iteration can move forward when local parity hits diminishing returns.
6. **Preserve the decision.** Record the failure, evidence, scope of any
   workaround, and the remaining validation in `findings/`. Paste the key
   log lines into that same topic file. Update these instructions when the
   lesson is general enough to prevent the next avoidable rabbit hole.

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
  - **Simple English**: write in short, plain sentences. Prefer common words,
    active voice, and one idea per sentence. Avoid filler, marketing words,
    and long stacks of jargon. Keep the main point in the first sentence. The
    Simple English guide at https://github.com/AminBlg/SimpleEnglish is the
    reference for this repo's docs and replies.
  - **Version wording**: do not introduce new hard-coded upstream desktop or
  distribution version references in docs or comments. Describe the package
  boundary or supported baseline instead, unless a version is required as
  executable configuration.
- **Model selection for agents/research**: match the model to the task.
  Use a lighter/faster model (e.g. Haiku-tier) for mechanical, well-defined
  work (log pruning, simple lookups, straightforward doc updates). Use a
  deeper-reasoning model (e.g. Opus-tier) for genuinely hard problems —
  tracing bugs through unfamiliar source trees, architecture decisions with
  real tradeoffs, anything where a shallow pass has already failed once. The
  priority is a working, well-tested personal project, not a perfect local
  clone of GitHub Actions.
- **AIC usage discipline for verification**: do as much screen-capture
  computation and behavioral analysis on-device as possible (image diffs,
  scripted interaction checks, local parsing) before sending visual data into
  model interpretation. Use model-side image analysis only when local evidence
  cannot resolve an unknown.
- **CI hygiene**: only re-run the specific build (ISO vs disk images, and
  going forward the more granular qcow2/VHDX/VDI/VMDK split) that actually
  needs iterating on. Cancel a premature run immediately. Once a failure or
  cancellation is diagnosed and the useful lines are in the matching
  `findings/*.md` topic file, delete the run so the Actions list stays
  useful.
- **Preflight cadence**: keep preflight checks broken into small, reportable
  units with visible progress and per-step logs. If a grouped local preflight
  run stalls or exceeds the practical local budget, offload the non-GUI
  checks (package resolution, repo priority, canary policy checks) to
  a dedicated Actions workflow rather than extending a long opaque local run.
- **Publication (`release.yml`) and focused debugging**: one workflow
  owns publication. Schedule (`30 05 * * *` UTC) runs the full set:
  wipe prior GitHub releases/tags, mint a fresh UTC-date tag with
  `.github/release-notes-template.md`, detect/publish desktop kmods when
  needed, build live ISO + qcow2 + VHDX/VDI/VMDK + installer ISO, build
  and test the canary container. Each finished product is hashed, split,
  and attached to the release **inside** its build job via
  `scripts/ci-upload-release-asset.sh` (pass `release_tag` from
  `create-release`). No parent `upload-*` jobs — that used to wait on
  the whole reusable call. Keep the qcow2 Actions artifact for convert
  jobs; VHDX/VDI/VMDK are release-only when `release_tag` is set.
  Manual dispatch exposes boolean flags for `live_iso`, `installer_iso`,
  `qcow2`, `vhdx`, `vdi`, `vmdk`, `canary`, `kmods`, and
  `replace_release`. Leave `replace_release` off for focused rebuilds so
  `scripts/resolve-release-tag.sh` attaches to the single current
  release and only clobbers the assets this run built. Schedule always
  sets `replace_release`. There is no separate build-only or canary-only
  workflow file, and no 3-day canary cron.
  `publish-desktop-kmods.yml` stays a hybrid on purpose: its own early
  kernel-drift schedule/dispatch plus `workflow_call` from `release.yml`
  when `kmods` is on. No push triggers on any workflow — spend budget on
  daily release, weekly containers, and the kmod drift schedule only.
  Do not fold kmods into `release.yml` only; kernel drift must refresh
  the Pages DNF repo without a full ISO night.
  `build-live-iso.yml` / `build-installer-iso.yml` are reusable only
  (`prepare_kernel_modules` defaults off when release already ran kmods).
  `Get-AzureLinuxDesktop.ps1` reads `/releases/latest`. Download released
  artifacts via `Get-AzureLinuxDesktop.ps1 -Live` or `-Install`; download
  mid-run Actions artifacts via `aria2c -x 16` with
  `--header="Authorization: Bearer $(gh auth token)"` against the
  `https://api.github.com/repos/sirredbeard/azurelinux-desktop/actions/artifacts/<id>/zip`
  URL. Local scratch downloads and ISO work go under `~/azl-work`, not
  `/tmp` for multi-gigabyte assets.
- **Parity, linting, and reusable scripts**: carry a package, repository,
  side-load, or priority change through every applicable live, installer, and
  canary path. Add build/test/download helpers under `/scripts/`, run them
  before committing, and retain them when they are generally useful. Before
  pushing workflow or script changes, lint all Bash with ShellCheck, all
  workflow files with actionlint (after confirming ShellCheck is on PATH), and
  all PowerShell with PSScriptAnalyzer.
- **No subdirectory README.md files.** Keep documentation in the root
  `README.md`, `findings/*.md`, and `.github/copilot-instructions.md`.
  Do not create or recreate `scripts/README.md`, `containers/README.md`,
  `kickstart/README.md`, or other nested README index files.
- **Config files live under `assets/`, then `install -m`.** Do not build
  product config with `cat > ... << EOF` or kickstart-parsing `awk` in
  image/canary paths. Put `.repo`, dconf, systemd drop-ins, and scripts
  in `assets/` and copy them with `install -m 0644` / `0755`.
- **Canary is a real Dockerfile.** `containers/canary/Dockerfile` builds
  with docker from the repo root (static `assets/yum.repos.d`, pkglist).
  Do not nest podman inside docker for GHCR builds; CI uses docker only
  for containers.yml.
- **Runner pickup over peak core count.** All workflow defaults use
  `ubuntu-24.04` (`AZL_RUNNER_LIGHT` / `AZL_RUNNER_HEAVY` /
  `AZL_RUNNER_CONVERT` / `AZL_RUNNER_KMOD` overrides only when you set
  repo vars). Prefer starting soon on a standard runner over waiting on
  larger labels.
- **Wallpaper/background scope**: do not introduce a new RPM/package solely
  for wallpaper or desktop background changes while closing final-polish
  issues. Resolve background behavior within existing image assets,
  configuration, and package sets.
- **Asset staging in kickstarts**: always use `install -m 0644` (data
  files) and `install -m 0755` (executables) instead of `cp -v` when
  copying assets in kickstart `%post` sections. `cp -v` preserves the
  source's permissions verbatim; the Fedora 43 build container that
  processes `assets.tar.gz` for the installer ISO runs with umask 077,
  so extracted files land at mode 600. GNOME Shell (running as the user)
  can't read a mode-600 `.desktop` file and silently drops it from the
  dash/favorites — confirmed root cause of PowerShell missing from the
  installed GNOME dash. `install -m 0644` forces the correct mode
  regardless of umask. Apply to all three kickstarts whenever adding or
  changing an asset staging block.
- **Installer disk partitioning**: disk partitioning is delegated to
  Anaconda's interactive TUI. Do not re-add `clearpart`/`autopart`
  directives to the installer kickstart. Keep bare `bootloader` (not
  `--location=mbr`) and bare `reqpart` so UEFI still gets an ESP when
  the user picks Standard Partition + use all free space (without
  `reqpart`, Anaconda can omit `/boot/efi` and fail). See
  `findings/installer-efi-separate-partition.md`.
- **Plymouth on installed systems**: do not include `console=ttyS0,...`
  in the installed system's kernel cmdline for desktop use. Azure Linux
  upstream inherits serial console parameters from its cloud/datacenter
  origin; on a desktop boot, `/sys/class/tty/console/active` then
  contains `ttyS0`, Plymouth detects a serial console, and the graphical
  splash is suppressed. `kiwi/post-bootloader.sh` must not inject serial
  console params into the normal boot BLS entry (rescue entry is fine to
  omit them too).
- **Installed system GRUB must use gfxterm**: `kiwi/post-bootloader.sh`
  writes the installed system's `/boot/grub2/grub.cfg`. Use
  `insmod efi_gop`, `insmod efi_uga`, `insmod all_video`,
  `set gfxmode=auto`, `set gfxpayload=keep`, `terminal_output gfxterm`,
  `terminal_input console`. Do NOT use `terminal_output console serial`;
  that forces text-mode GRUB (breaks `gfxpayload=keep`) and adds serial
  overhead on hardware that doesn't have a serial port. The installer ISO's
  own GRUB (`kiwi/grub_template.cfg`) already uses gfxterm; the installed
  system GRUB should match for a consistent desktop boot experience.
- **EFI vendor path**: our kickstart excludes Azure Linux's `shim-x64` and
  `grub2-efi-x64`; Fedora's Secure Boot-signed shim/grub RPMs install
  their binaries to `EFI/fedora/`, but Anaconda's NVRAM entry points to
  `EFI/azurelinux/shimx64.efi`. `kiwi/post-bootloader.sh` copies the
  Fedora EFI binaries to `EFI/azurelinux/` when absent. Don't reintroduce
  Azure Linux's unsigned shim/grub just to avoid this copy step.
- **Out-of-tree Bluetooth kmod layout:** Azure Linux x86_64 leaves
  `CONFIG_BT` off. The project bluetooth kmod must build `net/bluetooth`
  and `drivers/bluetooth` with matching `CONFIG_BT_LEDS` (and related)
  options. A mismatch shifts `struct hci_dev` and Oopses in
  `sk_skb_reason_drop` while Settings shows Bluetooth stuck off. See
  `findings/bluetooth-hci-timeout-thinkpad.md` and
  `scripts/build-desktop-kmods.sh`.
- **Interactive QEMU/GNOME testing**: quirks, caveats, and the SSH
  port-forwarding pattern for GNOME Wayland testing inside QEMU are
  documented in `findings/qemu-gnome-interactive-testing.md`. Read that
  file before attempting any QEMU guest interaction. Key: Wayland mouse
  clicks via QEMU monitor are unreliable; SSH into the guest with
  `hostfwd=tcp::2222-:22`; the default user shell is `pwsh`, so use
  `bash -c '...'` explicitly in SSH commands.

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
  trace in `findings/github-actions-build.md`, "BUG #5 - RESOLVED"):
  switch the disk image to **UEFI/GPT**, matching what the installed
  system should be using anyway - BIOS was never the right target here.
  Two more bugs surfaced only after the first real QEMU boot test of the
  resulting image (see the "Disk image confirmed to genuinely boot"
  section onward): the root partition didn't grow to fill the resized
  disk (fixed with `azl-growroot.service`, `cloud-utils-growpart` +
  `xfs_growfs`), and the VHDX conversion was sourced from the pre-resize
  raw image instead of the resized qcow2 (fixed by reordering the
  conversion). Both confirmed fixed against two consecutive real CI runs.
- **Why not just use Azure Linux's own Image Customizer/KIWI-NG for disk
  images**, which is what Microsoft's own Azure Linux release process
  actually uses: its own CI needs `losetup -P` (partition-scanning loop
  devices), which is confirmed broken on GitHub-hosted runners (see
  `findings/github-actions-build.md`) - that's why Image Customizer's own
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
- **Canary container image** (`release.yml` canary jobs,
  `scripts/build-canary-container.sh`): publishes a small OCI image to
  GHCR straight from the kickstart's own repo/priority setup, the same
  idea as Azure Linux's own upstream `container-base` (systemd=false,
  non-bootable, tiny package set - see `microsoft/azurelinux`'s
  `base/images/container-base/container-base.kiwi` and `images.toml`).
  Not a containerized desktop (GNOME needs systemd/D-Bus/a display, none
  of which belong in a plain OCI container) - it's a fast, always-fresh
  proof that the Azure-Linux-base + Fedora-GNOME-layer repo priority
  split still resolves packages from the intended repo, publishable so
  it can be pulled and inspected without a full ISO/disk-image build.
  Keep its package and repository policy aligned with the image inputs,
  but keep its scope narrow: repo-mixing and priority regression checks,
  not the desktop's runtime suite. `release.yml` builds, pushes, and
  tests the canary whenever the canary flag is on (always on schedule)
  and must keep covering DNF update/upgrade, Azure and Fedora package
  origins, the project-specific tools, and representative Flatpaks.
  Preserve its version and transaction logs as workflow artifacts.
- **Download script**: `scripts/Get-AzureLinuxDesktop.ps1` mirrors
  whatever image formats the release actually publishes - keep its
  `-Kvm`/`-Hyperv`/`-VirtualBox`/`-VMWare`-style options and README's
  documentation of them in sync with whatever the release workflow
  actually produces at any given time.


## OpenPGP signing (Flatpak remote + desktop kmod RPMs)

One shared OpenPGP key covers:

1. **Copilot Flatpak** on `sirredbeard/copilot-desktop-gtk` Pages (OSTree
   tips + `GPGKey=` in `.flatpakref`). Live/installer do **not** ship a
   separate Flatpak key file; they install from the signed `.flatpakref`
   (`scripts/install-copilot-desktop-flatpak.sh` asserts `gpg-verify=true`)
   and stage polkit for unprivileged Deploy.
2. **Desktop kmod RPMs** on this repo's Pages DNF tree
   (`https://sirredbeard.github.io/azurelinux-desktop/repo/`).

### Key identity

- UID: `Hayden Barnes (sirredbeard)`
- Email: `gpg@sirredbeard.github.io`
- Short id: see `packaging/gpg/keyid.txt`
- Public file in-tree: `packaging/gpg/public.asc` and
  `assets/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop`

### Actions secrets (`sirredbeard/azurelinux-desktop`)

Same names and material as `copilot-desktop-gtk`:

| Secret | Purpose |
| --- | --- |
| `GPG_PRIVATE_KEY` | Armored private key (CI signing) |
| `GPG_PUBLIC_KEY` | Armored public key |
| `GPG_KEY_ID` | Short key id |

`gh secret list -R sirredbeard/azurelinux-desktop` shows names only.
GitHub never returns values. Keep a private offline backup. Detail:
`packaging/gpg/README.md`.

### Workflows and clients

- `publish-desktop-kmods.yml` runs `scripts/sign-desktop-rpms.sh` on every
  RPM in the staged tree **before** `createrepo_c`, then publishes
  `RPM-GPG-KEY-azurelinux-desktop` at the Pages site root.
- Images also seed `/usr/share/azurelinux-desktop/gpg/signing-key.asc` (same public key).
- Image `.repo` files use `gpgcheck=1` and
  `gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop`
  (live kickstart, installer `post-install.sh`, canary).
- After key rotation: update secrets on **both** GitHub repos, resign
  kmods (`republish=true`), and cut a new Copilot Flatpak release.

### Flatpak on live/installer (summary)

- Seeded trust comes from Pages `.flatpakref` `GPGKey=` at prestage time,
  not from a baked-in keyring file.
- Polkit: `assets/polkit-1/rules.d/10-azurelinux-desktop-flatpak.rules`
- Findings: `findings/flatpak-untrusted-non-gpg-remote.md`

## Where things live

- `.github/workflows/` - five workflows, none on push:
  `release.yml` (daily publication + manual flags), `containers.yml`
  (weekly GHCR lifecycle for build-lorax/kiwi/kmods/canary plus
  `workflow_call` from release), `build-live-iso.yml` /
  `build-installer-iso.yml` (reusable only; pull prebuilt tool images),
  `publish-desktop-kmods.yml` (Pages DNF repo; nightly drift schedule,
  dispatch, and `workflow_call` from `release.yml` — keep separate;
  uses build-kmods image). Local preflight lives under `scripts/`
  (for example `run-preflight-split.sh`, `test-container-repos.sh`);
  there is no separate preflight Actions workflow. Guest boot testing
  stays local; do not add a GitHub Actions KVM or TCG guest-test
  workflow.
- `containers/` - Dockerfiles / canary build script for GHCR images.
  See `findings/ci-prebuilt-build-containers.md`.
- `kickstart/` - the kickstart(s) driving the ISO builds, the disk-image
  build, and (indirectly, via `scripts/build-canary-container.sh` parsing
  its repo/package setup) the canary container.
- `kiwi/` - the installer ISO's KIWI-NG description (see "Build
  architecture" above) - this IS the current installer-ISO path, unlike
  the abandoned mkosi disk-image exploration.
- `scripts/` - the PowerShell download script and QEMU/podman test/build
  scripts this project publishes and dogfoods. Anything written here
  should actually get run against a real build, not just committed
  unverified.
- `findings/` - the project's institutional memory. Read the relevant file
  before debugging something that feels like it's been hit before. Key log
  evidence belongs inside those topic files, not a side archive.

## A note on continuity

This file, `README.md`, and `findings/*.md` together are meant to carry
enough real technical detail that a fresh agent session (after a context
reset/compaction) can pick this project back up without re-discovering
things that have already been debugged once. When you learn something
substantial - a root cause, a dead end, an architecture decision and why -
write it down in one of these three places before moving on, not just in
chat.
