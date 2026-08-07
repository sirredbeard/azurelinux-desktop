# Hardware acceleration on ThinkPad T470s (metal)

**Status:** Metal check 2026-08-06 on `20JTS0D500` (T470s), Intel
Core i5-6300U + **HD Graphics 520 (Skylake GT2, PCI 8086:1916)**.

## Display / 3D / Vulkan — OK

| Layer | State |
| --- | --- |
| Kernel DRM | `i915` loaded; DMC firmware `i915/skl_dmc_ver1_27.bin` |
| `/dev/dri` | `card1` + `renderD128` |
| Mesa | `mesa-dri-drivers`, `mesa-libGL/EGL/gbm`, `mesa-vulkan-drivers` 25.3.6 |
| Vulkan | `Intel(R) HD Graphics 520 (SKL GT2)` via Mesa Intel ICD |
| Firmware blob package | `intel-gpu-firmware` (AZL) |

No discrete GPU. `xe` driver not used (correct for Gen9). Open-source
stack is the right stack; no NVIDIA proprietary driver applies.

## Video decode/encode (VA-API) — was incomplete

Image listed Fedora **`libva-intel-media-driver`**, which is built from
**`intel-media-driver-free`**: patent-unencumbered profiles only.

Metal `vainfo` with free driver:

* MPEG2, JPEG, VP8 only  
* **No H.264 / HEVC** (what browsers and most local video need)

Swap to RPM Fusion nonfree **`intel-media-driver`**:

* H.264 Main/High/ConstrainedBaseline VLD + encode  
* HEVC Main VLD + encode  
* VP8, VC1, JPEG, MPEG2, VPP, etc.

Also present and useful:

* `libva`, `intel-mediasdk`, `libvpl` / `intel-vpl-gpu-rt` (deps/stack)
* `ffmpeg` (RPM Fusion) + `gstreamer1-plugin-libav`

## Product change

Replace package name in live `%packages` and installer `TARGET_PKGS`:

* remove: `libva-intel-media-driver` (Fedora free)
* add: `intel-media-driver` (rpmfusion-nonfree)

Keep `libva` + `intel-mediasdk`.

## Optional gaps (not blocking metal)

* `gstreamer1-vaapi` not installed — helps Totem/GTK pipelines; Edge/Chromium often talk VA-API more directly.
* Diagnostic tools (`libva-utils`, `vulkan-tools`, `mesa-demos`) not on the image by default; install when debugging.
* Desktop user is in `wheel` only; logind ACLs + world-writable `renderD128` are enough for GPU access here.
* Metal host was missing some `/etc/pki/rpm-gpg/*` keys until copied from `assets/pki/rpm-gpg` (older install or incomplete key stage). Current live/installer `%post` is supposed to install and `rpm --import` them.

## Bottom line for this device

| Need | Covered? |
| --- | --- |
| KMS / GNOME Wayland on i915 | Yes |
| OpenGL / GLES (Mesa) | Yes |
| Vulkan | Yes |
| H.264/HEVC VA-API | Yes after `intel-media-driver` (nonfree) |
| AMD/NVIDIA dGPU drivers | N/A on this SKU |
