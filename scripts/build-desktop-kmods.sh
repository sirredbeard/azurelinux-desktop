#!/usr/bin/env bash
# build-desktop-kmods.sh
#
# Purpose: Build out-of-tree desktop kmod RPMs (USB, BT, sound, Wi-Fi, ...)
#   against a given Azure Linux kernel inside an Azure Linux container.
# Usage:   See header flags inside; usually run via publish-desktop-kmods.yml.
# Needs:   container runtime, kernel-devel matching target kernel, rpmbuild.
# CI:      Yes. publish-desktop-kmods.yml family matrix.

set -euo pipefail

AZL_BASE_URL="${AZL_BASE_URL:-https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64}"
OUTPUT_DIR="${1:?usage: $0 OUTPUT_DIR [kernel-nevra] [stage]}"
REQUESTED_KERNEL="${2:-}"
STAGE="${3:-${DESKTOP_KMOD_STAGE:-all}}"

run_stage() {
    local want="$1"
    [[ "$STAGE" == "all" || "$STAGE" == "$want" ]]
}

mkdir -p "$OUTPUT_DIR"

if [[ -n "$REQUESTED_KERNEL" ]]; then
    KERNEL_QUERY=("$REQUESTED_KERNEL")
else
    KERNEL_QUERY=(--latest-limit=1 kernel)
fi

read -r _ KERNEL_VERSION KERNEL_RELEASE KERNEL_ARCH < <(
    dnf5 repoquery --setopt=reposdir=/dev/null \
        --repofrompath=azl-base,"$AZL_BASE_URL" --repo=azl-base \
        --available \
        --qf '%{name}-%{version}-%{release}.%{arch} %{version} %{release} %{arch}' \
        "${KERNEL_QUERY[@]}"
    printf '\n'
)
KERNEL_EVR="${KERNEL_VERSION}-${KERNEL_RELEASE}"
KERNEL_DEVEL_NEVRA="kernel-devel-${KERNEL_EVR}.${KERNEL_ARCH}"

rpm -q "$KERNEL_DEVEL_NEVRA" >/dev/null 2>&1 || dnf5 install -y \
    --setopt=reposdir=/dev/null --setopt=azl-base.gpgcheck=0 \
    --repofrompath=azl-base,"$AZL_BASE_URL" --repo=azl-base \
    "$KERNEL_DEVEL_NEVRA" \
    bc gcc make perl python3 openssl-devel elfutils-devel elfutils-libelf-devel \
    rpm-build kmod git curl gawk tar gzip findutils which

KVERREL="${KERNEL_EVR}.${KERNEL_ARCH}"
BUILD_DIR="/usr/src/kernels/$KVERREL"

test -f "$BUILD_DIR/.config"
test -f "$BUILD_DIR/Module.symvers"

# Azure's kernel component carries its source fourth-version component as
# the first RPM release component (for example, 6.18.31-1.6.azl4 uses the
# rolling-lts/azl4/6.18.31.1 source).
SOURCE_REF="${KERNEL_VERSION}.${KERNEL_RELEASE%%.*}"

if [[ -n "${DESKTOP_KMOD_WORKDIR:-}" ]]; then
    WORKDIR="$DESKTOP_KMOD_WORKDIR"
    mkdir -p "$WORKDIR"
else
    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT
fi

prepare_source() {
    if [[ -f "$WORKDIR/.prepared" ]]; then
        # shellcheck disable=SC1091
        source "$WORKDIR/env.sh"
        SOURCE_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'CBL-Mariner-Linux-Kernel-*' -print -quit)"
        if [[ -z "$SOURCE_DIR" && -f "$WORKDIR/kernel.tar.gz" ]]; then
            tar -xzf "$WORKDIR/kernel.tar.gz" -C "$WORKDIR"
            SOURCE_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'CBL-Mariner-Linux-Kernel-*' -print -quit)"
        fi
        test -n "$SOURCE_DIR"
        return 0
    fi
    COMPONENT_TOML="$WORKDIR/kernel.comp.toml"
    curl --fail --location --retry 3 \
        https://raw.githubusercontent.com/microsoft/azurelinux/4.0/base/comps/kernel/kernel.comp.toml \
        -o "$COMPONENT_TOML"
    read -r SOURCE_URL SOURCE_SHA512 < <(
        python3 - "$COMPONENT_TOML" "$SOURCE_REF" <<'PY'
import sys
import tomllib

component_path, source_ref = sys.argv[1:]
with open(component_path, "rb") as component_file:
    component = tomllib.load(component_file)

expected_filename = f"kernel-{source_ref}.tar.gz"
for source in component["components"]["kernel"]["source-files"]:
    if source["filename"] == expected_filename:
        print(source["origin"]["uri"], source["hash"])
        break
else:
    raise SystemExit(f"Azure Linux 4.0 does not define {expected_filename}")
PY
    )
    test -n "$SOURCE_URL"
    test -n "$SOURCE_SHA512"
    # Optional host/cache path for local rebuilds (CI leaves unset).
    if [[ -n "${KERNEL_SRC_TARBALL:-}" && -f "$KERNEL_SRC_TARBALL" ]]; then
        cp -f "$KERNEL_SRC_TARBALL" "$WORKDIR/kernel.tar.gz"
    else
        curl --fail --location --retry 3 "$SOURCE_URL" -o "$WORKDIR/kernel.tar.gz"
    fi
    printf '%s  %s\n' "$SOURCE_SHA512" "$WORKDIR/kernel.tar.gz" | sha512sum --check
    # Extract unless prepare-only (CI uploads the tarball; families extract).
    if [[ "${DESKTOP_KMOD_PREPARE_TARBALL_ONLY:-0}" != "1" ]]; then
        tar -xzf "$WORKDIR/kernel.tar.gz" -C "$WORKDIR"
        SOURCE_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'CBL-Mariner-Linux-Kernel-*' -print -quit)"
        test -n "$SOURCE_DIR"
    fi
    cat > "$WORKDIR/env.sh" <<ENV
KVERREL='$KVERREL'
KERNEL_VERSION='$KERNEL_VERSION'
KERNEL_RELEASE='$KERNEL_RELEASE'
KERNEL_ARCH='$KERNEL_ARCH'
KERNEL_EVR='$KERNEL_EVR'
BUILD_DIR='$BUILD_DIR'
ENV
    touch "$WORKDIR/.prepared"
}

if [[ "$STAGE" == "package" ]]; then
    test -f "$WORKDIR/.prepared"
    # shellcheck disable=SC1091
    source "$WORKDIR/env.sh"
    SOURCE_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'CBL-Mariner-Linux-Kernel-*' -print -quit)"
    test -n "$SOURCE_DIR"
else
    prepare_source
    if [[ "$STAGE" == "prepare" ]]; then
        echo "Prepared kernel source for $KVERREL in $WORKDIR"
        exit 0
    fi
fi

check_vermagic() {
    local m
    for m in "$@"; do
        test -f "$m"
        test "$(modinfo -F vermagic "$m" | awk '{print $1}')" = "$KVERREL"
    done
}

# --- usbhid ---
if run_stage usbhid; then
echo "=== stage usbhid ==="
HID_DIR="$WORKDIR/usbhid"
mkdir -p "$HID_DIR"
cp "$SOURCE_DIR/drivers/hid/usbhid/hid-core.c" "$HID_DIR/"
cp "$SOURCE_DIR/drivers/hid/usbhid/"*.h "$HID_DIR/"
cat > "$HID_DIR/Makefile" <<'EOF'
obj-m += usbhid.o
usbhid-y := hid-core.o
EOF
make -C "$BUILD_DIR" M="$HID_DIR" modules
HID_MODULE="$HID_DIR/usbhid.ko"
check_vermagic "$HID_MODULE"
echo "=== stage usbhid done ==="
fi

