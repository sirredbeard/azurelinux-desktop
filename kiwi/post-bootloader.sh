#!/bin/bash
# post-bootloader.sh — UEFI bootloader setup (%post --nochroot script for kickstart)
# Runs in the installer environment (NOT chrooted into the target).
# Generates grub.cfg, copies EFI binaries to fallback path, fixes NVRAM.
set -x
SYSROOT=/mnt/sysroot

echo "=== Target mounts ==="
findmnt -R "$SYSROOT" 2>/dev/null || mount | grep sysroot

echo "=== fstab ==="
cat "$SYSROOT/etc/fstab" 2>/dev/null
echo "=== crypttab ==="
cat "$SYSROOT/etc/crypttab" 2>/dev/null

# --- Get partition UUIDs via blkid (direct device access) ---
BOOT_DEV=$(findmnt -n -o SOURCE "$SYSROOT/boot" 2>/dev/null)
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEV" 2>/dev/null)
ROOT_DEV=$(findmnt -n -o SOURCE "$SYSROOT" 2>/dev/null)
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null)

echo "Boot: dev=$BOOT_DEV uuid=$BOOT_UUID"
echo "Root: dev=$ROOT_DEV uuid=$ROOT_UUID"

# Fallback: parse fstab
if [ -z "$BOOT_UUID" ]; then
    BOOT_UUID=$(awk '$2 == "/boot" { sub(/^UUID=/, "", $1); print $1 }' "$SYSROOT/etc/fstab" 2>/dev/null)
fi
if [ -z "$ROOT_UUID" ]; then
    ROOT_UUID=$(awk '$2 == "/" { sub(/^UUID=/, "", $1); print $1 }' "$SYSROOT/etc/fstab" 2>/dev/null)
fi

# --- Find installed kernel and initramfs ---
KERNEL=$(ls "$SYSROOT"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls "$SYSROOT"/boot/initramfs-*.img 2>/dev/null | sort -V | tail -1)
KERNEL_NAME=$(basename "$KERNEL")
INITRD_NAME=$(basename "$INITRD")
echo "Kernel: $KERNEL_NAME  Initrd: $INITRD_NAME"

if [ -z "$BOOT_UUID" ] || [ -z "$ROOT_UUID" ]; then
    echo "!!! FATAL: Could not determine boot ($BOOT_UUID) or root ($ROOT_UUID) UUID"
    echo "!!! Bootloader setup SKIPPED — system may not boot"
    echo "=== blkid output ==="
    blkid 2>/dev/null
    echo "=== mount output ==="
    mount 2>/dev/null
    exit 0
fi

if [ -z "$KERNEL_NAME" ] || [ -z "$INITRD_NAME" ]; then
    echo "!!! FATAL: No kernel ($KERNEL_NAME) or initramfs ($INITRD_NAME) found in $SYSROOT/boot/"
    ls -la "$SYSROOT/boot/" 2>/dev/null
    exit 0
fi

# --- Detect LUKS encryption ---
LUKS_PARAMS=""
for luks_dev in $(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null); do
    LUKS_UUID=$(cryptsetup luksUUID "$luks_dev" 2>/dev/null) && {
        LUKS_PARAMS="rd.luks.uuid=luks-${LUKS_UUID}"
        echo "Detected LUKS device: $luks_dev UUID=$LUKS_UUID"
        break
    }
done

# --- Find or create EFI vendor directory ---
EFI_VENDOR=""
for d in "$SYSROOT/boot/efi/EFI/azurelinux" "$SYSROOT/boot/efi/EFI/fedora"; do
    [ -d "$d" ] && { EFI_VENDOR="$d"; break; }
done
[ -z "$EFI_VENDOR" ] && { EFI_VENDOR="$SYSROOT/boot/efi/EFI/azurelinux"; mkdir -p "$EFI_VENDOR"; }
EFI_VENDOR_NAME=$(basename "$EFI_VENDOR")
echo "EFI vendor dir: $EFI_VENDOR"
ls -la "$EFI_VENDOR/" 2>/dev/null

# When Fedora's shim/grub RPMs install to EFI/fedora/ but our NVRAM entry
# will point to EFI/azurelinux/, copy the binaries across so the boot
# entry resolves. This covers the Fedora-on-Azure-Linux package mix.
if [ "$EFI_VENDOR_NAME" = "azurelinux" ]; then
    FEDORA_EFI="$SYSROOT/boot/efi/EFI/fedora"
    for f in shimx64.efi shimaa64.efi shim.efi grubx64.efi grubaa64.efi mmx64.efi; do
        if [ ! -f "$EFI_VENDOR/$f" ] && [ -f "$FEDORA_EFI/$f" ]; then
            cp -v "$FEDORA_EFI/$f" "$EFI_VENDOR/$f"
        fi
    done
