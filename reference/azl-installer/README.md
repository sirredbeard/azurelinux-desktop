# What this directory is

These five files are copied verbatim off the real, official
`AzureLinux-4.0-x86_64.iso` (downloaded from Microsoft, sitting in
`~/Downloads` on the machine this project was researched on) - not
retyped, not paraphrased, not "based on." They came from directly
mounting the ISO and its nested images:

```
mount -o loop,ro AzureLinux-4.0-x86_64.iso /mnt/iso        # LiveOS/squashfs.img
mount -o loop,ro /mnt/iso/LiveOS/squashfs.img /mnt/squash  # LiveOS/rootfs.img
mount -o loop,ro /mnt/squash/LiveOS/rootfs.img /mnt/rootfs # the real installer environment
```

Inside `/mnt/rootfs`, straight `cp`:

- `azl-install.ks` from `/root/azl-install.ks`
- `azl-install-encrypted.ks` from `/root/azl-install-encrypted.ks`
- `post-install.sh` from `/root/post-install.sh`
- `post-bootloader.sh` from `/root/post-bootloader.sh`
- `anaconda-launcher.sh` from `/usr/local/bin/anaconda-launcher.sh`

Full walkthrough of how these were found and what they do is in
`findings/live-iso-and-bare-metal.md`.

## Are these also on GitHub?

Yes. Checked via `gh api` code search and confirmed by diff - Microsoft
publishes this exact installer's source in `microsoft/azurelinux`, under
`base/images/vm-iso-installer/`:

- `anaconda-launcher.sh`, `post-install.sh`, `post-bootloader.sh` are
  **byte-for-byte identical** to what's in this folder, right now, as of
  upstream commit `0e77e25` (checked with a plain `diff`, zero output).
- `azl-install.ks` and `azl-install-encrypted.ks` here are the **rendered**
  output of upstream's `azl-install.ks.in` / `azl-install-encrypted.ks.in`
  templates - identical except for one substitution: upstream's
  `@@PACKAGES@@` placeholder gets filled in at ISO build time with the
  real `%packages --nocore` block you see in the copy here.

**Upstream status as of 2026-07-23:** All 5 files unchanged since `0e77e25`.
Commit `3c2a74a` (2026-05-27) updated `post-bootloader.sh` to prefer
`EFI/azurelinux/` over `EFI/fedora/` for EFI vendor path detection — that
fix is already present in `0e77e25`. Our own `kiwi/post-bootloader.sh` has
been aligned with that same EFI priority order (plus our additional
cross-copy step for the Fedora-on-AZL hybrid shim situation).

Upstream links, pinned to that commit so they don't drift out from under
this note:

- https://github.com/microsoft/azurelinux/blob/0e77e25/base/images/vm-iso-installer/anaconda-launcher.sh
- https://github.com/microsoft/azurelinux/blob/0e77e25/base/images/vm-iso-installer/post-install.sh
- https://github.com/microsoft/azurelinux/blob/0e77e25/base/images/vm-iso-installer/post-bootloader.sh
- https://github.com/microsoft/azurelinux/blob/0e77e25/base/images/vm-iso-installer/azl-install.ks.in
- https://github.com/microsoft/azurelinux/blob/0e77e25/base/images/vm-iso-installer/azl-install-encrypted.ks.in

## Why keep local copies instead of just linking

Both, really, for different reasons:

- The copies here are pinned to the **exact ISO version this whole
  project was researched against** (`AzureLinux-4.0-x86_64.iso`,
  downloaded to `~/Downloads`), including the fully-rendered `.ks` files
  with real package lists in them - the upstream `.ks.in` templates alone
  don't show you that.
- Everything else in `findings/` that references these files (line
  numbers, exact commands, `anaconda-launcher.sh`'s menu logic) stays
  correct and readable without depending on the internet or on upstream
  never changing.
- Upstream is still the link to follow if you want the current, live
  source - past this point-in-time snapshot, for anything actively being
  developed against.