# --- psmouse (PS/2 mouse; CONFIG_INPUT_MOUSE unset on AZL x86_64) ---
# GNOME Boxes / generic libvirt default to PS/2 mouse for unknown Linux.
# i8042 + libps2 + atkbd are built-in; only the mouse protocol driver is
# missing. aarch64 AZL already has CONFIG_MOUSE_PS2=m. Minimal set is
# psmouse-base + always-linked synaptics/focaltech objects. See
# findings/hypervisor-mouse-ps2-boxes.md.
if run_stage psmouse; then
echo "=== stage psmouse ==="
PS2_DIR="$WORKDIR/psmouse"
mkdir -p "$PS2_DIR"
# psmouse-base.c #includes every protocol header unconditionally;
# optional .c objects stay behind IS_ENABLED(CONFIG_MOUSE_PS2_*).
# Ship all headers from drivers/input/mouse plus the always-built
# objects (psmouse-base, synaptics, focaltech) and trackpoint.
shopt -s nullglob
for f in "$SOURCE_DIR/drivers/input/mouse/"*.h; do
    cp "$f" "$PS2_DIR/"
done
shopt -u nullglob
for f in psmouse-base.c synaptics.c focaltech.c trackpoint.c; do
    if [[ -f "$SOURCE_DIR/drivers/input/mouse/$f" ]]; then
        cp "$SOURCE_DIR/drivers/input/mouse/$f" "$PS2_DIR/"
    fi
done
# Core three always build (upstream psmouse-objs). TrackPoint is small and
# useful on ThinkPads. Skip vmmouse / SMBus / touchpad extras — headers
# provide stubs when CONFIG_MOUSE_PS2_* is unset.
cat > "$PS2_DIR/Makefile" <<'EOF'
# Out-of-tree against AZL x86_64 where CONFIG_INPUT_MOUSE is not set.
ccflags-y += -DCONFIG_INPUT_MOUSE=1
ccflags-y += -DCONFIG_MOUSE_PS2_MODULE=1
ccflags-y += -DCONFIG_MOUSE_PS2_TRACKPOINT=1

obj-m += psmouse.o
psmouse-y := psmouse-base.o synaptics.o focaltech.o trackpoint.o
EOF
if [[ ! -f "$PS2_DIR/trackpoint.c" ]]; then
    sed -i '/trackpoint/d; /TRACKPOINT/d' "$PS2_DIR/Makefile"
fi
# Fail early if a required always-include header is missing from the tree.
for need in psmouse.h synaptics.h focaltech.h logips2pp.h; do
    [[ -f "$PS2_DIR/$need" ]] || {
        echo "error: psmouse missing $need from kernel sources" >&2
        exit 1
    }
done
make -C "$BUILD_DIR" M="$PS2_DIR" modules
PS2_MODULE="$PS2_DIR/psmouse.ko"
check_vermagic "$PS2_MODULE"
echo "=== stage psmouse done ==="
fi

# --- usb-storage + uas (sibling package, same kernel bind) ---
# CONFIG_USB_STORAGE / CONFIG_USB_UAS are not set on AZL 4.0 x86_64.
# Force module variants so IS_ENABLED() paths in the upstream sources
# match a normal =m build. USB core and SCSI mid-layer are built-in.
if run_stage usb-storage; then
echo "=== stage usb-storage ==="
STOR_DIR="$WORKDIR/usb-storage"
mkdir -p "$STOR_DIR"
# Core mass-storage + UAS only (skip ums-* specialty unusual drivers).
for f in \
    scsiglue.c scsiglue.h \
    protocol.c protocol.h \
    transport.c transport.h \
    usb.c usb.h \
    initializers.c initializers.h \
    sierra_ms.c sierra_ms.h \
    option_ms.c option_ms.h \
    usual-tables.c \
    debug.c debug.h \
    uas.c uas-detect.h \
    unusual_devs.h unusual_uas.h
do
    cp "$SOURCE_DIR/drivers/usb/storage/$f" "$STOR_DIR/"
done
# Headers referenced transitively by unusual_devs.h / usual-tables.
for f in "$SOURCE_DIR/drivers/usb/storage/"unusual_*.h; do
    bn="$(basename "$f")"
    [[ -f "$STOR_DIR/$bn" ]] || cp "$f" "$STOR_DIR/"
done
# transport.c includes "../../scsi/sd.h" relative to drivers/usb/storage.
# Copy sd.h locally and rewrite the include for out-of-tree builds.
cp "$SOURCE_DIR/drivers/scsi/sd.h" "$STOR_DIR/sd.h"
sed -i 's|#include "../../scsi/sd.h"|#include "sd.h"|' "$STOR_DIR/transport.c"
cat > "$STOR_DIR/Makefile" <<'EOF'
# Build against AZL kernel-devel where CONFIG_USB_STORAGE is off.
ccflags-y += -I$(src)
ccflags-y += -I$(srctree)/drivers/scsi
ccflags-y += -DDEFAULT_SYMBOL_NAMESPACE='"USB_STORAGE"'
ccflags-y += -DCONFIG_USB_STORAGE_MODULE=1
ccflags-y += -DCONFIG_USB_UAS_MODULE=1

obj-m += usb-storage.o uas.o

usb-storage-y := scsiglue.o protocol.o transport.o usb.o
usb-storage-y += initializers.o sierra_ms.o option_ms.o
usb-storage-y += usual-tables.o
EOF
make -C "$BUILD_DIR" M="$STOR_DIR" modules
STOR_MODULE="$STOR_DIR/usb-storage.ko"
UAS_MODULE="$STOR_DIR/uas.ko"
check_vermagic "$STOR_MODULE" "$UAS_MODULE"
echo "=== stage usb-storage done ==="
fi

# --- iwlwifi + opmodes (Intel Wi-Fi; CONFIG_WLAN off on AZL 4.0 x86_64) ---
# cfg80211 and mac80211 are already =m in the stock kernel. Only the
# vendor drivers under CONFIG_WLAN are missing. Build the full iwlwifi
# tree as external modules.
#
# C preprocessor reads autoconf (where CONFIG_IWL* is unset). Makefile
# obj-$(CONFIG_*) follows the make command line. Force both:
#   - subdir-ccflags CONFIG_*_MODULE defines for IS_ENABLED()
#   - make CONFIG_IWL*=m for object lists
# Leave DEBUGFS and DEVICE_TRACING off: those gate struct fields in
# headers via autoconf while still compiling the .c files if Makefile
# thinks they are enabled.
if run_stage iwlwifi; then
echo "=== stage iwlwifi ==="
IWL_DIR="$WORKDIR/iwlwifi"
rm -rf "$IWL_DIR"
cp -a "$SOURCE_DIR/drivers/net/wireless/intel/iwlwifi" "$IWL_DIR"
{
    cat <<'EOF'
# Out-of-tree build against AZL x86_64 where CONFIG_WLAN / CONFIG_IWL* are off.
subdir-ccflags-y += -DCONFIG_IWLWIFI_MODULE=1
subdir-ccflags-y += -DCONFIG_IWLMVM_MODULE=1
subdir-ccflags-y += -DCONFIG_IWLDVM_MODULE=1
subdir-ccflags-y += -DCONFIG_IWLMLD_MODULE=1
subdir-ccflags-y += -DCONFIG_IWLWIFI_OPMODE_MODULAR=1
subdir-ccflags-y += -DCONFIG_IWLWIFI_LEDS=1
EOF
    cat "$IWL_DIR/Makefile"
} > "$IWL_DIR/Makefile.oot"
mv "$IWL_DIR/Makefile.oot" "$IWL_DIR/Makefile"
make -C "$BUILD_DIR" M="$IWL_DIR" \
    CONFIG_IWLWIFI=m \
    CONFIG_IWLMVM=m \
    CONFIG_IWLDVM=m \
    CONFIG_IWLMLD=m \
    CONFIG_IWLWIFI_OPMODE_MODULAR=y \
    CONFIG_IWLWIFI_LEDS=y \
    CONFIG_IWLWIFI_DEBUGFS=n \
    CONFIG_IWLWIFI_DEVICE_TRACING=n \
    CONFIG_IWLWIFI_KUNIT_TESTS=n \
    CONFIG_IWLMEI=n \
    modules
