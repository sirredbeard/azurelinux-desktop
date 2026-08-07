#!/usr/bin/env bash
# verify-release-features.sh
#
# Purpose: Mount live ISO / live qcow2 / installer ISO / installed qcow2
#   roots and check the 2026.08 feature set (kmods conf, performance,
#   appstream preseed, dark theme, intel media, emoji fonts, copilot
#   flatpak, plymouth theme/setup messaging). Not a full package audit.
# Usage:
#   ./scripts/verify-release-features.sh \
#     --live-iso PATH --live-qcow PATH --installer-iso PATH \
#     [--installed-qcow PATH] [--out DIR]
# CI: No. Local dogfood after Get-AzureLinuxDesktop.ps1.

set -euo pipefail

# Non-interactive sudo: prefer SUDO_ASKPASS, else sudo -n when cached.
if [[ -z "${SUDO_ASKPASS:-}" ]]; then
  for cand in /tmp/azl-askpass.sh "${HOME}/.local/bin/azl-askpass"; do
    if [[ -x "$cand" ]]; then
      export SUDO_ASKPASS="$cand"
      break
    fi
  done
fi
if [[ -n "${SUDO_ASKPASS:-}" ]]; then
  sudo() { command sudo -A "$@"; }
else
  sudo() { command sudo -n "$@"; }
fi

LIVE_ISO=""
LIVE_QCOW=""
INSTALLER_ISO=""
INSTALLED_QCOW=""
OUT="${HOME}/azl-work/feature-verify-$(date +%Y%m%d-%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live-iso) LIVE_ISO="$2"; shift 2 ;;
    --live-qcow) LIVE_QCOW="$2"; shift 2 ;;
    --installer-iso) INSTALLER_ISO="$2"; shift 2 ;;
    --installed-qcow) INSTALLED_QCOW="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"/{mnt,logs}
LOG="$OUT/feature-verify.log"
SUMMARY="$OUT/summary.txt"
: >"$LOG"
: >"$SUMMARY"

pass=0
fail=0
skip=0

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
sum() { printf '%s\n' "$*" | tee -a "$SUMMARY" | tee -a "$LOG"; }

check() {
  # check LABEL ROOT path [grep_pattern]
  local label="$1" root="$2" path="$3" pat="${4:-}"
  local full="$root$path"
  if ! sudo test -e "$full"; then
    sum "FAIL  [$label] missing $path"
    fail=$((fail + 1))
    return 1
  fi
  if [[ -n "$pat" ]]; then
    if ! sudo grep -qE "$pat" "$full" 2>/dev/null; then
      sum "FAIL  [$label] $path missing /$pat/"
      fail=$((fail + 1))
      return 1
    fi
  fi
  sum "PASS  [$label] $path${pat:+ (/$pat/)}"
  pass=$((pass + 1))
}

check_rpm() {
  local label="$1" root="$2" pkg="$3"
  if sudo rpm --root "$root" -q "$pkg" >/dev/null 2>&1; then
    local nev
    nev=$(sudo rpm --root "$root" -q "$pkg" 2>/dev/null | head -1)
    sum "PASS  [$label] rpm $nev"
    pass=$((pass + 1))
  else
    sum "FAIL  [$label] rpm missing $pkg"
    fail=$((fail + 1))
  fi
}

check_absent_rpm() {
  local label="$1" root="$2" pkg="$3"
  if sudo rpm --root "$root" -q "$pkg" >/dev/null 2>&1; then
    sum "FAIL  [$label] unwanted rpm present: $pkg"
    fail=$((fail + 1))
  else
    sum "PASS  [$label] rpm absent $pkg"
    pass=$((pass + 1))
  fi
}

MOUNTS=()
register_mount() { MOUNTS+=("$1"); }

