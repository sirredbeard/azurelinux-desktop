#!/bin/bash
# Azure Linux Desktop — bare-metal Bluetooth / audio / desktop diagnostics
#
# Run ON the installed Azure Linux Desktop system (nested install or real
# disk), ideally after you have tried:
#   1) Settings → Bluetooth toggle
#   2) Settings → Screen recorder (optional)
# then from a terminal (default shell may be pwsh):
#
#   bash ~/azl-bt-gather.sh
#   # or:
#   bash ~/bin/azl-bt-gather.sh
#
# Needs sudo for journals, modules, rfkill, and some sysfs. Password prompt
# is normal. Output lands in ~/azl-bt-gather-<timestamp>/ as text files
# plus a tarball you can copy back to the Fedora host.
#
# Designed for this project's mix: Azure Linux base + Fedora GNOME layer +
# out-of-tree desktop kmods. Safe to re-run; does not change system state
# except optional non-destructive bluetoothctl probes and one optional
# recover re-run (off by default).
#
# Env knobs:
#   AZL_GATHER_RERUN_RECOVER=1  — run bt-usb-reset once mid-gather
#   AZL_GATHER_OUT=DIR          — force output directory
#   AZL_GATHER_NO_SUDO=1        — skip sudo sections (incomplete)
# Read-mostly diagnostics. May prompt for sudo. Safe for collecting logs; does not reflash firmware.

set -u

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${AZL_GATHER_OUT:-$HOME/azl-bt-gather-$TS}"
mkdir -p "$OUT"
LOG="$OUT/00-run.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== azl-bt-gather $TS ==="
echo "hostname=$(hostname 2>/dev/null || true)"
echo "user=$(id -un) uid=$(id -u) groups=$(id -Gn 2>/dev/null || true)"
echo "pwd=$PWD out=$OUT"
echo "shell=$SHELL"
date -Is
echo

have() { command -v "$1" >/dev/null 2>&1; }

run() {
    local title="$1"; shift
    echo "----- $title -----"
    if "$@"; then
        :
    else
        echo "(exit $?)"
    fi
    echo
}