IWL_MODULE="$IWL_DIR/iwlwifi.ko"
IWL_MVM="$IWL_DIR/mvm/iwlmvm.ko"
IWL_DVM="$IWL_DIR/dvm/iwldvm.ko"
IWL_MLD="$IWL_DIR/mld/iwlmld.ko"
check_vermagic "$IWL_MODULE" "$IWL_MVM" "$IWL_DVM" "$IWL_MLD"
echo "=== stage iwlwifi done ==="
fi

# --- sound: ALSA core + Intel HDA + common codecs + USB audio ---
if run_stage sound; then
echo "=== stage sound ==="
SND_DIR="$WORKDIR/sound"
rm -rf "$SND_DIR"
cp -a "$SOURCE_DIR/sound" "$SND_DIR"
cat > "$WORKDIR/force-snd.h" <<'EOF'
#define CONFIG_SOUND_MODULE 1
#define CONFIG_SND_MODULE 1
#define CONFIG_SND_TIMER_MODULE 1
#define CONFIG_SND_PCM_MODULE 1
#define CONFIG_SND_HWDEP_MODULE 1
#define CONFIG_SND_RAWMIDI_MODULE 1
#define CONFIG_SND_VMASTER 1
#define CONFIG_SND_JACK 1
#define CONFIG_SND_JACK_INPUT_DEV 1
#define CONFIG_SND_PCM_TIMER 1
#define CONFIG_SND_PCM_ELD 1
#define CONFIG_SND_DMA_SGBUF 1
#define CONFIG_SND_DYNAMIC_MINORS 1
/* Integer Kconfig values (not booleans). core.h uses MAX_CARDS when
 * DYNAMIC_MINORS is on; without it the static_assert fails. */
#define CONFIG_SND_MAX_CARDS 32
#define CONFIG_SND_MAJOR 116
#define CONFIG_SND_SUPPORT_OLD_API 1
#define CONFIG_SND_PROC_FS 1
#define CONFIG_SND_VERBOSE_PROCFS 1
#define CONFIG_SND_CTL_FAST_LOOKUP 1
#define CONFIG_SND_PCI 1
#define CONFIG_SND_USB 1
#define CONFIG_SND_HDA_MODULE 1
#define CONFIG_SND_HDA_CORE_MODULE 1
#define CONFIG_SND_HDA_GENERIC_MODULE 1
#define CONFIG_SND_HDA_GENERIC_LEDS 1
#define CONFIG_SND_HDA_INTEL_MODULE 1
#define CONFIG_SND_HDA_COMPONENT 1
#define CONFIG_SND_HDA_SCODEC_COMPONENT_MODULE 1
#define CONFIG_SND_HDA_HWDEP 1
#define CONFIG_SND_HDA_PREALLOC_SIZE 2048
#define CONFIG_SND_HDA_POWER_SAVE_DEFAULT 0
#define CONFIG_SND_INTEL_DSP_CONFIG_MODULE 1
#define CONFIG_SND_INTEL_NHLT 1
#define CONFIG_SND_INTEL_SOUNDWIRE_ACPI_MODULE 1
#define CONFIG_SND_HDA_CODEC_REALTEK_LIB_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC269_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC662_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC880_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC882_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC260_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC262_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC268_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC861_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC861VD_MODULE 1
#define CONFIG_SND_HDA_CODEC_HDMI_GENERIC_MODULE 1
#define CONFIG_SND_HDA_CODEC_HDMI_INTEL_MODULE 1
#define CONFIG_SND_HDA_CODEC_CONEXANT_MODULE 1
#define CONFIG_SND_HDA_CODEC_SIGMATEL_MODULE 1
#define CONFIG_SND_HDA_CODEC_VIA_MODULE 1
#define CONFIG_SND_HDA_CODEC_CMEDIA_MODULE 1
#define CONFIG_SND_USB_AUDIO_MODULE 1
#define CONFIG_SND_USB_AUDIO_USE_MEDIA_CONTROLLER 1
EOF
{
    echo "subdir-ccflags-y += -include $WORKDIR/force-snd.h"
    echo "ccflags-y += -include $WORKDIR/force-snd.h"
    cat <<'EOF'
obj-$(CONFIG_SOUND) += soundcore.o
obj-$(CONFIG_SND) += core/ hda/ usb/
soundcore-y := sound_core.o
EOF
} > "$SND_DIR/Makefile"
cat > "$SND_DIR/usb/Makefile" <<'EOF'
snd-usb-audio-y := card.o clock.o endpoint.o fcp.o format.o helper.o \
	implicit.o mixer.o mixer_quirks.o mixer_scarlett.o mixer_scarlett2.o \
	mixer_us16x08.o mixer_s1810c.o pcm.o power.o proc.o quirks.o \
	stream.o validate.o