cleanup() {
  set +e
  local m
  for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
    m="${MOUNTS[$i]}"
    mountpoint -q "$m" && sudo umount "$m"
  done
  if sudo lvs --noheadings anaconda_azurelinux-desktop/root >/dev/null 2>&1; then
    sudo vgchange -an anaconda_azurelinux-desktop >/dev/null 2>&1 || true
  fi
  for nbd in /dev/nbd0 /dev/nbd1; do
    sudo qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

mount_live_iso_root() {
  local iso="$1" tag="$2"
  local isom="$OUT/mnt/${tag}_iso"
  local sq="$OUT/mnt/${tag}_sq"
  local rootimg="$OUT/mnt/${tag}_rootimg"
  mkdir -p "$isom" "$sq" "$rootimg"
  sudo mount -o loop,ro "$iso" "$isom"
  register_mount "$isom"
  sudo mount -o loop,ro "$isom/LiveOS/squashfs.img" "$sq"
  register_mount "$sq"
  if sudo test -f "$sq/LiveOS/rootfs.img"; then
    sudo mount -o loop,ro "$sq/LiveOS/rootfs.img" "$rootimg"
    register_mount "$rootimg"
    echo "$rootimg"
  else
    echo "$sq"
  fi
}

mount_qcow_root() {
  local qcow="$1" tag="$2" nbd="${3:-/dev/nbd0}"
  local rootm="$OUT/mnt/${tag}_root"
  mkdir -p "$rootm"
  sudo modprobe nbd max_part=16 || true
  sudo qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true
  sudo qemu-nbd --read-only --connect="$nbd" "$qcow"
  sleep 2
  # Try LVM anaconda layout first (installed), then GPT partitions.
  # Live disk images use plain XFS on p2 (not LVM); installed may be LVM+ext4/xfs.
  if sudo pvscan --cache -aay >/dev/null 2>&1; then
    if sudo vgchange -ay anaconda_azurelinux-desktop >/dev/null 2>&1; then
      if sudo test -b /dev/anaconda_azurelinux-desktop/root; then
        if sudo mount -o ro,norecovery /dev/anaconda_azurelinux-desktop/root "$rootm" 2>/dev/null \
          || sudo mount -o ro /dev/anaconda_azurelinux-desktop/root "$rootm" 2>/dev/null; then
          register_mount "$rootm"
          echo "$rootm"
          return 0
        fi
      fi
    fi
  fi
  local part fstype
  for part in "${nbd}p3" "${nbd}p2" "${nbd}p4" "${nbd}p1"; do
    if sudo test -b "$part"; then
      fstype=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null || true)
      case "$fstype" in
        xfs)
          # ro,norecovery avoids log replay on dirty XFS
          if sudo mount -t xfs -o ro,norecovery "$part" "$rootm" 2>/dev/null \
            || sudo mount -t xfs -o ro "$part" "$rootm" 2>/dev/null; then
            if sudo test -d "$rootm/etc" && sudo test -d "$rootm/usr"; then
              register_mount "$rootm"
              echo "$rootm"
              return 0
            fi
            sudo umount "$rootm" 2>/dev/null || true
          fi
          ;;
        ext4|ext3)
          if sudo mount -t ext4 -o ro,noload "$part" "$rootm" 2>/dev/null \
            || sudo mount -o ro,noload "$part" "$rootm" 2>/dev/null; then
            if sudo test -d "$rootm/etc" && sudo test -d "$rootm/usr"; then
              register_mount "$rootm"
              echo "$rootm"
              return 0
            fi
            sudo umount "$rootm" 2>/dev/null || true
          fi
          ;;
        *)
          if sudo mount -o ro "$part" "$rootm" 2>/dev/null; then
            if sudo test -d "$rootm/etc" && sudo test -d "$rootm/usr"; then
              register_mount "$rootm"
              echo "$rootm"
              return 0
            fi
            sudo umount "$rootm" 2>/dev/null || true
          fi
          ;;
      esac
    fi
  done
  sum "FAIL  [$tag] could not mount root from $qcow"
  fail=$((fail + 1))
  echo ""
}

