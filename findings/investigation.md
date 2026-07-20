# Investigation: can you put a real GNOME desktop on Azure Linux 4.0?

Follow-up to the [WSL-based Azure Linux Desktop project](https://www.boxofcables.dev/azure-linux-desktop-a-build-2026-mashup-of-wslc-winui-reactor-and-azure-linux-4-0/). That ran a themed XFCE session inside WSL. This is the bare-metal version: can Azure Linux 4.0 boot to a real GNOME session on real hardware, with `/etc/os-release` still honestly saying Azure Linux?

Short answer: yes, for a curated GNOME desktop. No, for Fedora's full `workstation-product-environment` comps group. Everything below was tested in `podman` with `dnf --installroot`.

## Azure Linux 4.0 is a Fedora 43 snapshot

| Package | Azure Linux 4.0 | Fedora 43 | Fedora |
|---|---|---|---|
| glibc | `2.42-10.azl4` | Fedora lineage | newer Fedora desktop layer |
| systemd | `258.4-2.azl4` | `258` | `259.5` |
| gnome-shell | (not shipped) | `49.1` | `50.0` |

Same upstream versions, different build tags. `ID_LIKE=fedora` in AZL4's `/etc/os-release` is load-bearing. Fedora (one release ahead, stable GNOME) is the right desktop donor, not rawhide (two releases ahead, glibc symbols AZL4 doesn't have).

## dnf5 repo priority works

```ini
[azl-base]
priority=1    # (later changed to cost=1 - see below)

[Fedora]
priority=50   # (later changed to cost=50)
```

Result with curated GNOME + Microsoft/GitHub tooling: ~530 AZL packages to ~195 Fedora. glibc came from Fedora (mutter hard-requires `GLIBC_2.43`). Everything AZL ships stayed on AZL.

## Three specific conflicts

**`hunspell-en`** - pure file collision, no ABI. Both repos ship it at different versions with identical paths. Fix: exclude from AZL, let Fedora win.

**`gsettings-desktop-schemas`** - version floor. `gnome-shell-50.3` requires `>= 50~alpha`, AZL ships `49.1`. Fix: exclude from AZL.

**`grub2`/`shim` vs `fuse3`** - genuine ABI fork. AZL's `grub2-tools-minimal` links against `libfuse3.so.3`, Fedora's `flatpak`/`xdg-desktop-portal` need `libfuse3.so.4`. Fix: hand the *entire* grub2/shim family to Fedora. Cherry-picking individual libraries out of a coherent dependency tree just moves the same conflict one layer down.

## Don't `dnf group install workstation-product-environment`

The full comps group hits far more conflicts (`NetworkManager-libnm` version locks, `Box2D`/glibc fights, `libdisplay-info` soname bumps, `glycin` mismatches). No static exclude list survives contact with an unpredictable future `dnf install`. The approach that holds: curated initial install, both repos enabled permanently, grow the exclude list as conflicts appear.

## Final validation

Full log: `findings/logs/podman-resolve-full-desktop-947pkgs-edge-canary-code-insiders.log`.

**947 total packages, 729 from Azure Linux, 210 from Fedora, zero conflicts.** `/etc/os-release` still `NAME="Azure Linux"`, `ID=azurelinux`.

Container-test noise: dnf5's `Transaction failed` after `systemd-udev`'s hwdb scriptlet is a container artifact. Trust `rpm -qa` against the result, not dnf5's exit message.

## Update: the 729/210 split is from the abandoned `priority=` approach

After switching to `cost=` (to fix a `grub2-efi-x64-cdboot` conflict - see `gh-actions-installer-iso-build.md`), the real ratio on a built ISO was ~60 AZL / ~1,100 Fedora / ~17 other. `cost=` only tie-breaks identical NEVRAs, it doesn't shadow repos. Fixed with a 93-package `excludepkgs` on Fedora repos, bringing it to **171 Azure Linux / 986 Fedora / 16 other / 1,173 total**. Full investigation: `package-sourcing-clawback.md`.