snd-usb-audio-$(CONFIG_SND_USB_AUDIO_USE_MEDIA_CONTROLLER) += media.o
snd-usbmidi-lib-y := midi.o
obj-$(CONFIG_SND_USB_AUDIO) += snd-usb-audio.o snd-usbmidi-lib.o
EOF
# Keep upstream codecs Makefile (hdmi/realtek/side-codecs). Only drop
# cirrus amp side-codecs tree noise by leaving those CONFIG_* off.
# Realtek selects SND_HDA_SCODEC_COMPONENT for CS35 amp hooks on some
# laptops; ELD helpers live in core/pcm_drm_eld.o via CONFIG_SND_PCM_ELD.
make -C "$BUILD_DIR" M="$SND_DIR" \
    CONFIG_SOUND=m CONFIG_SND=m CONFIG_SND_TIMER=m CONFIG_SND_PCM=m \
    CONFIG_SND_HWDEP=m CONFIG_SND_RAWMIDI=m CONFIG_SND_SEQUENCER=n \
    CONFIG_SND_OSSEMUL=n CONFIG_SND_HRTIMER=n CONFIG_SND_DYNAMIC_MINORS=y \
    CONFIG_SND_MAX_CARDS=32 CONFIG_SND_MAJOR=116 \
    CONFIG_SND_SUPPORT_OLD_API=y CONFIG_SND_PROC_FS=y CONFIG_SND_VERBOSE_PROCFS=y \
    CONFIG_SND_CTL_FAST_LOOKUP=y CONFIG_SND_DEBUG=n CONFIG_SND_JACK=y \
    CONFIG_SND_JACK_INPUT_DEV=y CONFIG_SND_PCM_TIMER=y CONFIG_SND_PCM_ELD=y \
    CONFIG_SND_VMASTER=y CONFIG_SND_DMA_SGBUF=y CONFIG_SND_PCI=y CONFIG_SND_USB=y \
    CONFIG_SND_HDA=m CONFIG_SND_HDA_CORE=m CONFIG_SND_HDA_GENERIC=m \
    CONFIG_SND_HDA_INTEL=m CONFIG_SND_HDA_TEGRA=n CONFIG_SND_HDA_ACPI=n \
    CONFIG_SND_HDA_COMPONENT=y CONFIG_SND_HDA_I915=n CONFIG_SND_HDA_HWDEP=y \
    CONFIG_SND_HDA_INPUT_BEEP=n CONFIG_SND_HDA_PATCH_LOADER=n \
    CONFIG_SND_HDA_RECONFIG=n CONFIG_SND_HDA_GENERIC_LEDS=y \
    CONFIG_SND_HDA_SCODEC_COMPONENT=m \
    CONFIG_SND_HDA_CIRRUS_SCODEC=n CONFIG_SND_HDA_SCODEC_CS35L41=n \
    CONFIG_SND_HDA_SCODEC_CS35L41_I2C=n CONFIG_SND_HDA_SCODEC_CS35L41_SPI=n \
    CONFIG_SND_HDA_SCODEC_CS35L56=n CONFIG_SND_HDA_SCODEC_CS35L56_I2C=n \
    CONFIG_SND_HDA_SCODEC_CS35L56_SPI=n CONFIG_SND_HDA_SCODEC_TAS2781=n \
    CONFIG_SND_HDA_SCODEC_TAS2781_I2C=n CONFIG_SND_HDA_SCODEC_TAS2781_SPI=n \
    CONFIG_SND_HDA_EXT_CORE=n CONFIG_SND_INTEL_DSP_CONFIG=m \
    CONFIG_SND_INTEL_NHLT=y CONFIG_SND_INTEL_SOUNDWIRE_ACPI=m \
    CONFIG_SND_HDA_CODEC_REALTEK_LIB=m CONFIG_SND_HDA_CODEC_ALC260=m \
    CONFIG_SND_HDA_CODEC_ALC262=m CONFIG_SND_HDA_CODEC_ALC268=m \
    CONFIG_SND_HDA_CODEC_ALC269=m CONFIG_SND_HDA_CODEC_ALC662=m \
    CONFIG_SND_HDA_CODEC_ALC680=n CONFIG_SND_HDA_CODEC_ALC861=m \
    CONFIG_SND_HDA_CODEC_ALC861VD=m CONFIG_SND_HDA_CODEC_ALC880=m \
    CONFIG_SND_HDA_CODEC_ALC882=m CONFIG_SND_HDA_CODEC_HDMI_GENERIC=m \
    CONFIG_SND_HDA_CODEC_HDMI_SIMPLE=n CONFIG_SND_HDA_CODEC_HDMI_INTEL=m \
    CONFIG_SND_HDA_CODEC_HDMI_ATI=n CONFIG_SND_HDA_CODEC_HDMI_NVIDIA=n \
    CONFIG_SND_HDA_CODEC_HDMI_NVIDIA_MCP=n CONFIG_SND_HDA_CODEC_HDMI_TEGRA=n \
    CONFIG_SND_HDA_CODEC_CONEXANT=m CONFIG_SND_HDA_CODEC_SIGMATEL=m \
    CONFIG_SND_HDA_CODEC_VIA=m CONFIG_SND_HDA_CODEC_CMEDIA=m \
    CONFIG_SND_HDA_CODEC_CM9825=n CONFIG_SND_HDA_CODEC_ANALOG=n \
    CONFIG_SND_HDA_CODEC_CA0110=n CONFIG_SND_HDA_CODEC_CA0132=n \
    CONFIG_SND_HDA_CODEC_SENARYTECH=n CONFIG_SND_HDA_CODEC_SI3054=n \
    CONFIG_SND_USB_AUDIO=m CONFIG_SND_USB_AUDIO_MIDI_V2=n \
    CONFIG_SND_USB_AUDIO_USE_MEDIA_CONTROLLER=y CONFIG_SND_USB_UA101=n \
    CONFIG_SND_USB_USX2Y=n CONFIG_SND_USB_CAIAQ=n CONFIG_SND_USB_6FIRE=n \
    CONFIG_SND_USB_HIFACE=n CONFIG_SND_BCD2000=n CONFIG_SND_USB_LINE6=n \
    CONFIG_SND_SOC=n \
    modules
mapfile -t SOUND_MODULES < <(find "$SND_DIR" -name '*.ko' | sort)
test "${#SOUND_MODULES[@]}" -ge 12
check_vermagic "${SOUND_MODULES[@]}"
echo "=== stage sound done ==="
fi

# --- bluetooth ---
if run_stage bluetooth; then
echo "=== stage bluetooth ==="
BTNET_DIR="$WORKDIR/btnet"
rm -rf "$BTNET_DIR"
cp -a "$SOURCE_DIR/net/bluetooth" "$BTNET_DIR"
{
    cat <<'EOF'
# subdir-ccflags-y: rfcomm/, bnep/, hidp/ are subdirs; plain
# ccflags-y does not reach tty.c and rfcomm.h sees no RFCOMM_TTY.
subdir-ccflags-y += -DCONFIG_BT_MODULE=1
subdir-ccflags-y += -DCONFIG_BT_BREDR=1
subdir-ccflags-y += -DCONFIG_BT_LE=1
subdir-ccflags-y += -DCONFIG_BT_HS=1
subdir-ccflags-y += -DCONFIG_BT_LEDS=1
subdir-ccflags-y += -DCONFIG_BT_RFCOMM_MODULE=1
# Must match make CONFIG_BT_RFCOMM_TTY=y. Without this, rfcomm.h
# emits static inline stubs and tty.c redefines rfcomm_*_ttys.
subdir-ccflags-y += -DCONFIG_BT_RFCOMM_TTY=1
subdir-ccflags-y += -DCONFIG_BT_BNEP_MODULE=1
subdir-ccflags-y += -DCONFIG_BT_BNEP_MC_FILTER=1
subdir-ccflags-y += -DCONFIG_BT_BNEP_PROTO_FILTER=1
subdir-ccflags-y += -DCONFIG_BT_HIDP_MODULE=1
subdir-ccflags-y += -DCONFIG_BT_LE_L2CAP_ECRED=1
EOF
    cat "$SOURCE_DIR/net/bluetooth/Makefile"
} > "$BTNET_DIR/Makefile"
make -C "$BUILD_DIR" M="$BTNET_DIR" \
    CONFIG_BT=m CONFIG_BT_BREDR=y CONFIG_BT_LE=y CONFIG_BT_HS=y CONFIG_BT_LEDS=y \
    CONFIG_BT_RFCOMM=m CONFIG_BT_RFCOMM_TTY=y CONFIG_BT_BNEP=m \
    CONFIG_BT_BNEP_MC_FILTER=y CONFIG_BT_BNEP_PROTO_FILTER=y CONFIG_BT_HIDP=m \
    CONFIG_BT_CMTP=n CONFIG_BT_LE_L2CAP_ECRED=y CONFIG_BT_DEBUGFS=n \
    CONFIG_BT_FEATURE_DEBUG=n CONFIG_BT_SELFTEST=n \
    modules
