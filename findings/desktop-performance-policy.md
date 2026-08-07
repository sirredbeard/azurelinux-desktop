# Desktop performance policy

**Status:** active.

Azure Linux is built for cloud and server. The stock kernel and defaults
are fine there and a bit sleepy on a GNOME laptop. This project keeps the
Azure kernel and adds desktop policy on top: a conf-only kmod RPM, Fedora
userspace packages, and a few small assets.

## What the stock kernel already gives us

On current Azure Linux x86_64 these are already true, so we do not rebuild
them:

* `CONFIG_ZRAM=m` (zstd backend available)
* `CONFIG_TCP_CONG_BBR=m`, `CONFIG_NET_SCH_FQ=m`
* `CONFIG_IOSCHED_BFQ=m` (available; used only for spinning disks)
* `CONFIG_LRU_GEN=y` + `CONFIG_LRU_GEN_ENABLED=y` (MGLRU on)
* `CONFIG_PSI=y`, `CONFIG_SCHED_CORE=y`
* transparent hugepages = madvise
* NVMe I/O scheduler default = `none` (correct; leave it)

Kernel rebuild territory (leave alone for now):

* `HZ=100` (Fedora desktop hosts often use 1000)
* `PREEMPT_VOLUNTARY` (not full / dynamic preempt)
* `NO_HZ_FULL=y` (harmless unless you pass `nohz_full=` on the cmdline)

## SELinux

Stay on `selinux --enforcing` and `SELINUXTYPE=targeted`. That is already
the practical middle ground: daemons confined, desktop users usually
`unconfined_u`. Do not switch to permissive or disabled for "performance."
Fix real AVCs when they show up.

## Conf-only RPM: azurelinux-desktop-performance-kmod

Built in `scripts/build-desktop-kmods.sh`.

modules-load (`/etc/modules-load.d/azurelinux-desktop-performance.conf`):

* `zram`
* `tcp_bbr`
* `sch_fq`
* `bfq` (only applied by udev on rotational disks)

sysctl (`/etc/sysctl.d/99-azurelinux-desktop-performance.conf`):

* `net.core.default_qdisc = fq`
* `net.ipv4.tcp_congestion_control = bbr`
* `kernel.sched_autogroup_enabled = 1` (Fedora tuned desktop idea)
* `vm.swappiness = 10` (tuned performance-style; this host is 10)
* `vm.vfs_cache_pressure = 75`
* mild 16M TCP rmem/wmem caps
* `kernel.split_lock_mitigate = 0` (avoid multi-ms split-lock stalls)
* `kernel.nmi_watchdog = 0` (free a PMC / a little idle power)

zram-generator (`/etc/systemd/zram-generator.conf`):

* `zram-size = min(ram, 8192)` (Fedora Workstation-style cap)
* `compression-algorithm = zstd`

Loading `zram` alone does not create swap. Images also install Fedora
`zram-generator`.

## Image assets (not the kmod RPM)

journald (`/etc/systemd/journald.conf.d/50-azurelinux-desktop.conf`):

* `SystemMaxUse=200M`
* `RuntimeMaxUse=64M`
* `SystemKeepFree=1G`

systemd's default is a percent of the filesystem (easy multi-GB journals).
`50M` is too small for crash and debug history on a machine we actually
debug. Nested restage scripts may use a larger local cap; product images
use 200M.

I/O udev (`/etc/udev/rules.d/60-azurelinux-desktop-iosched.rules`):

* rotational disks only: `bfq`
* NVMe left at `none` (do not force `mq-deadline` on NVMe)
* no `elevator=` kernel cmdline

## Fedora packages on live ISO and installer target

Not on the canary container. Canary only cares that policy resolves the
performance kmod name.

* `zram-generator`
* `tuned` + `tuned-ppd` (GNOME Settings power profiles; not
  `power-profiles-daemon`)
* `irqbalance`
* `thermald`

`%post` enables irqbalance, tuned, thermald and runs
`tuned-adm profile desktop` (falls back to `balanced`).

## Azure guest agent

`WALinuxAgent` / `walinuxagent` is not in the desktop package set (live
list confirmed). `%post` still disables and masks `walinuxagent` /
`waagent` if something pulls them in later. Hyper-V daemons stay: they
are intentional guest agents and udev-gate off bare metal.

## Deliberately not set

* `SELINUX=permissive` or disabled
* `vm.swappiness = 0`
* `vm.dirty_ratio` / `vm.dirty_background_ratio` games
* old `kernel.sched_latency_ns` family
* `vm.lru_gen*` sysctls (MGLRU already on)
* forcing BFQ or mq-deadline on NVMe
* disabling transparent hugepages
* CPU governor locked to `performance`
* TLP or dual power-profile stacks
* masking hyperv-daemons (ship-all guest agent policy)

## Where it is wired

* `scripts/build-desktop-kmods.sh` (performance stage + RPM)
* `assets/systemd/journald.conf.d/50-azurelinux-desktop.conf`
* `assets/udev/60-azurelinux-desktop-iosched.rules`
* live: `kickstart/azurelinux-desktop-live.ks`
* installer: `kiwi/config.sh`, `kiwi/post-install.sh`
* canary: policy package name only

## Related

* `out-of-tree-usb-kmods-pages.md` (conf-only kmod packaging)
* `desktop-kmod-packages-breakdown.md`
* host check: Fedora tuned profiles, `/usr/lib/udev/rules.d/60-block-scheduler.rules`

## Research basis

Portable userspace policy only. No custom kernel rebuild.

Fedora (this host + packages):

* tuned `desktop` = `balanced` + `kernel.sched_autogroup_enabled=1`
* tuned-ppd replaces power-profiles-daemon for GNOME Settings
* zram-generator-defaults: `zram-size = min(ram, 8192)`
* irqbalance enabled on Workstation-class hosts
* NVMe scheduler default `none`; Fedora udev may set BFQ on some block
  devices — we only force BFQ when `rotational==1`
* host rawhide sample: swappiness 10, THP madvise, fq_codel/cubic until
  our conf loads BBR+fq

Common desktop kernel policy (userspace translation of well-known
desktop-oriented Kconfig choices; not a source import):

* BBR as congestion control when the module exists
* pair BBR with `fq`
* MGLRU on (already true on Azure Linux)
* mild 16M TCP socket caps
* do not ship removed CFS `sched_*_ns` knobs
* do not force performance CPU governor as the image default

Azure Linux stock:

* cloud-leaning HZ/preempt; leave alone
* WALinuxAgent not in the desktop package set; mask if present
* hyperv-daemons stay (ship-all guest agents)

Rejected after review:

* SELinux permissive
* journald 50M only (too small for debug history)
* dirty_ratio tweaks
* swappiness 0
* mq-deadline forced on NVMe
* dual tuned + power-profiles-daemon stacks

