# dnf update skips ffmpeg-libs and openapv-libs

`dnf update` on a fresh install from the 2026.11.16 installer reported:

```
Problem: installed package ffmpeg-libs-9.0.2-3.fc45.x86_64 requires
liboapv.so.3()(64bit), but none of the providers can be installed
 - cannot install both openapv-libs-1.1.3.0-1.fc45.x86_64 from
   fedora45-updates and openapv-libs-0.3.0.0-1.fc45.x86_64 from @System
 - cannot install the best update candidate for package
   ffmpeg-libs-9.0.2-3.fc45.x86_64
Skipping packages with conflicts:
openapv-libs  x86_64  1.1.3.0-1.fc45  fedora45-updates
Nothing to do.
```

Fedora updates bumped openapv-libs from 0.3.0.0 to 1.1.3.0. The soname
moved with it: liboapv.so.3 in the release tree, liboapv.so.11 in
updates. RPM Fusion rebuilt ffmpeg-libs against the new soname
(9.0.2-4, requires liboapv.so.11), and that build only exists in RPM
Fusion's updates tree.

Our shipped repo files never defined the RPM Fusion updates repos.
assets/yum.repos.d/azl-desktop-rpmfusion.repo and the combined
azurelinux-desktop.repo carried only rpmfusion-free and
rpmfusion-nonfree (the release trees). An installed system could see
the Fedora library bump but never the matching ffmpeg rebuild, so dnf
skipped both packages and every update run deadlocked on the pair.

Fix: add rpmfusion-free-updates and rpmfusion-nonfree-updates
(mirrorlists free-fedora-updates-released-45 and
nonfree-fedora-updates-released-45) to both repo files. The installer
kickstart and the live kickstart install the rpmfusion asset as-is, so
new images pick the fix up from the asset. azurelinux-desktop-policy
now also ships azl-desktop-rpmfusion.repo as a %config(noreplace)
payload in both build paths (scripts/build-desktop-kmods.sh and the
rebuild in publish-desktop-kmods.yml), so the fix reaches installed
systems through the normal policy refresh instead of waiting for a
reinstall.

Verified against the live repos: release openapv-libs provides
liboapv.so.3, updates provides liboapv.so.11, RPM Fusion release
ffmpeg-libs requires liboapv.so.3, RPM Fusion updates ffmpeg-libs
requires liboapv.so.11. An x86_64 installroot test starting from the
release package set reproduced the solver problem on upgrade with
only the release RPM Fusion repo defined; adding the updates repo
resolved the whole transaction (ffmpeg-libs-9.0.2-4,
openapv-libs-1.1.3.0).

The same test caught a second instance of the same defect:
libheif-freeworld from RPM Fusion release is exact-NVR locked to
Fedora's libheif, Fedora updates moved libheif 1.23.5 to 1.23.7, and
the matching libheif-freeworld rebuild also lives only in RPM
Fusion updates. It deadlocked the same way and resolved with the
same fix.

Lesson: a repo set that mixes a rolling updates feed (Fedora) with a
frozen release feed (RPM Fusion) breaks the first time the rolling
side bumps a soname the frozen side links against. Every repo we ship
needs its updates counterpart shipped with it.