BTDRV_DIR="$WORKDIR/btdrv"
rm -rf "$BTDRV_DIR"
cp -a "$SOURCE_DIR/drivers/bluetooth" "$BTDRV_DIR"
# CRITICAL: drivers/bluetooth and net/bluetooth MUST see the same
# CONFIG_BT_* values for include/net/bluetooth/hci_core.h.
# CONFIG_BT_LEDS inserts hdev->power_led before open/close/setup/
# shutdown/send. If LEDs is on in bluetooth.ko but off in btintel.ko,
# btintel_configure_setup writes setup/shutdown into the wrong offsets
# and hci_power_on crashes in sk_skb_reason_drop (bare-metal 2026-08-03).
cat > "$BTDRV_DIR/Makefile" <<'EOF'
ccflags-y += -DCONFIG_BT_MODULE=1
ccflags-y += -DCONFIG_BT_BREDR=1
ccflags-y += -DCONFIG_BT_LE=1
ccflags-y += -DCONFIG_BT_HS=1
ccflags-y += -DCONFIG_BT_LEDS=1
ccflags-y += -DCONFIG_BT_LE_L2CAP_ECRED=1
ccflags-y += -DCONFIG_BT_HCIBTUSB_MODULE=1
# Helper libs: IS_ENABLED(CONFIG_BT_*) needs *_MODULE or builtin define
# or headers emit static inline stubs and *.c redefines the symbols.
ccflags-y += -DCONFIG_BT_BCM_MODULE=1
ccflags-y += -DCONFIG_BT_INTEL_MODULE=1
ccflags-y += -DCONFIG_BT_RTL_MODULE=1
ccflags-y += -DCONFIG_BT_MTK_MODULE=1
ccflags-y += -DCONFIG_BT_HCIBTUSB_BCM=1
ccflags-y += -DCONFIG_BT_HCIBTUSB_MTK=1
ccflags-y += -DCONFIG_BT_HCIBTUSB_RTL=1
ccflags-y += -DCONFIG_BT_HCIBTUSB_POLL_SYNC=1
ccflags-y += -I$(src)
obj-m += btusb.o btintel.o btrtl.o btbcm.o btmtk.o
EOF
make -C "$BUILD_DIR" M="$BTDRV_DIR" \
    KBUILD_EXTRA_SYMBOLS="$BTNET_DIR/Module.symvers" \
    CONFIG_BT=m CONFIG_BT_BREDR=y CONFIG_BT_LE=y CONFIG_BT_HS=y CONFIG_BT_LEDS=y \
    CONFIG_BT_LE_L2CAP_ECRED=y \
    CONFIG_BT_HCIBTUSB=m CONFIG_BT_INTEL=m CONFIG_BT_RTL=m CONFIG_BT_BCM=m CONFIG_BT_MTK=m \
    CONFIG_BT_HCIBTUSB_BCM=y CONFIG_BT_HCIBTUSB_MTK=y CONFIG_BT_HCIBTUSB_RTL=y \
    CONFIG_BT_HCIBTUSB_POLL_SYNC=y \
    modules
mapfile -t BT_MODULES < <(find "$BTNET_DIR" "$BTDRV_DIR" -name '*.ko' | sort)
test "${#BT_MODULES[@]}" -ge 6
check_vermagic "${BT_MODULES[@]}"
echo "=== stage bluetooth done ==="
fi

# --- uvcvideo (+ UVC_COMMON helper) ---
if run_stage uvc; then
echo "=== stage uvc ==="
UVC_DIR="$WORKDIR/uvc"
rm -rf "$UVC_DIR"
mkdir -p "$UVC_DIR"
cp -a "$SOURCE_DIR/drivers/media/usb/uvc/." "$UVC_DIR/"
# USB_VIDEO_CLASS selects UVC_COMMON (drivers/media/common/uvc.c).
cp "$SOURCE_DIR/drivers/media/common/uvc.c" "$UVC_DIR/uvc-common.c"
cat > "$UVC_DIR/Makefile" <<'EOF'
ccflags-y += -DCONFIG_USB_VIDEO_CLASS_MODULE=1
ccflags-y += -DCONFIG_UVC_COMMON_MODULE=1
obj-m += uvc.o
uvc-y := uvc-common.o
obj-m += uvcvideo.o
uvcvideo-y := uvc_driver.o uvc_queue.o uvc_v4l2.o uvc_video.o uvc_ctrl.o \
	uvc_status.o uvc_isight.o uvc_debugfs.o uvc_metadata.o uvc_entity.o
EOF
make -C "$BUILD_DIR" M="$UVC_DIR" \
    CONFIG_USB_VIDEO_CLASS=m CONFIG_UVC_COMMON=m CONFIG_MEDIA_CONTROLLER=y \
    modules
UVC_COMMON_MODULE="$UVC_DIR/uvc.ko"
UVC_MODULE="$UVC_DIR/uvcvideo.ko"
check_vermagic "$UVC_COMMON_MODULE" "$UVC_MODULE"
echo "=== stage uvc done ==="
fi

# --- thinkpad_acpi (+ ACPI battery + privacy-screen class) ---
if run_stage thinkpad; then
echo "=== stage thinkpad ==="
TP_DIR="$WORKDIR/thinkpad"
rm -rf "$TP_DIR"
mkdir -p "$TP_DIR/battery-build" "$TP_DIR/privacy-build" "$TP_DIR/tp-build"

# Stock AZL cloud kernel leaves ACPI_BATTERY and DRM_PRIVACY_SCREEN off.
# Ship both helpers next to thinkpad_acpi (generic names, not machine RPMs).
cp "$SOURCE_DIR/drivers/acpi/battery.c" "$TP_DIR/battery-build/"
cat > "$TP_DIR/battery-build/Makefile" <<'EOF'
obj-m += battery.o
EOF
make -C "$BUILD_DIR" M="$TP_DIR/battery-build" modules

cp "$SOURCE_DIR/drivers/gpu/drm/drm_privacy_screen.c" \
    "$TP_DIR/privacy-build/drm_privacy_screen.c"
# drm_class is not exported; use a module-local class instead.
python3 - "$TP_DIR/privacy-build/drm_privacy_screen.c" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('#include "drm_internal.h"\n', '')
marker = '#include <drm/drm_privacy_screen_driver.h>\n'
inject = marker + '\nstatic struct class *drm_privacy_screen_class;\n'
if marker not in text:
    raise SystemExit('include marker missing')
if 'static struct class *drm_privacy_screen_class' not in text:
    text = text.replace(marker, inject, 1)
old = "\tpriv->dev.class = drm_class;\n"
new = "\tpriv->dev.class = drm_privacy_screen_class;\n"
if old not in text:
    raise SystemExit("drm_class assignment not found")
text = text.replace(old, new, 1)
if 'drm_privacy_screen_init' not in text:
    text += """
static int __init drm_privacy_screen_init(void)
{
	drm_privacy_screen_class = class_create("drm_privacy_screen");
	return PTR_ERR_OR_ZERO(drm_privacy_screen_class);
}

static void __exit drm_privacy_screen_exit(void)
{
	if (!IS_ERR_OR_NULL(drm_privacy_screen_class))
		class_destroy(drm_privacy_screen_class);
}

module_init(drm_privacy_screen_init);
module_exit(drm_privacy_screen_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("DRM privacy-screen class (OOT helper)");
"""
path.write_text(text)
PY
cat > "$TP_DIR/privacy-build/Makefile" <<'EOF'
ccflags-y += -DCONFIG_DRM_PRIVACY_SCREEN_MODULE=1
obj-m += drm_privacy_screen.o
EOF
make -C "$BUILD_DIR" M="$TP_DIR/privacy-build" modules

cp "$SOURCE_DIR/drivers/platform/x86/lenovo/thinkpad_acpi.c" "$TP_DIR/tp-build/"
cp "$SOURCE_DIR/drivers/platform/x86/dual_accel_detect.h" "$TP_DIR/tp-build/"
sed -i 's|#include "../dual_accel_detect.h"|#include "dual_accel_detect.h"|' \
    "$TP_DIR/tp-build/thinkpad_acpi.c"