fi

# --- Install GRUB EFI modules next to grub.cfg ---
# Fedora's grubx64.efi sets prefix to ($boot)/grub2. insmod then looks
# under /boot/grub2/x86_64-efi/, not /usr/lib/grub/x86_64-efi/. Without
# this copy, efi_gop/gfxterm fail and GRUB stays in text mode (BdsDxe
# text + ASCII menu) even when grub.cfg asks for gfxterm.
GRUB_EFI_MOD_SRC=""
for d in "$SYSROOT/usr/lib/grub/x86_64-efi" "$SYSROOT/usr/lib/grub/arm64-efi"; do
    [ -d "$d" ] && { GRUB_EFI_MOD_SRC="$d"; break; }
done
if [ -n "$GRUB_EFI_MOD_SRC" ]; then
    GRUB_EFI_MOD_DST="$SYSROOT/boot/grub2/$(basename "$GRUB_EFI_MOD_SRC")"
    mkdir -p "$GRUB_EFI_MOD_DST"
    cp -a "$GRUB_EFI_MOD_SRC"/. "$GRUB_EFI_MOD_DST"/
    echo "Installed GRUB modules: $GRUB_EFI_MOD_SRC -> $GRUB_EFI_MOD_DST"
    ls "$GRUB_EFI_MOD_DST" | wc -l
else
    echo "WARNING: no GRUB EFI module dir under $SYSROOT/usr/lib/grub"
fi

# Keep /etc/default/grub aligned with the desktop boot path so a later
# grub2-mkconfig does not reintroduce serial console and text terminals.
mkdir -p "$SYSROOT/etc/default"
# Desktop install: no text GRUB menu on normal boots. Go straight to the
# Azure Linux Plymouth splash. Hold Shift (or spam Esc) during firmware
# handoff if you need the menu; rescue + UEFI entries stay in grub.cfg.
cat > "$SYSROOT/etc/default/grub" << 'DEFAULTGRUB'
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_DISTRIBUTOR="Azure Linux"
GRUB_DEFAULT=0
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="gfxterm"
GRUB_CMDLINE_LINUX="rhgb quiet"
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_OS_PROBER=true
GRUB_GFXPAYLOAD_LINUX=keep
DEFAULTGRUB

# --- Generate /boot/grub2/grub.cfg ---
# Desktop: never paint a text menu on normal boots. timeout=0 + hidden,
# gfxterm only (no serial/console terminal_output), and ignore recordfail
# so a prior crash cannot force a 30s menu. Rescue/UEFI stay in the file
# for firmware key holds; they are not shown automatically.
mkdir -p "$SYSROOT/boot/grub2"
cat > "$SYSROOT/boot/grub2/grub.cfg" << GRUBCFG
set default=0
set timeout=0
set timeout_style=hidden
load_env
unset recordfail
save_env recordfail
insmod efi_gop
insmod efi_uga
insmod all_video
set gfxmode=auto
set gfxpayload=keep
terminal_output gfxterm
clear
terminal_input console

menuentry "Azure Linux" {
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /${KERNEL_NAME} root=UUID=${ROOT_UUID} ${LUKS_PARAMS} rhgb quiet ro
    initrd /${INITRD_NAME}
}

menuentry "Azure Linux (rescue)" {
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /${KERNEL_NAME} root=UUID=${ROOT_UUID} ${LUKS_PARAMS} ro systemd.unit=rescue.target
    initrd /${INITRD_NAME}
}

menuentry "UEFI Firmware Settings" --id "uefi-firmware" {
    fwsetup
}
GRUBCFG
echo "--- /boot/grub2/grub.cfg ---"
cat "$SYSROOT/boot/grub2/grub.cfg"

# --- Detect architecture for EFI binary names ---
EFI_ARCH=$(uname -m)
case "$EFI_ARCH" in
    x86_64)  SHIM_EFI="shimx64.efi"; GRUB_EFI="grubx64.efi"; BOOT_EFI="BOOTX64.EFI" ;;
    aarch64) SHIM_EFI="shimaa64.efi"; GRUB_EFI="grubaa64.efi"; BOOT_EFI="BOOTAA64.EFI" ;;
esac