verify_root() {
  local label="$1" root="$2"
  [[ -n "$root" ]] || { sum "SKIP  [$label] no root"; skip=$((skip+1)); return; }
  log ""
  log "======== $label root=$root ========"

  # Installer runtime is Anaconda media, not the desktop target. Full polish
  # lands via %post on the installed system. Check offline payload + assets.
  if [[ "$label" == installer* ]]; then
    check "$label" "$root" /etc/systemd/journald.conf.d/50-azurelinux-desktop.conf 'SystemMaxUse|RuntimeMaxUse' || true
    check "$label" "$root" /etc/udev/rules.d/60-azurelinux-desktop-iosched.rules 'BFQ|bfq|rotational' || true
    check "$label" "$root" /usr/share/plymouth/themes/azurelinux/azurelinux.plymouth 'azurelinux|Script' || true
    check "$label" "$root" /etc/polkit-1/rules.d/10-azurelinux-desktop-flatpak.rules 'flatpak|org.freedesktop.Flatpak' || true
    check "$label" "$root" /root/azl-install.ks 'ASSETS=/root/assets|root/assets' || true
    check "$label" "$root" /opt/azl-desktop-assets/dconf/db/local.d/00-azl-desktop-defaults 'prefer-dark|color-scheme' || true
    check "$label" "$root" /opt/azl-desktop-assets/bin/azl-growroot '.' || true
    check "$label" "$root" /opt/azl-desktop-assets/bin/azl-link-intel-ihd '.' || true
    check "$label" "$root" /opt/azl-desktop-assets/environment.d/50-azurelinux-desktop-libva.conf 'LIBVA|dri-nonfree' || true
    check "$label" "$root" /opt/azl-desktop-assets/systemd/azl-growroot.service 'grow|xfs' || true
    check "$label" "$root" /opt/azl-desktop-assets/polkit-1/rules.d/10-azurelinux-desktop-flatpak.rules 'Flatpak|flatpak' || true
    if sudo test -d "$root/opt/azl-offline-repo"; then
      sum "PASS  [$label] offline repo present"
      pass=$((pass + 1))
      for pat in intel-media-driver google-noto-color-emoji azurelinux-desktop-performance-kmod azurelinux-desktop-bluetooth-kmod; do
        if sudo find "$root/opt/azl-offline-repo" -name "${pat}*" 2>/dev/null | grep -q .; then
          sum "PASS  [$label] offline rpm payload has $pat"
          pass=$((pass + 1))
        else
          sum "FAIL  [$label] offline rpm payload missing $pat"
          fail=$((fail + 1))
        fi
      done
    else
      sum "FAIL  [$label] /opt/azl-offline-repo missing"
      fail=$((fail + 1))
    fi
    if sudo test -d "$root/opt/azl-offline-extras/flatpak-system"       || sudo test -d "$root/opt/azl-offline-extras/flatpak"; then
      sum "PASS  [$label] staged flatpak extras present"
      pass=$((pass + 1))
    else
      sum "FAIL  [$label] staged flatpak extras missing"
      fail=$((fail + 1))
    fi
    # ks must stage /root/assets for chrooted post
    if sudo grep -qE 'cp -a .*/root/assets|ASSETS=/root/assets' "$root/root/azl-install.ks" 2>/dev/null; then
      sum "PASS  [$label] product ks stages /root/assets for chroot post"
      pass=$((pass + 1))
    else
      sum "FAIL  [$label] product ks missing /root/assets stage"
      fail=$((fail + 1))
    fi
    return 0
  fi

  # Performance / journal / iosched assets
  check "$label" "$root" /etc/systemd/journald.conf.d/50-azurelinux-desktop.conf 'SystemMaxUse|RuntimeMaxUse'
  check "$label" "$root" /etc/udev/rules.d/60-azurelinux-desktop-iosched.rules 'BFQ|bfq|rotational'
  check "$label" "$root" /etc/sysctl.d/99-azurelinux-desktop-performance.conf 'swappiness|tcp_congestion|bbr' || true
  check "$label" "$root" /etc/modules-load.d/azurelinux-desktop-performance.conf 'tcp_bbr|sch_fq' || true
  # Any desktop kmod package present is a good signal on live/installed.
  # rpm --root does not always expand shell-style globs in -qa args; filter.
  kmod_list=$(sudo rpm --root "$root" -qa 2>/dev/null | grep -E '^azurelinux-desktop-.*-kmod' || true)
  if [[ -n "$kmod_list" ]]; then
    printf '%s\n' "$kmod_list" | tee -a "$LOG" >/dev/null
    sum "PASS  [$label] desktop kmod RPMs present"
    pass=$((pass + 1))
  else
    # Installer runtime may not ship kmods until target install; live/qcow should
    if [[ "$label" == installer* ]]; then
      sum "SKIP  [$label] kmod RPMs (installer runtime may omit)"
      skip=$((skip + 1))
    else
      sum "FAIL  [$label] no azurelinux-desktop-*-kmod RPMs"
      fail=$((fail + 1))
    fi
  fi

  # Dark theme dconf (source file and/or compiled db)
  if sudo test -f "$root/etc/dconf/db/local.d/00-azl-desktop-defaults"; then
    check "$label" "$root" /etc/dconf/db/local.d/00-azl-desktop-defaults 'prefer-dark|color-scheme|picture-uri'
  elif sudo grep -RqsE 'prefer-dark|color-scheme' "$root/etc/dconf/db/local.d" 2>/dev/null \
    || sudo strings "$root/etc/dconf/db/local" 2>/dev/null | grep -qE 'prefer-dark|color-scheme'; then
    sum "PASS  [$label] dconf dark theme keys present (compiled or local.d)"
    pass=$((pass + 1))
  else
    sum "FAIL  [$label] dconf dark theme (prefer-dark) not found"
    fail=$((fail + 1))
  fi
  check "$label" "$root" /etc/dconf/profile/user 'user-db|system-db'
  if sudo test -s "$root/etc/dconf/db/local"; then
    sum "PASS  [$label] dconf db compiled (/etc/dconf/db/local)"
    pass=$((pass + 1))
  else
    sum "FAIL  [$label] dconf db missing/empty"
    fail=$((fail + 1))
  fi

  # Emoji fonts
  check_rpm "$label" "$root" google-noto-color-emoji-fonts || check_rpm "$label" "$root" 'google-noto-emoji-color-fonts' || true
  check_rpm "$label" "$root" default-fonts-core-emoji || true

  # Intel multimedia (not Fedora free libva-intel-media-driver)
  check_rpm "$label" "$root" intel-media-driver
  check_absent_rpm "$label" "$root" libva-intel-media-driver
  # iHD: require dri link or environment.d LIBVA path (Azure Linux libva)
  if sudo test -e "$root/usr/lib64/dri/iHD_drv_video.so" || sudo test -L "$root/usr/lib64/dri/iHD_drv_video.so"; then
    sum "PASS  [$label] iHD linked at /usr/lib64/dri/iHD_drv_video.so"
    pass=$((pass + 1))
  elif sudo test -e "$root/usr/lib64/dri-nonfree/iHD_drv_video.so"; then
    sum "FAIL  [$label] iHD only in dri-nonfree (missing dri link)"
    fail=$((fail + 1))
  else
    if sudo find "$root/usr" -name 'iHD_drv_video.so' 2>/dev/null | tee -a "$LOG" | grep -q .; then
      sum "PASS  [$label] iHD_drv_video.so found under /usr"
      pass=$((pass + 1))
    else
      sum "FAIL  [$label] iHD_drv_video.so not found"
      fail=$((fail + 1))
    fi
  fi
  check "$label" "$root" /etc/environment.d/50-azurelinux-desktop-libva.conf 'LIBVA_DRIVERS_PATH|dri-nonfree' || true

  # Plymouth theme
  check "$label" "$root" /usr/share/plymouth/themes/azurelinux/azurelinux.plymouth 'azurelinux|Script'
  check "$label" "$root" /usr/share/plymouth/themes/azurelinux/azurelinux.script '.'
  # Setup message / theme default
  if sudo test -f "$root/etc/plymouth/plymouthd.conf"; then
    check "$label" "$root" /etc/plymouth/plymouthd.conf 'Theme|azurelinux' || true
  fi
  if sudo grep -RqsE 'Azure Linux|azurelinux|Setting up|preparing' \
      "$root/usr/share/plymouth/themes/azurelinux" \
      "$root/etc/plymouth" 2>/dev/null; then
    sum "PASS  [$label] plymouth theme text/setup messaging present"
    pass=$((pass + 1))
  else
    sum "WARN  [$label] no obvious plymouth setup message string (check theme)"
    skip=$((skip + 1))
  fi

  # Flatpak appstream preseed + copilot
  if sudo test -e "$root/var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml" \
    || sudo test -e "$root/var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml.gz"; then
    sum "PASS  [$label] flathub appstream preseeded"
    pass=$((pass + 1))
  else
    sum "FAIL  [$label] flathub appstream missing"
    fail=$((fail + 1))
  fi
  if sudo test -d "$root/var/lib/flatpak/app/com.github.sirredbeard.copilot-desktop-gtk" \
    || sudo flatpak --installation=system --system list --app 2>/dev/null | grep -q copilot-desktop \
    || sudo test -d "$root/var/lib/flatpak/app/com.github.sirredbeard.copilot-desktop-gtk"; then
    sum "PASS  [$label] copilot-desktop-gtk flatpak app dir"
    pass=$((pass + 1))
  else
    # try ostree refs
    if sudo find "$root/var/lib/flatpak" -path '*copilot-desktop*' 2>/dev/null | head -5 | tee -a "$LOG" | grep -q .; then
      sum "PASS  [$label] copilot-desktop flatpak paths present"
      pass=$((pass + 1))
    else
      sum "FAIL  [$label] copilot-desktop flatpak missing"
      fail=$((fail + 1))
    fi
  fi
  # gpg-verify remote
  if sudo test -f "$root/var/lib/flatpak/repo/config"; then
    if sudo grep -A20 'copilot-desktop' "$root/var/lib/flatpak/repo/config" 2>/dev/null | grep -qi 'gpg-verify=true'; then
      sum "PASS  [$label] copilot remote gpg-verify=true"
      pass=$((pass + 1))
    else
      # remote may be named differently
      if sudo grep -qi 'gpg-verify=true' "$root/var/lib/flatpak/repo/config"; then
        sum "PASS  [$label] flatpak repo has gpg-verify=true"
        pass=$((pass + 1))
      else
        sum "FAIL  [$label] flatpak gpg-verify not true"
        fail=$((fail + 1))
      fi
    fi
  fi

  # tuned / irqbalance presence (performance package set)
  check_rpm "$label" "$root" tuned || true
  check_rpm "$label" "$root" plymouth || true

  # Appstream refresh helper (preseeded catalog + unit)
  check "$label" "$root" /usr/libexec/azl-flatpak-appstream-refresh '.' || \
    check "$label" "$root" /usr/local/libexec/azl-flatpak-appstream-refresh '.' || true
  check "$label" "$root" /usr/lib/systemd/system/azl-flatpak-appstream.service 'flatpak|appstream' || true
  check "$label" "$root" /etc/polkit-1/rules.d/10-azurelinux-desktop-flatpak.rules 'flatpak|org.freedesktop.Flatpak' || true

  # Growroot first-boot + plymouth display-message hook
  check "$label" "$root" /usr/lib/systemd/system/azl-growroot.service 'grow|xfs|disk' || true
  grow_bin=""
  for g in /usr/local/sbin/azl-growroot /usr/local/bin/azl-growroot \
           /usr/libexec/azl-growroot /usr/bin/azl-growroot; do
    if sudo test -x "$root$g"; then
      grow_bin="$g"
      break
    fi
  done
  if [[ -n "$grow_bin" ]]; then
    sum "PASS  [$label] azl-growroot helper present ($grow_bin)"
    pass=$((pass + 1))
    if sudo grep -qsE 'display-message|plymouth' "$root$grow_bin" \
      || sudo grep -qsE 'display-message|plymouth' "$root/usr/lib/systemd/system/azl-growroot.service"; then
      sum "PASS  [$label] growroot references plymouth display-message"
      pass=$((pass + 1))
    else
      sum "WARN  [$label] growroot present but no plymouth message reference"
      skip=$((skip + 1))
    fi
  else
    sum "FAIL  [$label] azl-growroot helper missing"
    fail=$((fail + 1))
  fi

  # Wallpaper assets for dark/light dconf URIs
  check "$label" "$root" /usr/share/backgrounds/azurelinux/adwaita-d.jpg '.' || true
  check "$label" "$root" /usr/share/backgrounds/azurelinux/adwaita-l.jpg '.' || true

  # Representative kmod family RPMs (live/installed)
  if [[ "$label" != installer* ]]; then
    for pkg in azurelinux-desktop-performance-kmod \
               azurelinux-desktop-bluetooth-kmod \
               azurelinux-desktop-storage-kmod \
               azurelinux-desktop-intel-kmod; do
      check_rpm "$label" "$root" "$pkg" || true
    done
  fi
}

