# dnf update skips libblkid-devel and libmount-devel

Same fight as pinentry/NM-wwan/perl-libs, one level down. `dnf update` on a
fresh install reported:

```
Problem 1: package libmount-devel-2.41.5-1.fc43.x86_64 from fedora43-updates requires libmount(x86-64) = 2.41.5-1.fc43, but none of the providers can be installed
Problem 2: package libblkid-devel-2.41.5-1.fc43.x86_64 from fedora43-updates requires libblkid(x86-64) = 2.41.5-1.fc43, but none of the providers can be installed
```

libblkid and libmount are already clawed to AZL (util-linux) in every
excludepkgs list. Nobody added their -devel subpackages. Fedora happily
offers libblkid-devel/libmount-devel at the exact Fedora NVR, which
hard-requires the exact Fedora libblkid/libmount NVR, which is excluded.
Dangling update, every boot, forever.

Fix: add libblkid-devel and libmount-devel next to libblkid/libmount in
every FEDORA_EXCLUDES-equivalent list - kickstart/azurelinux-desktop-live.ks,
kiwi/config.sh, assets/yum.repos.d/azl-desktop-fedora.repo,
assets/yum.repos.d/azurelinux-desktop.repo. AZL ships its own
libblkid-devel/libmount-devel (util-linux-devel lineage), so this just
tells dnf to use them.

Prevention: `scripts/check-fedora-excludes-consistency.sh` diffs the
excludepkgs list across all four files and fails if any of them drift.
Run it before pushing any change to these lists. The general lesson from
this and the pinentry/NM-wwan/perl-libs fight still holds: whenever a
package is clawed from Fedora to AZL, check for -devel, -libs, or plugin
subpackages that also need clawing, or Fedora's exact-NVR requires will
dangle the same way later.