# sudo helper: use cached credentials when possible
SUDO=""
if [[ "${AZL_GATHER_NO_SUDO:-0}" != "1" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO=""
    elif have sudo; then
        if sudo -n true 2>/dev/null; then
            SUDO="sudo -n"
        else
            echo "Requesting sudo for privileged probes (journals, modules, rfkill)..."
            if sudo -v; then
                SUDO="sudo"
            else
                echo "WARN: sudo failed; privileged sections will be skipped"
                SUDO=""
            fi
        fi
    fi
fi

priv() {
    if [[ -n "$SUDO" ]]; then
        # shellcheck disable=SC2086
        $SUDO "$@"
    elif [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        echo "(skipped privileged: $*)"
        return 0
    fi
}

section() {
    local file="$1"; shift
    local title="$1"; shift
    {
        echo "=== $title ==="
        date -Is
        echo
        if "$@"; then
            :
        else
            echo "(section command exit $?)"
        fi
    } >"$OUT/$file" 2>&1 || true
    echo "wrote $file"
}

# Wedged HCI (0x0c03 timeout) makes bluetoothctl and some sysfs reads block
# forever. Always bound interactive BT tools and attribute cats.
timeout_run() {
    local secs="${1:-8}"
    shift
    if have timeout; then
        timeout --signal=TERM --kill-after=3 "$secs" "$@" 2>&1 || {
            local rc=$?
            if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
                echo "(timed out after ${secs}s: $*)"
            else
                echo "(exit $rc: $*)"
            fi
            return 0
        }
    else
        "$@" 2>&1 || true
    fi
}

safe_cat() {
    local path="$1"
    local secs="${2:-3}"
    [[ -e "$path" ]] || return 0
    if have timeout; then
        timeout --signal=TERM --kill-after=2 "$secs" cat "$path" 2>/dev/null || echo "(timed out reading $path)"
    else
        cat "$path" 2>/dev/null || true
    fi
}

# ---------------- identity / environment ----------------
section 01-uname.txt "uname / os-release" bash -c '
uname -a
echo
cat /etc/os-release 2>/dev/null || true
echo
cat /etc/azurelinux-release 2>/dev/null || true
echo
rpm -q azurelinux-release azurelinux-release-common 2>/dev/null || true
'

section 02-virt-or-metal.txt "virtualization vs bare metal" bash -c '
echo "systemd-detect-virt:"
systemd-detect-virt 2>/dev/null || echo unknown
echo
echo "DMI:"
cat /sys/class/dmi/id/sys_vendor 2>/dev/null; cat /sys/class/dmi/id/product_name 2>/dev/null
cat /sys/class/dmi/id/product_version 2>/dev/null
cat /sys/class/dmi/id/board_name 2>/dev/null
echo
echo "chassis:"
cat /sys/class/dmi/id/chassis_type 2>/dev/null || true
echo
if [[ -d /sys/firmware/qemu_fw_cfg ]]; then echo qemu_fw_cfg=yes; else echo qemu_fw_cfg=no; fi
if grep -q hypervisor /proc/cpuinfo 2>/dev/null; then echo hypervisor_flag=yes; else echo hypervisor_flag=no; fi
echo
echo "cmdline:"
cat /proc/cmdline
'

# ---------------- packages / origins ----------------
section 03-packages-bt-audio.txt "BT/audio/desktop packages + repo origin" bash -c '
# AZL rpmdb under /usr/lib/sysimage/rpm is often root-only (mode 600).
rpm_q() { sudo -n rpm -q "$@" 2>/dev/null || rpm -q "$@" 2>/dev/null; }
rpm_qi() { sudo -n rpm -qi "$@" 2>/dev/null || rpm -qi "$@" 2>/dev/null; }
pkgs="bluez bluez-libs bluez-obexd gnome-bluetooth gnome-bluetooth-libs
NetworkManager-bluetooth pipewire pipewire-libs pipewire-pulseaudio
pipewire-alsa wireplumber wireplumber-libs xdg-desktop-portal
xdg-desktop-portal-gnome xdg-desktop-portal-gtk gnome-shell mutter gdm
linux-firmware kernel kernel-core azurelinux-desktop-policy
azurelinux-desktop-bluetooth-kmod azurelinux-desktop-thinkpad-kmod
azurelinux-desktop-sound-kmod"
for p in $pkgs; do
  if rpm_q "$p" >/dev/null 2>&1; then
    echo "== $p =="
    rpm_q "$p"
    rpm_qi "$p" 2>/dev/null | grep -E "^(Name|Version|Release|Signature|From repo|Vendor|Build Date|Install Date|Packager|Source RPM)" || true
    if command -v dnf >/dev/null 2>&1; then
      sudo -n dnf -q repoquery --installed --qf "%{name}-%{version}-%{release}.%{arch} from %{reponame}" "$p" 2>/dev/null \
        || dnf -q repoquery --installed --qf "%{name}-%{version}-%{release}.%{arch} from %{reponame}" "$p" 2>/dev/null \
        || true
    fi
    echo
  else
    echo "== $p == NOT INSTALLED (or rpm db unreadable without sudo)"
    echo
  fi
done
'

section 04-kmod-rpms.txt "desktop kmod RPMs present" bash -c '
rpm_qa() { sudo -n rpm -qa "$@" 2>/dev/null || rpm -qa "$@" 2>/dev/null; }
rpm_qa "azurelinux-desktop-*" | sort
echo
rpm_qa "kernel*" | sort
'

# ---------------- modules / firmware ----------------
section 05-lsmod-bt.txt "loaded BT/platform modules" bash -c '
lsmod | head -1
lsmod | grep -iE "btusb|btintel|btrtl|btbcm|btmtk|bluetooth|bnep|rfcomm|thinkpad|cfg80211|mac80211|iwlwifi|snd_|pipewire" || true
echo
echo "--- /sys/module params ---"
for m in btusb btintel bluetooth thinkpad_acpi; do
  if [[ -d /sys/module/$m ]]; then
    echo "# $m"
    ls /sys/module/$m/parameters 2>/dev/null | while read -r p; do
      echo -n "  $p="; cat "/sys/module/$m/parameters/$p" 2>/dev/null; echo
    done
  else
    echo "# $m not loaded"
  fi
done
'

section 06-modinfo.txt "modinfo OOT vs path" bash -c '
KVER=$(uname -r)
echo "uname -r=$KVER"
echo
for m in btusb btintel bluetooth bnep rfcomm thinkpad_acpi; do
  echo "==== modinfo $m ===="
  modinfo "$m" 2>&1 | head -60 || true
  echo
done
echo "==== ko files under extra/azurelinux-desktop ===="
find "/lib/modules/$KVER/extra" "/usr/lib/modules/$KVER/extra" -type f 2>/dev/null | sort
echo
echo "==== vermagic sample ===="
for f in /lib/modules/$KVER/extra/azurelinux-desktop/*.ko /usr/lib/modules/$KVER/extra/azurelinux-desktop/*.ko; do
  [[ -f "$f" ]] || continue
  echo -n "$f: "
  modinfo -F vermagic "$f" 2>/dev/null || true
done
'

section 07-modprobe-conf.txt "modprobe and modules-load confs" bash -c '
echo "--- /etc/modprobe.d ---"
ls -la /etc/modprobe.d/ 2>/dev/null || true
for f in /etc/modprobe.d/*; do
  [[ -f "$f" ]] || continue
  echo "#### $f"
  cat "$f"
  echo
done
echo "--- /etc/modules-load.d ---"
ls -la /etc/modules-load.d/ 2>/dev/null || true
for f in /etc/modules-load.d/*; do
  [[ -f "$f" ]] || continue
  echo "#### $f"
  cat "$f"
  echo
done
echo "--- /usr/lib/modprobe.d (bt*) ---"
ls /usr/lib/modprobe.d/*bt* /usr/lib/modprobe.d/*blue* 2>/dev/null || true
'

section 08-firmware.txt "Intel BT firmware blobs" bash -c '
echo "--- ibt-11* ---"
ls -la /usr/lib/firmware/intel/ibt-11* 2>/dev/null || ls -la /lib/firmware/intel/ibt-11* 2>/dev/null || echo none
echo
echo "--- md5 ---"
md5sum /usr/lib/firmware/intel/ibt-11-5* 2>/dev/null || md5sum /lib/firmware/intel/ibt-11-5* 2>/dev/null || true
echo
echo "--- SELinux labels ---"
ls -laZ /usr/lib/firmware/intel/ibt-11-5* 2>/dev/null || ls -laZ /lib/firmware/intel/ibt-11-5* 2>/dev/null || true
echo
echo "--- other ibt (sample) ---"
ls /usr/lib/firmware/intel/ibt-*.sfi* 2>/dev/null | head -40 || true
'

# ---------------- USB / rfkill / HCI ----------------
section 09-usb.txt "USB topology and Intel BT device" bash -c '
if command -v lsusb >/dev/null 2>&1; then
  lsusb
  echo
  lsusb -t 2>/dev/null || true
  echo
  lsusb -d 8087: -v 2>/dev/null | head -120 || lsusb -v -d 8087:0a2b 2>/dev/null | head -120 || true
else
  echo "lsusb missing"
  echo "--- sysfs 8087 ---"
  for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" ]] || continue
    v=$(cat "$d/idVendor" 2>/dev/null || true)
    [[ "$v" == "8087" ]] || continue
    echo "$d vendor=$v product=$(cat "$d/idProduct" 2>/dev/null) class=$(cat "$d/bDeviceClass" 2>/dev/null)"
    ls -la "$d" 2>/dev/null | head -20
    for iface in "$d"/[0-9]*:[0-9]*; do
      [[ -e "$iface" ]] || continue
      echo "  iface $(basename "$iface") driver=$(basename "$(readlink -f "$iface/driver" 2>/dev/null)" 2>/dev/null)"
    done
  done
fi
echo
echo "--- power/control for 8087 ---"
for d in /sys/bus/usb/devices/*; do
  [[ -f "$d/idVendor" ]] || continue
  [[ "$(cat "$d/idVendor" 2>/dev/null)" == "8087" ]] || continue
  echo "$d authorized=$(cat "$d/authorized" 2>/dev/null) power=$(cat "$d/power/control" 2>/dev/null) autosuspend=$(cat "$d/power/autosuspend" 2>/dev/null)"
done
'

section 10-rfkill.txt "rfkill and thinkpad platform" bash -c '
if command -v rfkill >/dev/null 2>&1; then
  rfkill list all
  echo
  rfkill --output-all 2>/dev/null || true
else
  echo "rfkill CLI missing; sysfs:"
  for d in /sys/class/rfkill/rfkill*; do
    [[ -d "$d" ]] || continue
    echo "$d name=$(cat "$d/name" 2>/dev/null) type=$(cat "$d/type" 2>/dev/null) state=$(cat "$d/state" 2>/dev/null) soft=$(cat "$d/soft" 2>/dev/null) hard=$(cat "$d/hard" 2>/dev/null)"
  done
fi
echo
echo "--- thinkpad_acpi ---"
if [[ -d /sys/module/thinkpad_acpi ]]; then
  echo loaded=yes
  ls /sys/devices/platform/thinkpad_acpi 2>/dev/null | head
  find /sys -name "tpacpi*bluetooth*" 2>/dev/null | head
else
  echo loaded=no
  echo "(expected absent under pure QEMU; expected present on ThinkPad bare metal)"
fi
dmesg 2>/dev/null | grep -i thinkpad | tail -30 || true
'

section 11-hci-sysfs.txt "HCI sysfs and debug" bash -c '
safe_cat() {
  local path="$1"; local secs="${2:-3}"
  [[ -e "$path" ]] || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=2 "$secs" cat "$path" 2>/dev/null || echo "(timed out reading $path)"
  else
    cat "$path" 2>/dev/null || true
  fi
}
timeout_run() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=3 "$secs" "$@" 2>&1 || {
      local rc=$?
      if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then echo "(timed out after ${secs}s: $*)"; else echo "(exit $rc: $*)"; fi
      return 0
    }
  else
    "$@" 2>&1 || true
  fi
}
echo "--- /sys/class/bluetooth ---"
ls -la /sys/class/bluetooth 2>/dev/null || echo none
echo
for h in /sys/class/bluetooth/hci*; do
  [[ -e "$h" ]] || continue
  echo "#### $h -> $(readlink -f "$h" 2>/dev/null)"
  # address/name/manufacturer can block when HCI is wedged after 0x0c03 timeout
  for f in name address bus_type type power/control power/runtime_status dev_class manufacturer hci_version hci_revision; do
    [[ -e "$h/$f" ]] || continue
    echo -n "  $f="
    safe_cat "$h/$f" 3
    echo
  done
done
echo
echo "--- /sys/kernel/debug/bluetooth (may need root/debugfs) ---"
ls -la /sys/kernel/debug/bluetooth 2>/dev/null || echo "no debugfs bluetooth"
echo
echo "--- hciconfig ---"
timeout_run 5 hciconfig -a || echo "hciconfig unavailable"
echo
echo "--- btmgmt info ---"
timeout_run 5 btmgmt info || echo "btmgmt unavailable"
'

section 12-bluetoothctl.txt "bluetoothctl probes" bash -c '
timeout_run() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=3 "$secs" "$@" 2>&1 || {
      local rc=$?
      if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then echo "(timed out after ${secs}s: $*)"; else echo "(exit $rc: $*)"; fi
      return 0
    }
  else
    "$@" 2>&1 || true
  fi
}
if ! command -v bluetoothctl >/dev/null 2>&1; then
  echo "bluetoothctl missing"; exit 0
fi
# Non-interactive + short timeout: D-Bus to a half-dead adapter hangs forever.
echo "--- list ---"
timeout_run 8 bluetoothctl --timeout 5 list || true
echo
echo "--- show ---"
timeout_run 8 bluetoothctl --timeout 5 show || true
echo
echo "--- power on attempt ---"
timeout_run 10 bluetoothctl --timeout 8 power on || true
sleep 1
timeout_run 8 bluetoothctl --timeout 5 show || true
echo
echo "--- devices ---"
timeout_run 8 bluetoothctl --timeout 5 devices || true
'

# ---------------- systemd units ----------------
section 13-systemd-bt.txt "bluetooth and recover units" bash -c '
units="bluetooth.service azurelinux-desktop-bt-recover.service azurelinux-desktop-bt-recover-late.service azurelinux-desktop-bt-diag.service"
for u in $units; do
  echo "==== $u ===="
  systemctl status "$u" --no-pager -l 2>&1 | head -40 || true
  echo "is-enabled: $(systemctl is-enabled "$u" 2>&1 || true)"
  echo "is-active: $(systemctl is-active "$u" 2>&1 || true)"
  echo
done
echo "--- unit files ---"
for u in $units; do
  f=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null || true)
  echo "#### $u path=$f"
  [[ -n "$f" && -f "$f" ]] && cat "$f"
  echo
done
echo "--- helper script ---"
ls -la /usr/libexec/azurelinux-desktop-bt-usb-reset 2>/dev/null || true
head -80 /usr/libexec/azurelinux-desktop-bt-usb-reset 2>/dev/null || true
'

section 14-systemd-user-pipewire.txt "PipeWire user units (system + user)" bash -c '
echo "--- /etc/systemd/user wants ---"
ls -la /etc/systemd/user/sockets.target.wants/ 2>/dev/null || true
ls -la /etc/systemd/user/pipewire.service.wants/ 2>/dev/null || true
ls -la /etc/systemd/user/default.target.wants/ 2>/dev/null || true
ls -la /etc/systemd/user/graphical-session-pre.target.wants/ 2>/dev/null || true
echo
echo "--- presets ---"
ls -la /usr/lib/systemd/user-preset/ 2>/dev/null || true
for f in /usr/lib/systemd/user-preset/*; do
  [[ -f "$f" ]] || continue
  echo "#### $f"
  cat "$f"
  echo
done
echo "--- systemctl --user (may fail outside session) ---"
systemctl --user status pipewire.socket pipewire.service pipewire-pulse.socket wireplumber.service --no-pager -l 2>&1 | head -80 || true
echo
systemctl --user is-enabled pipewire.socket pipewire-pulse.socket wireplumber.service 2>&1 || true
echo
echo "--- runtime sockets ---"
ls -la "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/pipewire* 2>/dev/null || echo "no pipewire runtime sockets"
ls -la "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/pulse 2>/dev/null || true
'

# ---------------- journals (privileged) ----------------
section 15-journal-kernel-bt.txt "journal kernel BT (this boot)" bash -c '
if [[ -n "'"$SUDO"'" ]] || [[ "$(id -u)" -eq 0 ]]; then
  '"$SUDO"' journalctl -b -k --no-pager 2>/dev/null | grep -iE "bluetooth|btusb|btintel|hci0|8087|ibt-|thinkpad_acpi|rfkill|firmware_load|azl-bt" || true
else
  dmesg 2>/dev/null | grep -iE "bluetooth|btusb|btintel|hci0|8087|thinkpad|firmware" || true
fi
'

section 16-journal-units.txt "journal recover + bluetoothd + pipewire" bash -c '
if [[ -n "'"$SUDO"'" ]] || [[ "$(id -u)" -eq 0 ]]; then
  echo "==== azurelinux-desktop-bt-recover ===="
  '"$SUDO"' journalctl -b -u azurelinux-desktop-bt-recover.service --no-pager 2>/dev/null || true
  echo
  echo "==== azurelinux-desktop-bt-recover-late ===="
  '"$SUDO"' journalctl -b -u azurelinux-desktop-bt-recover-late.service --no-pager 2>/dev/null || true
  echo
  echo "==== bluetooth.service ===="
  '"$SUDO"' journalctl -b -u bluetooth.service --no-pager 2>/dev/null | tail -n 120 || true
  echo
  echo "==== user pipewire/wireplumber/portal/screencast (all users) ===="
  '"$SUDO"' journalctl -b --no-pager 2>/dev/null | grep -iE "pipewire|wireplumber|xdg-desktop-portal|Screencast|gnome-shell.*[Bb]lue" | tail -n 200 || true
else
  journalctl --user -b --no-pager 2>/dev/null | grep -iE "pipewire|wireplumber|portal|Screencast" | tail -n 80 || true
fi
'

section 17-journal-selinux.txt "SELinux / AVC related to firmware or bluetooth" bash -c '
echo "getenforce: $(getenforce 2>/dev/null || echo n/a)"
echo "selinux config:"; grep -E "^SELINUX" /etc/selinux/config 2>/dev/null || true
echo
if [[ -n "'"$SUDO"'" ]] || [[ "$(id -u)" -eq 0 ]]; then
  '"$SUDO"' journalctl -b --no-pager 2>/dev/null | grep -iE "avc:|firmware_load|bluetooth|btusb|denied" | tail -n 150 || true
  echo
  if command -v ausearch >/dev/null 2>&1; then
    '"$SUDO"' ausearch -m avc -ts boot 2>/dev/null | tail -n 80 || true
  fi
else
  echo "need sudo for full AVC"
fi
'

section 18-dmesg-full-bt-window.txt "dmesg full BT window" bash -c '
if [[ -n "'"$SUDO"'" ]] || [[ "$(id -u)" -eq 0 ]]; then
  '"$SUDO"' dmesg --ctime 2>/dev/null | grep -n -iE "usb|bluetooth|btusb|hci|thinkpad|firmware|8087" | head -n 400 || true
else
  dmesg --ctime 2>/dev/null | grep -n -iE "usb|bluetooth|btusb|hci|thinkpad|firmware|8087" | head -n 400 || true
fi
'

# ---------------- optional recover re-run ----------------
# Recover re-run can take 30s+ (stop bluetooth, unbind, USB reset).
# Do not combine with a tight outer timeout; Ctrl-C leaves btusb unloaded.
if [[ "${AZL_GATHER_RERUN_RECOVER:-0}" == "1" ]]; then
  section 19-recover-rerun.txt "optional recover re-run" bash -c '
  if [[ -x /usr/libexec/azurelinux-desktop-bt-usb-reset ]]; then
    echo "Running recover helper..."
    if [[ -n "'"$SUDO"'" ]] || [[ "$(id -u)" -eq 0 ]]; then
      '"$SUDO"' /usr/libexec/azurelinux-desktop-bt-usb-reset
      sleep 3
      echo "--- after ---"
      '"$SUDO"' dmesg -T 2>/dev/null | tail -n 40
      bluetoothctl show 2>&1 || true
      rfkill list 2>&1 || true
    else
      echo "need sudo"
    fi
  else
    echo "helper missing"
  fi
  '
else
  echo "(skip recover re-run; set AZL_GATHER_RERUN_RECOVER=1 to enable)" | tee "$OUT/19-recover-rerun.txt"
fi

# ---------------- GNOME / session quirks ----------------
section 20-gnome-session.txt "GNOME session / display / portals" bash -c '
echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-}"
echo "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-}"
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
echo "DISPLAY=${DISPLAY:-}"
echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"
echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}"
echo
echo "--- gsettings bluetooth (if schemas present) ---"
gsettings list-schemas 2>/dev/null | grep -i blue || true
gsettings get org.gnome.desktop.peripherals.bluetooth remember-devices 2>/dev/null || true
echo
echo "--- portal processes ---"
ps aux 2>/dev/null | grep -iE "xdg-desktop-portal|pipewire|wireplumber|bluetoothd|gsd-rfkill" | grep -v grep || true
echo
echo "--- gsd-rfkill / gnome-bluetooth ---"
systemctl --user status org.gnome.SettingsDaemon.Rfkill.service --no-pager 2>&1 | head -30 || true
'

section 21-nm-bluetooth.txt "NetworkManager bluetooth plugin" bash -c '
nmcli -f GENERAL,WIFI-PROPERTIES,BLUETOOTH general 2>/dev/null || true
echo
nmcli device status 2>/dev/null || true
echo
rpm -q NetworkManager-bluetooth 2>/dev/null || true
ls /usr/lib*/NetworkManager/*/libnm-device-plugin-bluetooth* 2>/dev/null || true
'

# ---------------- bluez filesystem ----------------
section 22-var-lib-bluetooth.txt "BlueZ state dir" bash -c '
ls -la /var/lib/bluetooth 2>/dev/null || echo "cannot list /var/lib/bluetooth"
if [[ -n "'"$SUDO"'" ]] || [[ "$(id -u)" -eq 0 ]]; then
  '"$SUDO"' ls -laR /var/lib/bluetooth 2>/dev/null | head -n 100 || true
fi
echo
ls -la /etc/bluetooth/ 2>/dev/null || true
for f in /etc/bluetooth/main.conf /etc/bluetooth/input.conf /etc/bluetooth/network.conf; do
  [[ -f "$f" ]] || continue
  echo "#### $f"
  cat "$f"
  echo
done
'

# ---------------- SELinux policy note for AZL ----------------
section 23-selinux-policy-notes.txt "SELinux policy bits for hybrid stack" bash -c '
echo "getenforce=$(getenforce 2>/dev/null || echo n/a)"
echo
echo "--- firmware contexts ---"
ls -laZ /usr/lib/firmware/intel 2>/dev/null | head -20 || true
echo
echo "--- module contexts ---"
ls -laZ /usr/lib/modules/$(uname -r)/extra/azurelinux-desktop 2>/dev/null | head -30 || true
echo
echo "--- bluetoothd context ---"
ps -eZ 2>/dev/null | grep -i bluetooth || true
echo
echo "Note: AZL has logged: Permission firmware_load in class system not defined in policy"
echo "That is a policy capability gap vs Fedora; capture AVCs above if any."
'

# ---------------- repo / hybrid priority canary ----------------
section 24-repos.txt "dnf repos and priority (AZL vs Fedora)" bash -c '
ls -la /etc/yum.repos.d/ 2>/dev/null || true
echo
for f in /etc/yum.repos.d/*.repo; do
  [[ -f "$f" ]] || continue
  echo "#### $f"
  # trim huge exclude lines
  sed "s/exclude=.*/exclude=<trimmed>/" "$f" | head -80
  echo
done
if command -v dnf >/dev/null 2>&1; then
  echo "--- dnf repolist ---"
  dnf -q repolist 2>/dev/null || true
fi
'

# ---------------- timeline summary ----------------
section 25-timeline-summary.txt "boot timeline synthesis" bash -c '
echo "Building approximate timeline from journal/dmesg (best effort)"
echo
if [[ -n "'"$SUDO"'" ]] || [[ "$(id -u)" -eq 0 ]]; then
  '"$SUDO"' journalctl -b -k -o short-precise --no-pager 2>/dev/null | grep -iE "thinkpad_acpi|btusb|Bluetooth|hci0|azl-bt|usb 1-|8087|rfkill" | head -n 120 || true
else
  dmesg -T 2>/dev/null | grep -iE "thinkpad|btusb|Bluetooth|hci0|usb|8087" | head -n 120 || true
fi
echo
echo "KEY QUESTIONS FOR ANALYSIS:"
echo "1. Did thinkpad_acpi unblock before first btusb bind? (bare metal only)"
echo "2. Did recover early/late run, and did HCI succeed after?"
echo "3. Did firmware revision line ever appear?"
echo "4. Any SELinux/AVC on firmware_load after HCI would have worked?"
echo "5. Are pipewire user sockets enabled and active in the graphical session?"
'

# ---------------- environment marker ----------------
section 99-meta.txt "gather meta" bash -c '
echo "script=azl-bt-gather.sh"
echo "version=2026-08-03"
echo "out='"$OUT"'"
echo "sudo_used=$([[ -n "'"$SUDO"'" ]] && echo yes || echo no)"
echo "rerun_recover='"${AZL_GATHER_RERUN_RECOVER:-0}"'"
echo "virt=$(systemd-detect-virt 2>/dev/null || echo unknown)"
uname -a
date -Is
'

# ---------------- pack ----------------
TAR="$HOME/azl-bt-gather-$TS.tar.gz"
# Prefer relative paths inside tarball
(
  cd "$(dirname "$OUT")"
  base="$(basename "$OUT")"
  if have tar; then
    tar -czf "$TAR" "$base" 2>/dev/null || tar -czf "$TAR" -C "$(dirname "$OUT")" "$base"
  fi
)
echo
echo "=== DONE ==="
echo "Directory: $OUT"
if [[ -f "$TAR" ]]; then
  ls -lh "$TAR"
  echo "Tarball:   $TAR"
  echo
  echo "Copy to Fedora host, e.g. from host after reboot:"
  echo "  # mount nested home, then:"
  echo "  cp /mnt/azl-home/azurelinux/azl-bt-gather-$TS.tar.gz ~/azl-work/"
fi
echo
echo "Optional second pass after toggling BT in Settings:"
echo "  AZL_GATHER_RERUN_RECOVER=1 bash ~/azl-bt-gather.sh"
echo