# No ALSA console mixer: stock AZL has no CONFIG_SND; sound is a sibling
# OOT package and may build in parallel without shared Module.symvers.
cat > "$TP_DIR/tp-build/Makefile" <<'EOF'
ccflags-y += -DCONFIG_THINKPAD_ACPI_MODULE=1
ccflags-y += -DCONFIG_THINKPAD_ACPI_VIDEO=1
ccflags-y += -DCONFIG_THINKPAD_ACPI_HOTKEY_POLL=1
ccflags-y += -DCONFIG_DRM_PRIVACY_SCREEN_MODULE=1
ccflags-y += -DCONFIG_ACPI_BATTERY_MODULE=1
obj-m += thinkpad_acpi.o
EOF
EXTRA_SYM=()
for sv in \
    "$TP_DIR/battery-build/Module.symvers" \
    "$TP_DIR/privacy-build/Module.symvers"
do
    [[ -f "$sv" ]] || continue
    EXTRA_SYM+=("$sv")
done
MAKE_EXTRA=()
if ((${#EXTRA_SYM[@]})); then
    MAKE_EXTRA=(KBUILD_EXTRA_SYMBOLS="${EXTRA_SYM[*]}")
fi
make -C "$BUILD_DIR" M="$TP_DIR/tp-build" \
    "${MAKE_EXTRA[@]}" \
    CONFIG_THINKPAD_ACPI=m \
    modules

cp -f "$TP_DIR/battery-build/battery.ko" "$TP_DIR/battery.ko"
cp -f "$TP_DIR/privacy-build/drm_privacy_screen.ko" "$TP_DIR/drm_privacy_screen.ko"
cp -f "$TP_DIR/tp-build/thinkpad_acpi.ko" "$TP_DIR/thinkpad_acpi.ko"
check_vermagic \
    "$TP_DIR/battery.ko" \
    "$TP_DIR/drm_privacy_screen.ko" \
    "$TP_DIR/thinkpad_acpi.ko"
echo "=== stage thinkpad done ==="
fi

# --- typec + ucsi ---
if run_stage typec; then
echo "=== stage typec ==="
TYPEC_DIR="$WORKDIR/typec"
rm -rf "$TYPEC_DIR"
cp -a "$SOURCE_DIR/drivers/usb/typec" "$TYPEC_DIR"
# Include UCSI debugfs + trace objects when the running kernel has those
# features (AZL does). Upstream gates them on CONFIG_DEBUG_FS/TRACING.
cat > "$TYPEC_DIR/Makefile" <<'EOF'
ccflags-y += -DCONFIG_TYPEC_MODULE=1
ccflags-y += -DCONFIG_TYPEC_UCSI_MODULE=1
ccflags-y += -DCONFIG_UCSI_ACPI_MODULE=1
ccflags-y += -DCONFIG_TYPEC_DP_ALTMODE_MODULE=1
ccflags-y += -DCONFIG_DEBUG_FS=1
ccflags-y += -DCONFIG_TRACING=1
ccflags-y += -I$(src)
ccflags-y += -I$(src)/ucsi
CFLAGS_ucsi/trace.o := -I$(src)/ucsi
obj-m += typec.o
typec-y := class.o mux.o retimer.o bus.o port-mapper.o pd.o
obj-m += typec_ucsi.o
typec_ucsi-y := ucsi/ucsi.o ucsi/psy.o ucsi/displayport.o ucsi/debugfs.o ucsi/trace.o
obj-m += ucsi_acpi.o
ucsi_acpi-y := ucsi/ucsi_acpi.o
EOF
make -C "$BUILD_DIR" M="$TYPEC_DIR" \
    CONFIG_TYPEC=m CONFIG_TYPEC_UCSI=m CONFIG_UCSI_ACPI=m \
    CONFIG_TYPEC_DP_ALTMODE=m CONFIG_DEBUG_FS=y CONFIG_TRACING=y \
    modules
TYPEC_MODULE="$TYPEC_DIR/typec.ko"
TYPEC_UCSI_MODULE="$TYPEC_DIR/typec_ucsi.ko"
UCSI_ACPI_MODULE="$TYPEC_DIR/ucsi_acpi.ko"
check_vermagic "$TYPEC_MODULE" "$TYPEC_UCSI_MODULE" "$UCSI_ACPI_MODULE"
echo "=== stage typec done ==="
fi

# --- package RPMs ---
# Adaptive: package whichever family modules are present in WORKDIR.
# Missing families are skipped so partial CI matrix success still publishes.
if ! run_stage package; then
    exit 0
fi
echo "=== stage package ==="

have_ko() {
    local p="$1"
    [[ -f "$p" ]]
}

# Resolve optional module paths.
HID_MODULE="$WORKDIR/usbhid/usbhid.ko"
PS2_MODULE="$WORKDIR/psmouse/psmouse.ko"
STOR_MODULE="$WORKDIR/usb-storage/usb-storage.ko"
UAS_MODULE="$WORKDIR/usb-storage/uas.ko"
IWL_MODULE="$WORKDIR/iwlwifi/iwlwifi.ko"
IWL_MVM="$WORKDIR/iwlwifi/mvm/iwlmvm.ko"
IWL_DVM="$WORKDIR/iwlwifi/dvm/iwldvm.ko"
IWL_MLD="$WORKDIR/iwlwifi/mld/iwlmld.ko"
UVC_COMMON_MODULE="$WORKDIR/uvc/uvc.ko"
UVC_MODULE="$WORKDIR/uvc/uvcvideo.ko"
TP_BATTERY_MODULE="$WORKDIR/thinkpad/battery.ko"
TP_PRIVACY_MODULE="$WORKDIR/thinkpad/drm_privacy_screen.ko"
TP_MODULE="$WORKDIR/thinkpad/thinkpad_acpi.ko"
TYPEC_MODULE="$WORKDIR/typec/typec.ko"
TYPEC_UCSI_MODULE="$WORKDIR/typec/typec_ucsi.ko"
UCSI_ACPI_MODULE="$WORKDIR/typec/ucsi_acpi.ko"

mapfile -t SOUND_MODULES < <(find "$WORKDIR/sound" -name '*.ko' 2>/dev/null | sort || true)
mapfile -t BT_MODULES < <(
    {
        find "$WORKDIR/btnet" -name '*.ko' 2>/dev/null || true
        find "$WORKDIR/btdrv" -name '*.ko' 2>/dev/null || true
    } | sort
)

PRESENT_PKGS=()
PRESENT_KOS=()

add_pkg() {
    local name="$1"
    PRESENT_PKGS+=("$name")
}

if have_ko "$HID_MODULE"; then
    PRESENT_KOS+=("$HID_MODULE")
    add_pkg usbhid
fi
if have_ko "$PS2_MODULE"; then
    PRESENT_KOS+=("$PS2_MODULE")
    add_pkg psmouse
fi
if have_ko "$STOR_MODULE" && have_ko "$UAS_MODULE"; then
    PRESENT_KOS+=("$STOR_MODULE" "$UAS_MODULE")
    add_pkg usb-storage
fi
if have_ko "$IWL_MODULE" && have_ko "$IWL_MVM" && have_ko "$IWL_DVM" && have_ko "$IWL_MLD"; then
    PRESENT_KOS+=("$IWL_MODULE" "$IWL_MVM" "$IWL_DVM" "$IWL_MLD")
    add_pkg iwlwifi
fi
if ((${#SOUND_MODULES[@]} >= 12)); then
    PRESENT_KOS+=("${SOUND_MODULES[@]}")
    add_pkg sound
fi
if ((${#BT_MODULES[@]} >= 6)); then
    PRESENT_KOS+=("${BT_MODULES[@]}")
    add_pkg bluetooth
fi
if have_ko "$UVC_COMMON_MODULE" && have_ko "$UVC_MODULE"; then
    PRESENT_KOS+=("$UVC_COMMON_MODULE" "$UVC_MODULE")
    add_pkg uvc
elif have_ko "$UVC_MODULE"; then
    # Older layout without separate common helper.
    PRESENT_KOS+=("$UVC_MODULE")
    add_pkg uvc
fi
if have_ko "$TP_MODULE" && have_ko "$TP_BATTERY_MODULE" && have_ko "$TP_PRIVACY_MODULE"; then
    PRESENT_KOS+=("$TP_BATTERY_MODULE" "$TP_PRIVACY_MODULE" "$TP_MODULE")
    add_pkg thinkpad
elif have_ko "$TP_MODULE"; then
    PRESENT_KOS+=("$TP_MODULE")
    add_pkg thinkpad
fi
if have_ko "$TYPEC_MODULE" && have_ko "$TYPEC_UCSI_MODULE" && have_ko "$UCSI_ACPI_MODULE"; then
    PRESENT_KOS+=("$TYPEC_MODULE" "$TYPEC_UCSI_MODULE" "$UCSI_ACPI_MODULE")
    add_pkg typec
fi

if ((${#PRESENT_PKGS[@]} == 0)); then
    echo "package: no family modules present in $WORKDIR" >&2
    exit 1
fi

echo "package: present families: ${PRESENT_PKGS[*]}"
check_vermagic "${PRESENT_KOS[@]}"

RPMBUILD="$WORKDIR/rpmbuild"
rm -rf "$RPMBUILD"
mkdir -p "$RPMBUILD"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
EXTRA_INSTALL_DIR="extra/azurelinux-desktop"

install_ko_source() {
    local src="$1"
    cp "$src" "$RPMBUILD/SOURCES/$(basename "$src")"
}

for m in "${PRESENT_KOS[@]}"; do
    install_ko_source "$m"
done

pkg_enabled() {
    local want="$1" p
    for p in "${PRESENT_PKGS[@]}"; do
        [[ "$p" == "$want" ]] && return 0
    done
    return 1
}

# Dynamic subpackage fragments.
REQUIRES_SIBLINGS=""
PACKAGE_SECTIONS=""
INSTALL_SECTION=""
FILES_SECTIONS=""
POST_SECTIONS=""

append_requires() {
    local rpmname="$1"
    REQUIRES_SIBLINGS+="Requires:       ${rpmname} = %{version}-%{release}"$'\n'
}

# helpers for multi-ko packages
ko_install_line() {
    local bn="$1"
    echo "install -Dpm 0644 %{_sourcedir}/${bn} %{buildroot}%{_usr}/lib/modules/${KVERREL}/${EXTRA_INSTALL_DIR}/${bn}"
}
ko_files_line() {
    local bn="$1"
    echo "%{_usr}/lib/modules/${KVERREL}/${EXTRA_INSTALL_DIR}/${bn}"
}

if pkg_enabled usbhid; then
    append_requires azurelinux-desktop-usbhid-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-usbhid-kmod
Summary:        USB HID transport module for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-usbhid-kmod
The usbhid module built for Azure Linux kernel ${KVERREL}.
"
    INSTALL_SECTION+="$(ko_install_line usbhid.ko)"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-usbhid.conf <<'DRACUT'
add_drivers+=\" usbhid \"
DRACUT"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-usbhid-kmod
$(ko_files_line usbhid.ko)
%config(noreplace) %{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-usbhid.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-usbhid-kmod
/usr/sbin/depmod -a ${KVERREL} || :
if [ -x /usr/bin/dracut ] && [ -e /boot/initramfs-${KVERREL}.img ]; then
  /usr/bin/dracut --force --kver ${KVERREL} || :
fi
%postun -n azurelinux-desktop-usbhid-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled psmouse; then
    append_requires azurelinux-desktop-psmouse-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-psmouse-kmod
Summary:        PS/2 mouse (psmouse) for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-psmouse-kmod
psmouse for Azure Linux kernel ${KVERREL}. Covers GNOME Boxes and other
hypervisors that default to a PS/2 mouse for unknown Linux guests.
"
    INSTALL_SECTION+="$(ko_install_line psmouse.ko)"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-psmouse.conf <<'DRACUT'
add_drivers+=\" psmouse \"
DRACUT"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-psmouse.conf <<'ML'
psmouse
ML"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-psmouse-kmod
$(ko_files_line psmouse.ko)
%config(noreplace) %{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-psmouse.conf
%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-psmouse.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-psmouse-kmod
/usr/sbin/depmod -a ${KVERREL} || :
if [ -x /usr/bin/dracut ] && [ -e /boot/initramfs-${KVERREL}.img ]; then
  /usr/bin/dracut --force --kver ${KVERREL} || :
fi
%postun -n azurelinux-desktop-psmouse-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled usb-storage; then
    append_requires azurelinux-desktop-usb-storage-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-usb-storage-kmod
Summary:        USB mass-storage modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-usb-storage-kmod
usb-storage and uas modules for Azure Linux kernel ${KVERREL}.
"
    INSTALL_SECTION+="$(ko_install_line usb-storage.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line uas.ko)"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-usb-storage.conf <<'DRACUT'
add_drivers+=\" usb-storage uas \"
DRACUT"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-usb-storage-kmod
$(ko_files_line usb-storage.ko)
$(ko_files_line uas.ko)
%config(noreplace) %{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-usb-storage.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-usb-storage-kmod
/usr/sbin/depmod -a ${KVERREL} || :
if [ -x /usr/bin/dracut ] && [ -e /boot/initramfs-${KVERREL}.img ]; then
  /usr/bin/dracut --force --kver ${KVERREL} || :
fi
%postun -n azurelinux-desktop-usb-storage-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled iwlwifi; then
    append_requires azurelinux-desktop-iwlwifi-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-iwlwifi-kmod
Summary:        Intel Wi-Fi modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-iwlwifi-kmod
iwlwifi family modules for Azure Linux kernel ${KVERREL}.
"
    for bn in iwlwifi.ko iwlmvm.ko iwldvm.ko iwlmld.ko; do
        INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
    done
    FILES_SECTIONS+="
%files -n azurelinux-desktop-iwlwifi-kmod
$(ko_files_line iwlwifi.ko)
$(ko_files_line iwlmvm.ko)
$(ko_files_line iwldvm.ko)
$(ko_files_line iwlmld.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-iwlwifi-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-iwlwifi-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled sound; then
    append_requires azurelinux-desktop-sound-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-sound-kmod
Summary:        ALSA HDA and USB audio modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-sound-kmod
ALSA core, Intel HDA, common codecs, and USB audio for ${KVERREL}.
Pair with intel-audio-firmware and alsa-ucm.
"
    SOUND_FILES=""
    for m in "${SOUND_MODULES[@]}"; do
        bn="$(basename "$m")"
        INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
        SOUND_FILES+="$(ko_files_line "$bn")"$'\n'
    done
    # Do not force-load snd-hda-intel at boot. On VMs without a working
# codec it returns Invalid argument and fails systemd-modules-load.
# Fedora's dist-alsa install rule also pulls snd-seq, which the AZL
# kernel does not ship. udev binds HDA when hardware is present.
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-sound.conf <<'ML'
# snd-hda-intel is loaded by udev when HDA audio hardware appears.
ML"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modprobe.d/azurelinux-desktop-alsa.conf <<'ML'
# Override Fedora dist-alsa.conf: AZL kernel has no snd-seq module.
# Keep snd-pcm loadable without failing the install hook.
install snd-pcm /sbin/modprobe --ignore-install snd-pcm \$CMDLINE_OPTS
ML"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-sound-kmod
${SOUND_FILES}%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-sound.conf
%config(noreplace) %{_sysconfdir}/modprobe.d/azurelinux-desktop-alsa.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-sound-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-sound-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled bluetooth; then
    append_requires azurelinux-desktop-bluetooth-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-bluetooth-kmod
Summary:        Bluetooth core and USB modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-bluetooth-kmod
Bluetooth core and USB controllers for ${KVERREL}. Pair with BlueZ
and Intel BT firmware (ibt-*).
"
    BT_FILES=""
    for m in "${BT_MODULES[@]}"; do
        bn="$(basename "$m")"
        INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
        BT_FILES+="$(ko_files_line "$bn")"$'\n'
    done
    # Do not force-load btusb at boot. On ThinkPads, early btusb races
    # thinkpad_acpi rfkill and HCI reset times out (no firmware load).
    # udev loads btusb from USB aliases when the controller appears.
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-bluetooth.conf <<'ML'
# btusb is loaded by udev when a Bluetooth controller appears.
ML"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modprobe.d/azurelinux-desktop-bluetooth.conf <<'ML'
# Prefer platform rfkill (thinkpad_acpi) before binding btusb when present.
softdep btusb pre: thinkpad_acpi
options btusb reset=1
options btusb enable_autosuspend=0
ML"$'\n'
    # USB authorize-cycle recover: BT device often enumerates before
    # thinkpad_acpi unblocks platform rfkill (HCI 0x0c03 timeout).
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    BT_RESET_SRC="$REPO_ROOT/assets/bluetooth/azurelinux-desktop-bt-usb-reset"
    BT_SVC_SRC="$REPO_ROOT/assets/systemd/azurelinux-desktop-bt-recover.service"
    BT_LATE_SRC="$REPO_ROOT/assets/systemd/azurelinux-desktop-bt-recover-late.service"
    if [[ -f "$BT_RESET_SRC" && -f "$BT_SVC_SRC" ]]; then
        install_ko_source "$BT_RESET_SRC"
        install_ko_source "$BT_SVC_SRC"
        INSTALL_SECTION+="install -Dpm 0755 %{_sourcedir}/azurelinux-desktop-bt-usb-reset %{buildroot}/usr/libexec/azurelinux-desktop-bt-usb-reset"$'\n'
        INSTALL_SECTION+="install -Dpm 0644 %{_sourcedir}/azurelinux-desktop-bt-recover.service %{buildroot}/usr/lib/systemd/system/azurelinux-desktop-bt-recover.service"$'\n'
        BT_RECOVER_FILES="/usr/libexec/azurelinux-desktop-bt-usb-reset
/usr/lib/systemd/system/azurelinux-desktop-bt-recover.service
"
        if [[ -f "$BT_LATE_SRC" ]]; then
            install_ko_source "$BT_LATE_SRC"
            INSTALL_SECTION+="install -Dpm 0644 %{_sourcedir}/azurelinux-desktop-bt-recover-late.service %{buildroot}/usr/lib/systemd/system/azurelinux-desktop-bt-recover-late.service"$'\n'
            BT_RECOVER_FILES+="/usr/lib/systemd/system/azurelinux-desktop-bt-recover-late.service
"
        fi
    else
        echo "warning: BT recover assets missing; shipping modules only" >&2
        BT_RECOVER_FILES=""
    fi
    FILES_SECTIONS+="
%files -n azurelinux-desktop-bluetooth-kmod
${BT_FILES}%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-bluetooth.conf
%config(noreplace) %{_sysconfdir}/modprobe.d/azurelinux-desktop-bluetooth.conf
${BT_RECOVER_FILES}"
    POST_SECTIONS+="
%post -n azurelinux-desktop-bluetooth-kmod
/usr/sbin/depmod -a ${KVERREL} || :
if [ -x /usr/libexec/azurelinux-desktop-bt-usb-reset ]; then
    /usr/bin/systemctl enable azurelinux-desktop-bt-recover.service 2>/dev/null || :
    /usr/bin/systemctl enable azurelinux-desktop-bt-recover-late.service 2>/dev/null || :
fi
%postun -n azurelinux-desktop-bluetooth-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled uvc; then
    append_requires azurelinux-desktop-uvc-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-uvc-kmod
Summary:        USB Video Class modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-uvc-kmod
uvc common helper and uvcvideo for Azure Linux kernel ${KVERREL}.
"
    UVC_FILES=""
    if have_ko "$UVC_COMMON_MODULE"; then
        INSTALL_SECTION+="$(ko_install_line uvc.ko)"$'\n'
        UVC_FILES+="$(ko_files_line uvc.ko)"$'\n'
    fi
    INSTALL_SECTION+="$(ko_install_line uvcvideo.ko)"$'\n'
    UVC_FILES+="$(ko_files_line uvcvideo.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-uvc-kmod
${UVC_FILES}"
    POST_SECTIONS+="
%post -n azurelinux-desktop-uvc-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-uvc-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled thinkpad; then
    append_requires azurelinux-desktop-thinkpad-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-thinkpad-kmod
Summary:        thinkpad_acpi and laptop power helpers for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-thinkpad-kmod
thinkpad_acpi plus ACPI battery and DRM privacy-screen class helpers
for Azure Linux kernel ${KVERREL}.
"
    TP_FILES=""
    for bn in battery.ko drm_privacy_screen.ko thinkpad_acpi.ko; do
        if [[ -f "$RPMBUILD/SOURCES/$bn" ]]; then
            INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
            TP_FILES+="$(ko_files_line "$bn")"$'\n'
        fi
    done
    # Do not force-load at boot: thinkpad_acpi returns -ENODEV off-machine
    # and fails systemd-modules-load. udev/ACPI loads it on match.
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-thinkpad.conf <<'ML'
# Loaded by udev/ACPI on matching hardware; do not force-load at boot.
ML"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-thinkpad-kmod
${TP_FILES}%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-thinkpad.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-thinkpad-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-thinkpad-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled typec; then
    append_requires azurelinux-desktop-typec-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-typec-kmod
Summary:        USB Type-C and UCSI modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-typec-kmod
typec, typec_ucsi, and ucsi_acpi for Azure Linux kernel ${KVERREL}.
"
    for bn in typec.ko typec_ucsi.ko ucsi_acpi.ko; do
        INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
    done
    FILES_SECTIONS+="
%files -n azurelinux-desktop-typec-kmod
$(ko_files_line typec.ko)
$(ko_files_line typec_ucsi.ko)
$(ko_files_line ucsi_acpi.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-typec-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-typec-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

FAMILY_LIST="${PRESENT_PKGS[*]}"

cat > "$RPMBUILD/SPECS/azurelinux-desktop-kmods.spec" <<EOF
Name:           azurelinux-desktop-policy
Version:        ${KERNEL_VERSION}
Release:        ${KERNEL_RELEASE}
Summary:        Exact Azure Linux kernel and desktop kmod update policy
License:        GPL-2.0-only
BuildArch:      ${KERNEL_ARCH}
Requires:       kernel-core-uname-r = ${KVERREL}
${REQUIRES_SIBLINGS}
%description
Keeps Azure Linux kernel updates paired with matching desktop modules
built in this set (${FAMILY_LIST}).
${PACKAGE_SECTIONS}
%install
${INSTALL_SECTION}
${POST_SECTIONS}
%files
${FILES_SECTIONS}
EOF

rpmbuild --define "_topdir $RPMBUILD" -bb \
    "$RPMBUILD/SPECS/azurelinux-desktop-kmods.spec"
find "$RPMBUILD/RPMS" -type f -name '*.rpm' -exec cp -v {} "$OUTPUT_DIR/" \;

# Record which families shipped for CI publish validation.
printf '%s\n' "${PRESENT_PKGS[@]}" > "$OUTPUT_DIR/present-families.txt"

echo "Built kmods for $KVERREL (families: ${FAMILY_LIST}):"
ls -la "$OUTPUT_DIR"/*.rpm