# --- live ISO ---
if [[ -n "$LIVE_ISO" && -f "$LIVE_ISO" ]]; then
  r=$(mount_live_iso_root "$LIVE_ISO" liveiso)
  verify_root live-iso "$r"
else
  sum "SKIP  live-iso not provided"
  skip=$((skip + 1))
fi

# --- installer ISO (runtime payload) ---
if [[ -n "$INSTALLER_ISO" && -f "$INSTALLER_ISO" ]]; then
  r=$(mount_live_iso_root "$INSTALLER_ISO" instiso)
  verify_root installer-runtime "$r"
else
  sum "SKIP  installer-iso not provided"
  skip=$((skip + 1))
fi

# --- live qcow ---
if [[ -n "$LIVE_QCOW" && -f "$LIVE_QCOW" ]]; then
  r=$(mount_qcow_root "$LIVE_QCOW" liveqcow /dev/nbd0)
  verify_root live-qcow "$r"
else
  sum "SKIP  live-qcow not provided"
  skip=$((skip + 1))
fi

# --- installed qcow ---
if [[ -n "$INSTALLED_QCOW" && -f "$INSTALLED_QCOW" ]]; then
  r=$(mount_qcow_root "$INSTALLED_QCOW" installed /dev/nbd1)
  verify_root installed-qcow "$r"
else
  sum "SKIP  installed-qcow not provided"
  skip=$((skip + 1))
fi

log ""
sum "==== totals: PASS=$pass FAIL=$fail SKIP=$skip ===="
sum "log: $LOG"
[[ "$fail" -eq 0 ]]
