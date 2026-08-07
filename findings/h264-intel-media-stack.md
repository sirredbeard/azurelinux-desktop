# Full multimedia and Intel GPU stack

**Status:** Product policy. Live, installer target, and canary ship the
full stack: Mesa/Vulkan, RPM Fusion Intel iHD, GStreamer VA-API, ffmpeg,
and patent-encumbered gst plugins (mp3/h264/aac paths).

## Goals (Intel laptops like T470s HD 520)

- OpenGL / GLES: `mesa-dri-drivers` (plus libglvnd from deps)
- Vulkan: `mesa-vulkan-drivers` + `vulkan-loader`
- VA-API (H.264/HEVC HW): `libva` + `intel-media-driver` (RPM Fusion
  nonfree) + `intel-mediasdk`
- GStreamer to VA-API: `gstreamer1-vaapi`
- Software H.264: `ffmpeg`, `gstreamer1-plugin-libav`,
  `gstreamer1-plugin-openh264`
- MP3 / ugly codecs: `gstreamer1-plugins-ugly` (RPM Fusion free) plus
  keep `ugly-free` baseline
- Extra freeworld codecs: `gstreamer1-plugins-bad-freeworld`
- VDPAU apps on Intel: `libvdpau` + `libvdpau-va-gl` (bridge; no native
  Intel VDPAU)
- Mesa VA fallback: `mesa-va-drivers` (Gallium; iHD preferred for Intel
  Gen9+)

## Critical package choice: free vs full Intel media driver

- `libva-intel-media-driver` (Fedora): free-only iHD. MPEG2/JPEG/VP8.
  No H.264/HEVC.
- `intel-media-driver` (RPM Fusion nonfree): full iHD. H.264 and HEVC
  decode/encode.

Do not leave the free package installed. Canary build/test fail if
`libva-intel-media-driver` is present.

Full iHD shared object path (current RPM Fusion nonfree layout):

* Package file: `/usr/lib64/dri-nonfree/iHD_drv_video.so`
* Product link: `/usr/lib64/dri/iHD_drv_video.so` -> `../dri-nonfree/...`

Fedora libva is patched to search `dri-nonfree`. Azure Linux libva still
defaults to `/usr/lib64/dri` only (no useful `/etc/libva.conf` on AZL).
Canary test run 31149049012 failed when the test only looked under
`dri/` while the RPM only installed under `dri-nonfree/`.

Product fix (live kickstart, KIWI config.sh + post-install, canary
build): `assets/bin/azl-link-intel-ihd`

* Symlink iHD into `/usr/lib64/dri/`
* Drop `/etc/environment.d/50-azurelinux-desktop-libva.conf` with
  `LIBVA_DRIVERS_PATH=/usr/lib64/dri-nonfree:/usr/lib64/dri`

Canary test requires both the real dri-nonfree .so and the dri/ link.

Metal proof: `vainfo` gained `VAProfileH264*` / `VAProfileHEVCMain` only
after `dnf swap libva-intel-media-driver intel-media-driver`.
Details: `intel-hw-video-accel.md`.

## Where it ships

- Live ISO / VMs: `kickstart/azurelinux-desktop-live.ks` packages +
  `%post` runs `azl-link-intel-ihd`
- Installer target: `kiwi/config.sh` + `kiwi/post-install.sh`
- Canary OCI: `build-canary-container.sh` + `test-canary-container.sh`

## Not listed (and why)

- `mesa-vdpau-drivers`: only older Mesa in repos while the image tracks
  newer Mesa; would force a downgrade. Intel uses VA-API; VDPAU
  consumers use `libvdpau-va-gl`.
- Diagnostic tools (`libva-utils`, `vulkan-tools`, `mesa-demos`):
  optional for debugging, not required at runtime.

## RPM DB note

World-read on `rpmdb.sqlite` is restored on live, installer, and canary
so non-root `rpm -q` works. See `rpmdb-permissions.md`.

## Related

- `intel-hw-video-accel.md`: T470s metal inventory
- `fedora-azl-repo-mixing.md`: RPM Fusion repos/cost
- Live kickstart comments on patent-free vs RPM Fusion codecs