# --- Create EFI stub grub.cfg on every vendor path we ship ---
# Fedora's signed grubx64.efi / shim fallback often loads EFI/fedora/grub.cfg
# even when the NVRAM path or removable BOOTX64 path is azurelinux/BOOT.
# Anaconda leaves a package-time UUID there that does not match the final
# /boot filesystem, which drops the user at a bare "grub>" prompt.
write_efi_stub_cfg() {
    local dest="$1"
    [ -n "$BOOT_UUID" ] || return 0
    mkdir -p "$(dirname "$dest")"
    cat > "$dest" << STUBCFG
search --no-floppy --root-dev-only --fs-uuid --set=dev ${BOOT_UUID}
set prefix=(\$dev)/grub2
export \$prefix
configfile \$prefix/grub.cfg
STUBCFG
    echo "EFI stub: $dest -> boot UUID $BOOT_UUID"
}

if [ -n "$BOOT_UUID" ]; then
    write_efi_stub_cfg "$EFI_VENDOR/grub.cfg"
    write_efi_stub_cfg "$SYSROOT/boot/efi/EFI/BOOT/grub.cfg"
    # Keep Fedora path in lockstep when those RPMs are present.
    if [ -d "$SYSROOT/boot/efi/EFI/fedora" ] || [ -f "$SYSROOT/boot/efi/EFI/fedora/$GRUB_EFI" ]; then
        write_efi_stub_cfg "$SYSROOT/boot/efi/EFI/fedora/grub.cfg"
    fi
fi

# --- Copy EFI binaries + grub.cfg to fallback boot path ---
mkdir -p "$SYSROOT/boot/efi/EFI/BOOT"
if [ -f "$EFI_VENDOR/$SHIM_EFI" ]; then
    cp -vf "$EFI_VENDOR/$SHIM_EFI"   "$SYSROOT/boot/efi/EFI/BOOT/$BOOT_EFI"
    cp -vf "$EFI_VENDOR/$GRUB_EFI"   "$SYSROOT/boot/efi/EFI/BOOT/$GRUB_EFI"   2>/dev/null || true
    cp -vf "$EFI_VENDOR/grub.cfg"    "$SYSROOT/boot/efi/EFI/BOOT/grub.cfg"     2>/dev/null || true
elif [ -f "$EFI_VENDOR/$GRUB_EFI" ]; then
    cp -vf "$EFI_VENDOR/$GRUB_EFI"   "$SYSROOT/boot/efi/EFI/BOOT/$BOOT_EFI"
    cp -vf "$EFI_VENDOR/grub.cfg"    "$SYSROOT/boot/efi/EFI/BOOT/grub.cfg"     2>/dev/null || true
else
    echo "!!! WARNING: No EFI binaries found!"
    find "$SYSROOT/boot/efi" -type f -name "*.efi" 2>/dev/null
fi

echo "=== Final ESP contents ==="
ls -laR "$SYSROOT/boot/efi/" 2>/dev/null

# --- Fix UEFI NVRAM boot entry ---
ESP_DEV=$(findmnt -n -o SOURCE "$SYSROOT/boot/efi" 2>/dev/null)
if [ -n "$ESP_DEV" ]; then
    ESP_DISK=$(echo "$ESP_DEV" | sed 's/[0-9]*$//')
    ESP_PART=$(echo "$ESP_DEV" | grep -o '[0-9]*$')
    echo "ESP: dev=$ESP_DEV disk=$ESP_DISK part=$ESP_PART"

    echo "=== Current UEFI boot entries ==="
    efibootmgr 2>/dev/null
    for bootnum in $(efibootmgr 2>/dev/null | grep -i 'default\\\|anaconda\|fedora\|azurelinux' | sed 's/Boot\([0-9A-Fa-f]*\).*/\1/'); do
        echo "Removing stale entry Boot$bootnum"
        efibootmgr -b "$bootnum" -B 2>/dev/null || true
    done

    EFI_NVRAM_PATH="\\EFI\\${EFI_VENDOR_NAME}\\${SHIM_EFI}"
    efibootmgr -c -d "$ESP_DISK" -p "$ESP_PART" \
        -L "Azure Linux" -l "$EFI_NVRAM_PATH" 2>/dev/null && \
        echo "Created UEFI boot entry: Azure Linux -> $EFI_NVRAM_PATH" || \
        echo "WARNING: efibootmgr -c failed"

    echo "=== Updated UEFI boot entries ==="
    efibootmgr 2>/dev/null
else
    echo "WARNING: Could not find ESP mount — skipping NVRAM fix"
fi
