# Full multimedia + Intel GPU acceleration (live, installer, canary)

**Status:** Product policy 2026-08-06. Live, installer target, and canary
ship the full stack: Mesa/Vulkan, RPM Fusion Intel iHD, GStreamer VA-API,
ffmpeg, and patent-encumbered gst plugins (mp3/h264/aac paths).

## Goals (Intel laptops like T470s HD 520)

| Capability | Packages / mechanism |
| --- | --- |
| OpenGL / GLES | `mesa-dri-drivers` (+ libglvnd from deps) |
| Vulkan | `mesa-vulkan-drivers` + `vulkan-loader` |
| VA-API (H.264/HEVC HW) | `libva` + **`intel-media-driver`** (RPM Fusion **nonfree**) + `intel-mediasdk` |
| GStreamer ↔ VA-API | **`gstreamer1-vaapi`** |
| Software H.264 | `ffmpeg`, `gstreamer1-plugin-libav`, `gstreamer1-plugin-openh264` |
| MP3 / “ugly” codecs | `gstreamer1-plugins-ugly` (RPM Fusion free) + keep `ugly-free` baseline |
| Extra freeworld codecs | `gstreamer1-plugins-bad-freeworld` (RPM Fusion free) |
| VDPAU apps on Intel | `libvdpau` + **`libvdpau-va-gl`** (bridge; no native Intel VDPAU) |
| Mesa VA fallback | `mesa-va-drivers` (Gallium; iHD is preferred for Intel Gen9+) |

## Critical package choice: free vs full Intel media driver

| Package | Repo | Result on metal HD 520 |
| --- | --- | --- |
| `libva-intel-media-driver` | Fedora | **Free-only** iHD — MPEG2/JPEG/VP8. **No H.264/HEVC.** |
| `intel-media-driver` | RPM Fusion nonfree | Full iHD — **H.264 + HEVC** decode/encode |

**Must not** leave the free package installed. Canary build/test fail if
`libva-intel-media-driver` is present.

Metal proof: `vainfo` gained `VAProfileH264*` / `VAProfileHEVCMain` only
after `dnf swap libva-intel-media-driver intel-media-driver`.
Details: `intel-hw-video-accel.md`.

## Deliverable matrix

| Artifact | Full stack listed | Notes |
| --- | --- | --- |
| Live ISO / VMs | `kickstart/azurelinux-desktop-live.ks` `%packages` | gst ugly/freeworld/vaapi + mesa/vulkan + intel-media-driver |
| Installer → disk | `kiwi/config.sh` TARGET_PKGS | Same set; offline repo needs rpmfusion free+nonfree |
| Canary OCI | `build-canary-container.sh` PKGS + tests | Asserts packages; rejects free-only iHD |
| This metal host | Applied with dnf 2026-08-06 | Stack verified; restart apps after install |

## Not listed (and why)

* **`mesa-vdpau-drivers`** — only older Mesa (25.2.x) in repos while the
  image tracks Mesa 25.3.x; would force a downgrade. Intel uses VA-API;
  VDPAU consumers use `libvdpau-va-gl`.
* Diagnostic tools (`libva-utils`, `vulkan-tools`, `mesa-demos`) — optional
  for debugging, not required at runtime.

## RPM DB note (related testing)

World-read on `rpmdb.sqlite` is restored on live, installer, and canary
so non-root `rpm -q` works in tests and desktop sessions. See
`rpmdb-permissions.md`.

## Related

* `intel-hw-video-accel.md` — T470s metal inventory
* `fedora-azl-repo-mixing.md` — RPM Fusion repos/cost
* Live kickstart comments on patent-free vs RPM Fusion codecs
