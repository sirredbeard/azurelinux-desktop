# Ventuno Q hardware enablement for an ARM image: scope and gap analysis

**Status:** merged to main as a preview. PR #42 landed on main on 2026-11-10 (squash commit 65d7f31), on top of the Fedora 45 rebase. The work this document scopes is in the image: the firmware family, the sound module pipeline, the compiled device tree, and the FastRPC, dma-buf heap, and QRTR repacks, plus the ALSA UCM configuration package. The ARM image passed a systemd-nspawn boot test, graphical session up, the image's own DSP services running against the board's real DSPs. The live-boot census on the board itself has not run yet, and the three decisions flagged in this document (the camera exception, device tree delivery, and the policy package shape) are still open. The analysis below is the original scoping document, written 2026-11-09 from a live inspection of the board and a line by line read of the Azure Linux 4 kernel configs, and it stays as written.

The short version

An ARM Azure Linux desktop image is closer than the README implies, and the distance is concentrated in a handful of places.

Most of the SoC is already switched on in the stock Azure Linux 4 aarch64 kernel config: clocks, pinctrl, interconnect, PCIe, the MSM display stack, Ethernet, USB, UFS, eMMC, the remoteprocs, FastRPC, QRTR. The board device tree is not in the Azure kernel tree (it landed in mainline on 2026-03-13, after 6.18 branched, so that work is a backport, not a port). And three subsystem switches are off on aarch64 exactly as they are on x86_64: `CONFIG_WLAN`, `CONFIG_BT`, and `CONFIG_SOUND`. Those three switches kill Wi-Fi, Bluetooth, and all audio on this board.

So the work breaks into: (1) a board device tree, (2) three out of tree subsystem builds in the pattern this repo already uses on x86_64, (3) a small UVC build that carries over unchanged, (4) userspace packaging for FastRPC and the audio topologies, which no Azure or Fedora package supplies today, and (5) a boot test that proves which of the 'already on' drivers actually bind to the Monza device tree. Nothing on that list needs a kernel rebuild. The standing rule holds on ARM too: do not rebuild the Azure kernel, supplement it.

The one hard rule for everything below: no function that works on the Ubuntu stack on this board gets lost in the move. The checklist at the end is the sign-off. An ARM image is not supported until every line on it passes.

## The device, as measured

Board: Arduino Ventuno Q, hostname ventunoq. Running device tree model is `Qualcomm Technologies, Inc. Monaco Monza addons`, compatible `arduino,monza`, `qcom,monaco-monza`, `qcom,qcs8300`. SoC is QCS8275 (`/sys/devices/soc0/machine`), soc_id 675, Snapdragon family. Monaco is the QCS8300 family name, and the Azure kernel tree treats QCS8300 and SA8775P as siblings (Lemans), which matters for clocks below.

CPU: 4x Cortex-A78C at up to 2361.6 MHz plus 4x Cortex-A55 at up to 1958.4 MHz. RAM: 15,651,816 kB. No swap.

Boot storage is the 59.3 GiB eMMC (`mmcblk0`, type MMC). The eMMC carries a Qualcomm GPT with 71 partitions: the XBL/ABL/firmware A/B set, `system-boot` (p69, FAT32, 512 MiB, mounted at /boot/efi), `persist` (p70, 30 MiB), and `writable` (p71, ext4) as /. The desktop installer must never rewrite that partition table wholesale. A second disk, a 512 GB NVMe (MAXIO MAP1602, PCI `1e4b:1602`) on the second PCIe root port, is /data on this unit and is user added, not part of the board.

PCIe: two Qualcomm root ports (`17cb:0115`), a Pericom switch (`12d8:b304`) under the first, and three endpoints that matter: the QCNFA765 Wi-Fi card (`17cb:1103`), a TI TUSB73x0 xHCI (`104c:8241`), and the NVMe on the second root port.

Everything else is on the SoC or on the Arduino microcontroller:

* GPU: Adreno 623 (`qcom,adreno-623.0`, GMU `qcom,adreno-gmu-623.0`). Display controller is `qcom,qcs8300-dpu`, connectors DP-1, HDMI-A-1, Writeback-1. An ADV7511 bridge sits on the HDMI path. LVDS-1 exists in the tree and is disabled on purpose (see boot notes).
* Video: Iris VPU, `/dev/video32` and `/dev/video33` under `msm_vidc`. Camera: CAMSS plus a downstream camera stack (the running tree names `qcom,cam-cpas`, `qcom,cam-isp`, `qcom,cam-req-mgr`, `qcom,csid692`, `qcom,csiphy`).
* Audio: LPASS through the ADSP. ALSA card `monaco-gertrude`, MultiMedia1 playback, MultiMedia2 capture, MultiMedia3 playback, MAX98090 codec on the board plus HDMI codec.
* Remoteprocs, all running: `3000000.remoteproc` (ADSP, `qcom/qcs8300/adsp.mbn`), `26300000.remoteproc` (CDSP, `qcom/qcs8300/cdsp0.mbn`), `20c00000.remoteproc` (GPDSP, `qcom/qcs8300/gpdsp0.mbn`). FastRPC nodes `/dev/fastrpc-adsp-secure`, `/dev/fastrpc-cdsp`, `/dev/fastrpc-cdsp-secure`, `/dev/fastrpc-gdsp0`, `/dev/fastrpc-gdsp0-secure`.
* Wi-Fi: QCNFA765 is the WCN6855 combo part, PCIe for Wi-Fi (`wlp3s0`), UART for Bluetooth (`hci0`, HCI 5.3). One chip, two transports, two separate driver gaps below.
* Ethernet: `end0`, `qcom,qcs8300-ethqos` (dwmac), QCA808x PHY, 10/100/1000/2500 link modes. No carrier at inspection time, the port is unused on this unit, but the driver binds.
* USB: two DWC3 controllers on the SoC (one runs the gadget: `ttyGS0`, FunctionFS) plus the TI xHCI for host ports. USB-C power delivery is a Cypress CYPD6129 at I2C `12-0008`, driven by `typec_ucsi` plus `ucsi_ccg`, and it registers a UCSI power supply.
* The Arduino side: a USB device (`1209:ca01`) from the microcontroller presents three CAN interfaces through `gs_usb` (`can0`, `can1`, `can2`) plus CDC ACM (`ttyACM0`). The router service talks to the microcontroller on `ttySTM0` at 115200 baud. 48 thermal zones report through TSENS.
* Firmware update: fwupd sees the system firmware as an ESRT device, updated via capsule on disk, vendor string `arduino`. Secure Boot is disabled and the platform is in Setup Mode. Project modules are not signed by the Azure key, same constraint as x86_64, no worse here.

## Method

Board side, 2026-11-09, on the running system: `uname -a`, `lscpu`, `lsmod`, `lspci -nnk`, `lsusb`, `lsblk`, `/proc/device-tree` and `/sys/firmware/devicetree`, `/proc/cmdline`, `/boot/config-6.8.0-1089-qcom`, `dpkg -l` filtered for qcom/arduino/firmware, `/etc/apt/sources.list.d`, `/lib/firmware` census, `systemctl` unit lists, and the file lists of the four Arduino packages (`dpkg -L`).

Azure side: `base/comps/kernel/6.18-aarch64-azl.config` and `6.18-x86_64-azl.config` from `microsoft/azurelinux` branch `4.0`, read 2026-11-09 (14,105 lines and 11,032 `CONFIG_` lines on aarch64, against 8,691 lines and 5,651 on x86_64), plus the qcom Makefile in `microsoft/CBL-Mariner-Linux-Kernel` at `rolling-lts/azl4/6.18.31.1`, the kernel source the shipped desktop kernel `6.18.31-1.16.azl4` is built from.

A second pass the same day pulled three comparison sources: the package manifest of Canonical's IQ-8275 EVK desktop image (build x15, 20260925), the `qcom-deb-images` debos recipes and kernel config fragments from `github.com/qualcomm-linux/qcom-deb-images`, and the qcom DTS Makefiles from `torvalds/linux` master and `qualcomm-linux/kernel` branch `qcom-next`. Those feed the cross-image check section below: manifests, recipes, and file lists only, nothing flashed and nothing booted.

One caveat on version skew, stated once: the config files at the `4.0` branch head track the newest 6.18 (the branch `kernel.comp.toml` already lists `kernel-6.18.57.1.tar.gz`), while the desktop images ship 6.18.31. The three off switches are present in both arch files at head and match every x86_64 finding this repo has recorded against 6.18.31, so I treat the subsystem conclusions as settled. Before any kmod stage is written, re-diff against the exact target EVR's shipped config, the same discipline `scripts/build-desktop-kmods.sh` already documents.

## What works on Ubuntu, layer by layer

The board runs Ubuntu 24.04.5 LTS on Canonical's IoT kernel: `linux-image-qcom` `6.8.0-1089.94` (a second kernel, 6.8.0-1084, is also installed). That kernel is the reference. It is two years behind the Azure kernel on version and ahead of it on this one board, because it carries the Monza board file and the combo of drivers this SoC needs, all switched on at once: `/boot/config-6.8.0-1089-qcom` has the QCOM platform, `DRM_MSM`, `ATH11K`, the Q6 audio stack, and the remoteproc/FastRPC chain as modules or built in, with none of the three master switches off.

Board file: the kernel package ships `monaco-monza.dtb` (216,962 bytes), `monaco-addons-monza.dtb` (275,713 bytes), `monaco-addons-monza-ovl.dtb`, and `monaco-monza-precision-hat.dtbo` under `/usr/lib/firmware/6.8.0-1089-qcom/device-tree/qcom/`. Two hat overlays ship in the Arduino config package instead: `monaco-addons-iqaudio-codeczero-monza.dtbo` (IQAudio Codec Zero) and `monaco-monza-automation-hat.dtbo`, under `/var/lib/arduino-linux-config/overlays/`. Neither hat is enabled on this unit (`arduino-linux-config hw show` reports both disabled).

The running device tree does not come from grub. There is no `devicetree` line in `/boot/grub/grub.cfg` and no .dtb in /boot. Firmware hands the kernel its tree, and `arduino-linux-config` (0.3.0, in `arduino-linux-config`) rewrites that hand-off when the carrier/hat selection changes. `arduino-ventunoq-config` (0.4.1) installs `/etc/kernel/postinst.d/zzza-apply-dtb-configuration`, which runs `arduino-linux-config hw reload` after every kernel install so the selection survives a kernel update. Any ARM image that wants hats to keep working needs an equivalent of that hook. A one time .dtb drop is not equivalent.

Boot chain: UEFI (BOOTAA64.EFI, `shimaa64.efi`, `grubaa64.efi` in `/boot/efi/EFI/ubuntu`), grub with `/etc/default/grub.d/99-dragonwing-defaults.cfg` (serial console `console=ttyMSM0,115200n8`, `pcie_pme=nomsi`, `earlycon`, console terminal, 3 second menu) and `99-dragonwing-disable-lvds.cfg` (`video=LVDS-1:d`, because the panel reports connected when absent and gdm would land on a screen that is not there). Running cmdline: `BOOT_IMAGE=/boot/vmlinuz-6.8.0-1089-qcom root=UUID=... ro console=ttyMSM0,115200n8 pcie_pme=nomsi earlycon video=LVDS-1:d`. The Azure aarch64 kernel keeps `CONFIG_SERIAL_QCOM_GENI=y` and its console variant built in, so this console path survives the move. The two grub.d files are small and should carry over as assets.

Firmware packages: Ubuntu splits `linux-firmware` and the Qualcomm parts do not come from the split. `linux-firmware-dragonwing` `20260825` comes from the `ubuntu-qcom-iot` PPA (`ppa.launchpadcontent.net/ubuntu-qcom-iot/qcom-ppa`, noble) and carries the Dragonwing set. On disk: `/lib/firmware/qcom` is 64 MiB (including `qcom/qcs8300` and `qcom/qcs8275`), `/lib/firmware/ath11k` is 25 MiB (the WCN6855 hw2.0 set: `amss.bin`, `board-2.bin`, `m3.bin`, `regdb.bin`), `/lib/firmware/qca` carries the Bluetooth rampatches, and `/lib/firmware/updates` is another 168 MiB. Adreno zap for this GPU is `qcom/a623_zap.mbn` (the running tree also stages it under the sa8775p/qcs8300 firmware dirs). DSP skeleton libraries live outside the firmware tree, under `/usr/share/qcom/qcs8300/Qualcomm/QCS8300-RIDE/dsp/`, and the FastRPC daemons pick adsp/cdsp payloads by soc_id from there.

Userspace enablement, the part a kernel census misses:

* `qcom-fastrpc1` `1.0.15+repack2`: `adsprpcd`, `cdsprpcd`, `gdsprpcd` (plus cdsp1/gdsp1 variants), `libadsprpc`/`libcdsprpc`, udev rules for the fastrpc and dma-heap nodes, and the systemd units. The units gate on the `/dev/fastrpc-*` nodes and stage the right `/usr/share/qcom` payload per soc_id (675 takes the QCS8300-RIDE set). Without this package the DSPs boot and nothing can talk to them.
* `qrtr-tools` and `libqrtr1`/`libqrtr-glib0`, plus `qrtr-ns.service` (QIPCRTR name service). `ath11k` and the audio DSP path both ride QRTR.
* `alsa-conf-qcom` `1.18` and a Qualcomm build of `alsa-ucm-conf` (`1.2.14-1qcom0.1arduino3`): topology binaries `MONACO-EVK-tplg.bin`, `monaco-gertrude-tplg.bin`, `QCS8275-IQ8-EVK-tplg.bin` in the firmware tree, and the UCM profiles under `/usr/share/alsa/ucm2/Qualcomm/`. Stock UCM does not know this machine name (`monaco-gertrude`) or this card.
* Qualcomm builds of GStreamer `1.24.2` (`libgstreamer-qcom`, `gstreamer1.0-plugins-qcom-good` and friends, from the same PPA). The hardware video path on this board is exercised through those plugins.
* QAIRT `2.49.0` (`qairt-libs`, `qairt-dsp-binaries`, `qairt-tools`, `qairt-headers`, all `-0ubuntu1~bpo24.04.2` from the PPA): the Hexagon HTP stack that sits on top of FastRPC and the CDSP. Proprietary, PPA only. I do not scope it into the image. I do scope the layers under it, because without them QAIRT has nothing to run on.
* Mesa `25.2.8-0ubuntu0.24.04.4` with both `msm_dri.so` and `kgsl_dri.so` in the DRI directory. The display controller binds `msm_dpu` and card0 is an MSM DRM device. Which GL driver a given session picks is a runtime question I did not settle at inspection time (no `glxinfo` run against a live desktop session), and it matters for the comparison below, so it is an explicit Phase 1 check, not an assumption.
* The Arduino packages proper: `arduino-ventunoq` `0.4.0` (meta: `adbd`, `arduino-app-cli`, `arduino-router`, `arduino-app-lab`, `arduino-cli`, `arduino-cloud-connector`, `arduino-ventunoq-config`, `arduino-linux-config`), from `apt-repo.arduino.cc`. These are .deb only and I scope them out of the desktop image itself. Two exceptions are noted where they touch hardware: the device tree hook above, and the router/MCU path in the checklist.

## What the stock Azure aarch64 kernel already has

The aarch64 config is a different animal from the x86_64 config. 224 lines mention QCOM on aarch64, against 9 on x86_64. `CONFIG_ARCH_QCOM=y`. Verified present, as `=y` or `=m`, in the aarch64 file:

* Platform core for this SoC: `QCS_GCC_8300`, `SA_GCC_8775P`, `SA_DISPCC_8775P`, `SA_GPUCC_8775P`, `SA_VIDEOCC_8775P`, `SA_CAMCC_8775P`, `PINCTRL_QCS8300`, `PINCTRL_SA8775P`, `INTERCONNECT_QCOM_QCS8300`, `INTERCONNECT_QCOM_SA8775P`, RPMH/RPM regulators, `QCOM_TSENS`, `QCOM_WDT`, cpufreq HW (`ARM_QCOM_CPUFREQ_HW`).
* Bus and storage: `PCIE_QCOM` (built in, with the common layer), `NVME_CORE` built in, `MMC_SDHCI_MSM`, `SCSI_UFS_QCOM` with `PHY_QCOM_QMP_UFS`, `USB_STORAGE` and `USB_UAS`.
* Display and GPU: `DRM_MSM` with MDSS, DPU, DP, DSI and its PHYs, HDMI with HDCP, plus `DRM_I2C_ADV7511` (with CEC) and `DRM_DISPLAY_CONNECTOR` for this board's HDMI path.
* Video and camera, upstream drivers: `VIDEO_QCOM_IRIS`, `VIDEO_QCOM_VENUS`, `VIDEO_QCOM_CAMSS`.
* DSP and IPC: `QCOM_Q6V5_PAS` (with the common and sysmon layers), `QCOM_FASTRPC`, `QCOM_MDT_LOADER`, `QRTR` with SMD and MHI transports, `RPMSG` with the GLINK transports, `QCOM_APR`, `MHI_BUS` with the PCI generic driver.
* Wired and wired adjacent: `DWMAC_QCOM_ETHQOS` on `STMMAC`, `QCA808X_PHY`, `PHY_QCOM_SGMII_ETH`.
* USB and Type-C: `USB_DWC3_QCOM`, `TYPEC` with `TYPEC_UCSI`, `UCSI_CCG` and `I2C_CCGX_UCSI` (the Cypress part on this board), gadget and configfs including `USB_F_ACM` and `USB_F_FS`, `USB_ACM` for host side ACM.
* Input and misc desktop bits that x86_64 lacks: `USB_HID`, `INPUT_MOUSE` with `MOUSE_PS2`, `I2C_HID` with `HID_MULTITOUCH`, `CAN` with `CAN_GS_USB` (the exact driver the Arduino microcontroller needs), broad `USB_SERIAL` (cp210x, ftdi_sio and friends, minus ch341), GENI I2C/SPI/UART.
* The 802.11 core without any vendor drivers: `CFG80211` and `MAC80211` are `=m`. RFKILL is on.

That last line is the pattern for the whole comparison. Where Azure turns a subsystem on, the QCOM drivers for this board are almost always already in the list. Where Azure turns a subsystem off, nothing under it exists at all.

## The comparison

| Function (works on Ubuntu today) | Ubuntu driver today | Stock AZL 4 aarch64 | Verdict |
|---|---|---|---|
| SoC clocks, pinctrl, interconnect | qcom kernel, built in | Present (`QCS_GCC_8300`, SA8775P clock set, `PINCTRL_QCS8300`, ICC QCS8300) | Present. Binding test still required. |
| PCIe root ports and switch | `pcieport`, `PCIE_QCOM` | `PCIE_QCOM=y` | Present. |
| NVMe (user disk) | `nvme` | `NVME_CORE=y` | Present. |
| eMMC root | `sdhci_msm` | `MMC_SDHCI_MSM=m` | Present. Initrd must carry it, see boot scope. |
| UFS controller | `ufshcd` qcom | `SCSI_UFS_QCOM=m` | Present. Boot disk on this unit is eMMC, UFS is probed silicon. |
| GPU and display (DP, HDMI) | `msm` (`msm_dpu` binds card0), Mesa 25.2.8 | `DRM_MSM=m` full set, ADV7511 bridge present | Present in config. DT binding plus which Mesa driver wins are open checks. |
| Video encode/decode | Downstream Iris (`iris_vpu`, `msm_vidc`) | Upstream `VIDEO_QCOM_IRIS=m`, `VENUS=m` | Same name, different lineage. Test, do not assume. |
| Camera | Downstream cam stack plus CAMSS | Upstream `VIDEO_QCOM_CAMSS=m` only | Divergent. Highest risk item after the board file. |
| Wi-Fi (WCN6855, PCIe) | `ath11k_pci`, MHI, QRTR over MHI | Core present, `CONFIG_WLAN` off, no `ath11k` at all | **Gap.** New OOT family. |
| Bluetooth (WCN6855, UART) | `hci_uart`, `btqca` | `CONFIG_BT` off, no HCI drivers | **Gap.** New OOT family, UART flavor. |
| Audio (LPASS, MAX98090, HDMI) | `snd_q6apm`/`q6prm`, `snd_soc_sc8280xp`, qcom UCM | `CONFIG_SOUND` off. `QCOM_APR=m` alone does nothing | **Gap.** Largest OOT family, plus UCM packaging. |
| Ethernet 2.5G | `dwmac_qcom_ethqos`, QCA808x | Same drivers `=m` | Present. |
| USB host, gadget, ACM | `dwc3_qcom`, TI xHCI, `libcomposite` | `USB_DWC3_QCOM=m`, gadget/configfs present | Present. |
| USB-C PD | `typec_ucsi`, `ucsi_ccg` | `TYPEC_UCSI=m`, `UCSI_CCG=m` | Present. |
| Remoteprocs and FastRPC (kernel) | `qcom_q6v5_pas`, `fastrpc` | Same, `=m` | Present in kernel. Userspace is the gap, below. |
| FastRPC userspace, QRTR name service | `qcom-fastrpc1`, `qrtr-ns` | No AZL or Fedora package known | **Gap.** Packaging, not a kmod. |
| Audio topologies and UCM | `alsa-conf-qcom`, qcom `alsa-ucm-conf` | AZL `alsa-ucm` exists (x86_64 list), contents for this card unverified | **Unverified.** File list check in Phase 0. |
| Firmware blobs (DSP, GPU, Wi-Fi, BT) | `linux-firmware-dragonwing` plus splits | AZL `linux-firmware` contents for `qcom/qcs8300`, `ath11k/WCN6855`, `qca` unverified | **Unverified.** File list check in Phase 0. |
| UVC cameras | `uvcvideo` | `CONFIG_USB_VIDEO_CLASS` off on aarch64 too | **Gap, small.** The x86_64 uvc family ports as is. |
| CAN from the microcontroller | `gs_usb` | `CAN_GS_USB=m` | Present. Router userspace stays an Arduino add on. |
| Serial console | GENI UART, `ttyMSM0` | `SERIAL_QCOM_GENI=y`, console `=y` | Present. |
| Board file and hat overlays | `monaco-monza*.dtb`, 2 hat .dtbo, config hook | Absent from the Azure tree. Mainline has `monaco-arduino-monza` since 2026-03-13 | **Gap.** Backport, per gap 1. |

## Cross-image check

Three other images bear on this board, and each one answers a question the board alone cannot.

Canonical's Ubuntu 24.04 Desktop for the IQ-8275 EVK (build x15, 20260925) is the same SoC on Qualcomm's evaluation board, and Canonical publishes its package manifest. Diffed against this board's installed set: 1,538 package names in common, 12 names only in the EVK image (kernel header and source meta packages), 360 only on this board. The board only set is the Arduino layer, `qcom-fastrpc1`, the forked `alsa-ucm-conf`, and the applications installed on this unit since it shipped. Both run the identical kernel (`linux-image-6.8.0-1089-qcom` 6.8.0-1089.94), the identical `linux-firmware-dragonwing` 20260825, and the identical `alsa-conf-qcom` 1.18. One Canonical qcom kernel serves the EVK and the Monza, and the Ventuno delta over the generic Dragonwing image is thin: Arduino packages, the FastRPC userspace, and the UCM fork (`1.2.14-1qcom0.1arduino3` here against stock `1.2.10-1ubuntu5.14` in the EVK image). The EVK image also ships `protection-domain-mapper` (this board has it too) and no fastrpc daemon at all, which makes `qcom-fastrpc1` an Arduino side addition rather than part of Canonical's Dragonwing baseline.

Arduino publishes no manifest for the Ventuno factory image. The current build (20260729-248, Ubuntu 24.04.4) is a single 6,949,821,785 byte .tar.zst plus release notes, so a package level diff of the newest factory image costs a 7 GB download to read one file. Not done. The release notes list Arduino's maintained packages, and nothing in them moves a conclusion below.

Qualcomm's `qcom-deb-images` builds Debian Trixie images from debos recipes, and its flash recipe carries a target named `monaco-arduino-monza`: soc_id `qcs8300`, ptool platform `qcs8275-monza/emmc`, the Monza CDT from CodeLinaro (`qcs8275-Monza_v1.zip`), and dtb `qcom/monaco-arduino-monza.dtb`. A Debian image for this exact board already exists in that pipeline, built on the `linux-image-qcom-next` kernel packages and systemd-boot. Its kernel config fragments (`kernel-configs/` in that repo) read as a checklist against the Azure aarch64 config, and most of the list is already satisfied: `monza.config` asks for the EMC2305 fan controller, PCA963X LEDs, and INA2XX power sensors (all `=m` in the Azure config), `arduino-accessories.config` asks for the OV5647 camera sensor (`=m`), `qcom-imsdk.config` asks for the system and CMA DMABUF heaps (both present), and `systemd-boot.config` asks for `CONFIG_EFI_ZBOOT=y` (present, though this project boots grub rather than systemd-boot, so the line is informational here). Two misses: `CONFIG_POWER_SEQUENCING_PCIE_M2` is absent from the Azure config (the fragment wants it for a Wi-Fi and Bluetooth M.2 module; this board's WCN6855 is onboard and loads no pwrseq driver under Ubuntu, so I read it as a Phase 1 census check, not a gap), and `CONFIG_SND_SOC_MAX98090` does not appear in the Azure config at all, which is moot while `CONFIG_SOUND` is off and lands in gap 2 either way.

## The gaps, in the order I would work them

### 1. The board file is not in the Azure tree

In `microsoft/CBL-Mariner-Linux-Kernel` at `rolling-lts/azl4/6.18.31.1`, `arch/arm64/boot/dts/qcom/Makefile` builds exactly one Monaco board: `monaco-evk.dtb`. For the wider family it builds `qcs8300-ride.dtb`, `sa8775p-ride.dtb`, and `sa8775p-ride-r3.dtb`. There is no `monaco-monza.dts`, no Monza addons file, and no Arduino hat overlay in the tree. The SoC include (`qcs8300.dtsi`) is there.

Mainline is a different story. `torvalds/linux` carries `monaco-arduino-monza.dts`: first commit `70e3a6120` ('arm64: dts: qcom: Add Arduino Monza (VENTUNO Q) board support', 2026-03-13) with 11 follow ups since, and the follow ups name gap 2 functions in tree form (USB-C controller and connector, 2026-04-21; the Bluetooth UART node, 2026-04-29; DisplayPort audio, 2026-05-22; the fan controller and thermal cooling, 2026-06-09). `qualcomm-linux/kernel` branch `qcom-next` carries the same board plus a camx camera overlay set. Neither 6.17.y nor 6.18.y has any of it. The Azure 6.18 tree is simply too old to contain this board, and the `qcom-deb-images` flash target in the cross-image check is built on a newer kernel for exactly that reason. So the board file work is a backport with a known file list, not a port from the Ubuntu kernel's downstream tree: take the mainline board and addons wiring against the `qcs8300.dtsi` the Azure tree already has. The Ubuntu `monaco-monza.dts` and `monaco-addons-monza.dts` stay useful as the record of what the shipping board actually runs.

Two delivery shapes are possible and the choice is Phase 3's first decision: (a) carry the compiled Monza .dtb/.dtbo as project assets and install them where the boot chain looks, with a postinst equivalent so kernel updates keep them, or (b) get the board booting on the firmware supplied tree (the path Ubuntu uses today) and treat carrying the backport as a longer term maintenance job. The mainline file list makes (a) a known quantity rather than an open ended port, which weakens the case for (b) some. I still lean towards (b) for the first boot test, because it removes the board file from the critical path of the driver census, and (a) for the shippable image, because an image that depends on a vendor firmware tree it does not control is fragile. That is an opinion. The census in Phase 1 settles which one is actually available.

Related, and easy to miss: the addons tree is what wires the PCIe switch, the TI xHCI, the ADV7511, the MAX98090, and the CYPD6129 to the SoC. A base `monaco-monza` tree without the addons layer boots to a serial console and not much else. The checklist tests the addons functions individually for exactly that reason.

### 2. WLAN, BT, SOUND: the same three switches, the same fix pattern

The exact lines, in both arch files at head:

```
# CONFIG_WLAN is not set
# CONFIG_BT is not set
# CONFIG_SOUND is not set
```

On x86_64 this project answers each one with an out of tree family built against the exact `kernel-devel` (see `findings/desktop-kmod-packages-breakdown.md`). On aarch64 the same three families are needed, but the contents differ, and sizing them as renames of the x86_64 families would be wrong:

* **wlan (new):** `ath11k` plus `ath11k_pci`. The dependencies are already stock (`MHI_BUS`, `QRTR_MHI`, `CFG80211`, `MAC80211`), which is the good news. The x86_64 intel family (`iwlwifi`) is no use here. Firmware is the WCN6855 hw2.0 set, pending the Phase 0 file list check. No dracut requirement: Wi-Fi is not needed to mount root.
* **bluetooth (new contents):** the Bluetooth core plus the UART path, `hci_uart` with `btqca` for this chip. The x86_64 bluetooth family is USB shaped (`btusb` and the USB vendor helpers). The helpers overlap (`btrtl`, `btintel`, `btbcm` all load on this board under Ubuntu, hung off `hci_uart`), the transport does not. Firmware is the `qca/` rampatch and NVM set.
* **sound (new, and the largest build this project has attempted):** the full sound subsystem, not the HDA slice the x86_64 sound family ships. Contents: ALSA core, ASoC core, the Qualcomm DSP path (`snd_q6dsp_common`, `snd_q6apm`, `q6apm_dai`, `q6apm_lpass_dais`, `snd_q6prm`/`q6prm_clocks` on APR), the machine layer (`snd_soc_sc8280xp` is what Ubuntu binds for `monaco-gertrude`, with `snd_soc_qcom_common` and `snd_soc_qcom_sdw`), the MAX98090 codec, and the HDMI codec. The build script's own warning applies with force here: the large subsystem stages need the force header treatment, every flipped `CONFIG_` needs its matching `#define`, or the failure is silent. Sound also has a hard userspace half (topologies and UCM, gap 4) and a hard dependency on gap 1 (the machine driver only binds if the tree names the card).
* **uvc (ports as is):** `CONFIG_USB_VIDEO_CLASS` is off on aarch64 too. The existing uvc family is arch portable in contents (`uvcvideo`). It joins the ARM policy set unchanged.

Each family gets the same treatment the x86_64 families get: built from the matching Azure kernel source tarball against stock `kernel-devel`, vermagic checked, shipped under `/usr/lib/modules/$KVER/extra/azurelinux-desktop/`, coupled to the kernel by policy (gap 5). Secure Boot stays as it is on x86_64: these are project signed, not Azure signed, and this board runs with Secure Boot off.

In parallel, and cheap: file the config request upstream. Azure's aarch64 config is a server config that happens to carry a desktop SoC's platform drivers. Asking for `CONFIG_WLAN`/`CONFIG_BT`/`CONFIG_SOUND` on aarch64 costs an issue, not a project. If upstream ever flips them, the three families retire the same way families do. I do not plan around it happening.

### 3. Camera and video are upstream/downstream splits, not switches

Nothing to flip here. The drivers exist on both sides and are different drivers. Ubuntu's video path is the downstream Iris stack (`iris_vpu` module, `msm_vidc` media controller). Azure ships the upstream `iris` driver (plus Venus). They want different firmware interfaces and they bind differently. Phase 1 records which one, if either, binds the Monza tree's video node, and Phase 1 also records the GL driver question from the Mesa note above (Adreno 623 under upstream Mesa is Freedreno/Turnip territory, and Ubuntu shipping `kgsl_dri.so` next to `msm_dri.so` means the board's current sessions may not be running the upstream path at all).

Camera is starker. The running tree describes the downstream Qualcomm camera stack by name, and Azure has no equivalent of it, only upstream CAMSS. If the Monza sensors do not bind CAMSS, camera is the one function the checklist cannot pass on kernel work alone. My call, stated as a decision for review in this PR: camera does not block a first ARM image, provided the image says so plainly in its README support note and the checklist line stays visibly unchecked. Everything else on the checklist blocks. If that trade is wrong, this is the paragraph to argue with.

### 4. Userspace that no repo in the mix supplies

* **FastRPC daemons and DSP payloads.** Package `adsprpcd`/`cdsprpcd`/`gdsprpcd`, the rpc libraries, the udev rules, and the `/usr/share/qcom` payload layout as RPMs, sourced from the same upstream the Ubuntu `qcom-fastrpc1` package builds from. Include `qrtr-ns`. Without these, gap 2's audio DSP path and any HTP work are dead even with every kernel module loaded. This is the highest value packaging job in the scope. It also has a maintained reference now: `qcom-deb-images` pulls `src:fastrpc` (the `fastrpc-support` package) plus `rmtfs`, `tqftpserv`, and `protection-domain-mapper` into its Debian rootfs recipe, so the RPM port follows a source package instead of starting from a blank page.
* **Audio topologies and UCM.** First check what AZL `alsa-ucm` and Fedora 45's `alsa-ucm-conf` already carry for Qualcomm (both have been gaining SA8775/QCS8300 profiles upstream). If `monaco-gertrude` is absent, ship the topology binaries and the UCM profile as a small project package, the alsa equivalent of a kmod family.
* **GStreamer.** Fedora 45's stock GStreamer replaces the Qualcomm build. Hardware decode then depends on the V4L2 path through the upstream Iris driver. Accept stock for v1, test with the checklist's video line, and only package patched plugins if the test fails in a way stock cannot fix.
* **QAIRT.** Out of scope, noted once: it is proprietary, PPA only, and it rides on the FastRPC packaging above. Nothing in the image blocks on it.

### 5. The policy package is x86_64 only, so ARM has no coupling today

`azurelinux-desktop-policy` hard requires the exact x86_64 `kernel-core` EVR and 27 x86_64 kmod packages. That is why it drops out of every ARM resolve in the Fedora 45 findings: a property of the package, not a test artifact. ARM needs its own policy variant (`azurelinux-desktop-policy` built for aarch64, or a separate `azurelinux-desktop-policy-arm`) coupling the aarch64 kernel EVR to the ARM family set: wlan, bluetooth, sound, uvc, plus any family gap 3 forces. The x86_64 only families (psmouse, usbhid, storage, typec, thinkpad and the other laptop platform families, surface, intel) must not be required on ARM: the first three and typec are already stock `=m` on aarch64, and the laptop families name hardware this arch does not have. `scripts/build-desktop-kmods.sh` also hardcodes the x86_64 base URL (`AZL_BASE_URL` default), and `containers/build-kmods` pins the same URL. Both take the arch as a parameter before any ARM family can build in CI.

### 6. Browser on ARM is the bridge project, not a package

Edge is x86_64 only and `scripts/make-arm-ks.py` already drops `microsoft-edge-canary` (along with `powershell`, `code-insiders`, `gh`, `github-desktop`, and the rest of the 11 package drop list). That stays. The ARM browser story is `sirredbeard/edge-arm-bridge`: FEX runs the x86_64 Edge build for sign in and Microsoft sync, and a .NET sync service mirrors the profile, including the GNOME Keyring Safe Storage secret with a decrypt check before swap, into a native arm64 Chromium family browser. On this board the mirror target is Google Chrome arm64 at `/usr/bin/google-chrome`, because Ubuntu's Chromium is snap only here. On an Azure/Fedora base that constraint goes away: Fedora ships a native aarch64 Chromium. Scope for the image is small: preinstall the Fedora aarch64 Chromium, leave the bridge as a documented add on (its bundle is self contained and distro agnostic by design), and do not block the image on the bridge's untested items (live keyring move with real password autofill, headed Wayland sign in from the bundled image). PowerShell, VS Code Insiders, and the GitHub tools each need their own aarch64 availability check before the ARM kickstart promises them; `make-arm-ks.py` dropping them for test builds is not a verdict on the final list.

### 7. Boot and install: live first, installer last, eMMC untouched until both work

The ARM live path already exists as a test: `scripts/make-arm-ks.py` (aarch64 repo URLs, `grub2-efi-aa64` and `shim-aa64` swaps, the drop list, x86_64 side loads neutralized) and `.github/workflows/build-live-iso-arm-test.yml` (`ubuntu-24.04-arm` runner, `containers/build-lorax/Dockerfile.aarch64`, build only, artifacts retained 3 days). The Fedora 45 rebase already fixed the aarch64 lorax EFI gate on this branch (the `gcdaa64.efi` copy in `%post`). What does not exist is a boot of that image on this board.

First boot target is external media (USB stick on the TI xHCI, or the NVMe), never the eMMC. Two board specific risks get tested there: (a) the initrd. The Azure dracut policy must carry `sdhci_msm`, its interconnect and clock dependencies, and `nvme`/`usb-storage` for the external paths, early enough to find root on a platform device tree system with no ACPI. The x86_64 findings (`usb-storage-missing-initrd.md`, `early-kms` work) are the warning shape. (b) The firmware supplied device tree. If grub on the live image tries to load a distro .dtb instead, the boot test measures that too, by failing.

The kiwi installer is out of scope until the live image passes the checklist on this board. The upstream Azure installer assumes it owns the disk layout. This board's eMMC layout is owned by the Qualcomm boot chain, and an installer that repartitions p1 to p68 bricks the board in a way no ISO can undo. When the installer work starts, it starts from 'install into the `system-boot` plus `writable` shape that already exists' as a requirement, not as a preference.

## Scope: phases and deliverables

Phase 0, checks that cost no builds (do first, all are file lists and config reads):

1. AZL aarch64 `linux-firmware` file list: confirm or deny `qcom/qcs8300/` (adsp/cdsp/gpdsp .mbn set), the Adreno 623 zap (`a623_zap.mbn`), `ath11k/WCN6855/hw2.0/`, and the `qca/` Bluetooth set. Same check on the Fedora 45 side for any name the kickstart currently excludes Fedora from supplying.
2. AZL and Fedora `alsa-ucm` contents: confirm or deny a `monaco-gertrude` (or QCS8300/SA8775P) topology and UCM profile.
3. Re-diff the three off switches and the present list against the exact shipping EVR's config (6.18.31 today).
4. Fedora 45 aarch64 availability list for the `make-arm-ks.py` drop list, one line per package: published for aarch64 upstream, or not.

Phase 1, driver census on the board (one live boot, no eMMC writes): boot the ARM test live rootfs from USB or NVMe on ventunoq, capture `dmesg`, `lsmod`, `/sys/class/drm`, `v4l2-ctl --list-devices`, and a desktop session's `glxinfo -B`. Deliverable is a census table appended to this file: every checklist function, bound or not bound, with the exact dmesg line for the failures. This phase converts every 'Present in config' above into a fact, and settles the Iris and Mesa questions in gap 3.

Phase 2, the three subsystem families plus UVC for aarch64, in the existing pipeline: parameterize `build-desktop-kmods.sh` and the build-kmods container on arch, add the wlan/Bluetooth/sound stages, add `azurelinux-desktop-policy` for aarch64 with the ARM family set, publish to the same Pages repo under the aarch64 arch. Sound goes last in the phase and gets its own canary style module load test, because it is the largest stage and the force header failure mode is silent.

Phase 3, board file: backport `monaco-arduino-monza` plus its addons wiring and overlays from mainline (gap 1), ship the .dtb and the two hat .dtbo as project assets with a kernel postinst equivalent, and wire the LVDS disable and serial console grub.d assets into the ARM kickstart. Deliverable includes `arduino-linux-config hw` parity notes: which hat selections the image supports, stated plainly (both hats ship disabled by default on this unit, and 'supported' means the overlay applies and the codec binds, tested).

Phase 4, userspace packaging: FastRPC plus `qrtr-ns` RPMs, audio topology/UCM package if Phase 0 says one is needed, and the Fedora aarch64 Chromium preinstall in the ARM kickstart. Edge stays dropped, with the README pointing at edge-arm-bridge.

Phase 5, sign-off and support claim: run the checklist end to end on the board, update the README's arch paragraph (today it says aarch64 is 'on the wishlist' and 'not a supported image target yet'), and only then talk about the kiwi installer as a follow on PR.

Out of scope for the whole effort, stated once: QAIRT and the Arduino .deb stack in the image, camera parity if gap 3's test fails (flagged in the README instead, per gap 3), Secure Boot signing (unchanged from x86_64), and any change to the x86_64 images or families.

## No-loss checklist

Every line works on the Ubuntu stack on this board today (2026-11-09 inspection). An ARM image is supported when every line passes on that image, on this board, except the camera line, which follows the gap 3 rule.

- [ ] Boots to gdm on DP or HDMI, no LVDS phantom screen (`video=LVDS-1:d` or tree equivalent in place)
- [ ] Serial console on `ttyMSM0` at 115200 from grub through login
- [ ] GPU accelerated GNOME session (record the Mesa driver and renderer string)
- [ ] Wi-Fi associates through NetworkManager on `wlp3s0` (ath11k, WCN6855 firmware loaded)
- [ ] Bluetooth pairs a headset, `hci0` up (hci_uart, btqca)
- [ ] Audio playback and capture on the `monaco-gertrude` card, plus HDMI audio
- [ ] Hardware video decode in a stock Fedora GStreamer pipeline (`/dev/video32` or successor node present)
- [ ] Camera (gap 3 rule: pass, or the README support note carries the exception)
- [ ] Ethernet link on `end0` at 2500
- [ ] USB host ports (TI xHCI), USB storage boot and read, UVC camera
- [ ] USB gadget on DWC3 (`ttyGS0` ACM, FunctionFS) and host side `ttyACM0` from the microcontroller
- [ ] CAN `can0` to `can2` through `gs_usb`
- [ ] USB-C PD negotiates, UCSI power supply registers
- [ ] All three remoteprocs running, `/dev/fastrpc-*` present, `adsprpcd` and `cdsprpcd` active
- [ ] NVMe /data mounts, eMMC root untouched by the test
- [ ] fwupd still sees the ESRT system firmware device
- [ ] Both hat overlays apply and the IQAudio codec binds (hats fitted for the test)
- [ ] Kernel update keeps every module above (policy coupling holds on aarch64)

## Open decisions in this PR

1. Camera: the gap 3 trade (ship v1 with a printed exception vs block on CAMSS). My recommendation is in gap 3.
2. Board file delivery: firmware tree first for the census, project carried .dtb for the image (gap 1). Argue here if the order should flip.
3. Policy shape: one `azurelinux-desktop-policy` package built per arch, or a separate ARM policy package name. Per arch builds of one name match how the x86_64 repo already thinks, I think, but the Pages repo layout gets a vote too.

This PR is stacked on #41. The ARM harness, the ARM live ISO workflow, and the Fedora 45 package census it cites all live on `rebase/fedora-45`. Retarget to `main` when #41 lands.

## Phase 0 results (2026-11-09, later)

The Phase 0 checks are done. They ran against the Fedora 45 ARM live rootfs built in CI for PR #41 (the shipped kernel is 6.18.31-1.16.azl4, and its config was read from /boot in the image itself, not from the branch head file the comparison above used) and against the Fedora 45 GA aarch64 tree plus the exact repo set the ARM kickstart uses. Two of the four checks change the scope above, one of them substantially.

Item 3 first, because it reframes the rest: the shipped config is not the branch head config. `CONFIG_WLAN=y` and `CONFIG_BT=m` in the shipped file; only `CONFIG_SOUND` is still off. Under those switches the shipped config carries `CONFIG_ATH11K=m` with `ATH11K_PCI=m` and `ATH11K_AHB=m`, `CFG80211` and `MAC80211` as modules, `MHI_BUS` and `QRTR_MHI` as modules, `CONFIG_BT_HCIUART=m` with `CONFIG_BT_QCA=m` and the H4 transport built in, and `CONFIG_USB_VIDEO_CLASS=m`. The ath11k module files are on disk in the image. So of the three out of tree families gap 2 planned, only sound is real. Wi-Fi, Bluetooth, and UVC need no family on this kernel; they move to the Phase 1 census, which now has to prove binding rather than presence. The upstream config request narrows to one switch: `CONFIG_SOUND` on aarch64. `CONFIG_SND_SOC_MAX98090` and `CONFIG_POWER_SEQUENCING_PCIE_M2` appear nowhere in the shipped config, as above.

Item 1, firmware: Azure's linux-firmware in the image carries the Wi-Fi and Bluetooth sets (`ath11k/WCN6855/hw2.0/` with amss, board-2, m3, regdb; the `qca/` rampatch and NVM files) and nothing else this board needs. `/usr/lib/firmware/qcom` holds only the sdx35 and sdx61 modem directories: no `qcs8300/` DSP set at all, and no `a623_zap.mbn` anywhere in the tree. Fedora 45's qcom-firmware carries all of it: `qcom/qcs8300/` with the DSP set (adsp.mbn and friends), `a623_zap.mbn` and `a623_gmu.bin`, `MONACO-EVK-tplg.bin`, and `arduino-monza-tplg.bin`, a topology binary named for this exact board. And the two sets co-install: an install of Azure linux-firmware plus Fedora qcom-firmware plus Azure alsa-ucm into a scratch root, against the ARM kickstart's repos, completes clean (35 packages), and the qcs8300 DSP set, a623_zap.mbn, and both topology binaries are present in the installed tree. The DSP firmware, the GPU zap, and the audio topologies therefore stop being packaging work and become a kickstart decision: the ARM variant takes Fedora's qcom-firmware alongside Azure's linux-firmware. (atheros-firmware stays excluded; Azure's ath11k set is already complete.)

Item 2, UCM and topologies: the topology half is the paragraph above. The UCM half stands as a gap. The image's alsa-ucm carries `Qualcomm/qcs8300` with the monaco-evk profile and `conf.d/qcs8300/MONACO-EVK.conf`, plus sa8775p, but no profile names this board's card (`monaco-gertrude` under Ubuntu), and Fedora 45's alsa-ucm-conf has no qcs8300, monaco, or sa8775 entries at all. What remains is one small project package, or an upstream contribution: a UCM profile for the card the mainline tree names. Which name that is becomes a Phase 1 datum.

Item 4, the drop list against aarch64 availability, arch verified per package: code-insiders is published for aarch64 (vscode repo), gh is published (Fedora 45 and the gh-cli repo), and thermald is published (Fedora 45). Not published for aarch64: microsoft-edge-canary, powershell, and github-desktop (x86_64 only in their repos), azurelinux-desktop-policy (x86_64 only; gap 5 stands), microcode_ctl, intel-media-driver, intel-mediasdk, and virtualbox-guest-additions (absent from every repo the kickstart uses). Three of the eleven drops were precautionary and can come back when the ARM image leaves test status. The rest are availability facts, not choices.

Board file: the shipped kernel's dtb directory carries monaco-evk.dtb, qcs8300-ride.dtb, sa8775p-ride.dtb, and sa8775p-ride-r3.dtb. No monaco-monza.dtb, and no monaco addons or hat overlay files either. Gap 1 stands exactly as written. Mesa: the image carries both msm_dri.so and kgsl_dri.so, same as Ubuntu; the GL driver question stays a Phase 1 runtime check.

What this does to the phases. Phase 2 is now the sound family plus the policy parameterization, and nothing else. Phase 4 loses the DSP firmware (a kickstart line instead of a package) and keeps the FastRPC userspace, qrtr-ns, and the UCM profile. The checklist is unchanged: it tests functions, not provenance, and nothing in Phase 0 proves a single driver binds. Phase 1 is still the gate.

## Implementation results (2026-11-09, later)

The stages are built and the ARM image carries all of them. This section is the record, stage by stage, including the two designs that failed measurement and what replaced them.

Stage 1, firmware. The first fix excluded Azure's qcom-firmware from the ARM azl-base repo line (4064df8) and was not sufficient: the proof build still carried Azure's 20260221-2.azl4. The reason is a family lock, not the hide. Fedora's qcom-firmware version-locks to atheros-firmware and linux-firmware-whence at it's own EVR, Azure's linux-firmware locks to Azure's whence at it's EVR, and the claw-back froze the whole family to Azure, so Fedora's package had no consistent solve at all. A plain dnf container test against the same repos picks Fedora's package the moment the family is free, which is how the lock was isolated. The fix (137aa70) lives in the ARM kickstart generator: it strips the firmware family (linux-firmware, linux-firmware-whence, every *-firmware entry) from the Fedora repos' excludepkgs in the ARM kickstart only, and adds hexagon-dsp-binaries-arduino-monza to the ARM package set. Verified in the image: qcom-firmware and linux-firmware at 20261019-1.fc45, hexagon-dsp-binaries-arduino-monza installed, arduino-monza-tplg.bin and gpdspr.jsn present under qcom/qcs8300. The x86_64 image keeps the Azure firmware set; the unfreeze is ARM only.

Stage 2, sound modules and the policy package. The publish pipeline builds the sound family for both arches and the validate-arm job installs kernel plus policy from the live repo on an ARM runner. One design flaw showed up in the cross build: an aarch64 policy cross-built as noarch carried a release string (1.16.azl4.aarch64) that sorts above the native x86_64 build, so an x86_64 solve against the flat repo picked the cross package and failed on it's aarch64 kernel requirement. That is what killed an installer verification build on the PR #41 branch. The fix (7a1f072): publish keeps the package jobs' native policy and drops a cross rebuild whenever a native build exists for the same kernel, with a post-build sweep for any noarch shadowed by a native. The final ARM image carries the native aarch64 policy and 30 sound modules under extra/azurelinux-desktop. The module load check still belongs to Phase 1: it needs the Azure kernel running on the board.

Stage 3, the board file. The backport compiles. The sources are the mainline monaco-arduino-monza.dts and monaco-monza-som.dtsi retargeted at the Azure tree's qcs8300.dtsi, plus a project supplement carrying the subtrees the Azure tree lacks (the extracted upstream nodes, the tsens set, the LPASS pinctrl node, the DSI PHY binding includes). dtc exits 0 and the blob is 127,359 bytes; a decompile shows the Monza model string, mdss, cci, both PCIe root ports and PHYs, four tsens, the LPASS pinctrl, and the thermal zones. The compiled blob and the three sources are committed under assets/dtb (blob sha256 712646239b186627d1ccb450f184ae86ba28db25e6079f3fb5d50a082d8fb271), and the ARM kickstart %post stages the blob into the kernel modules dtb/qcom directory and the sources into /usr/share/azl/monza-dt. Verified in the final image: the staged blob is byte-identical to the committed one. Grub does not load the blob yet. The firmware supplied tree stays authoritative until the Phase 1 census compares the two on the board, which is the order gap 1 recommended.

Stage 4, the repacks. Four specs under packaging/, each built from the actual deb payload off the board and content-verified against it: qcom-fastrpc 1.0.15 (the adsprpcd, cdsprpcd, and gdsprpcd daemons, the libraries, the udev rules), qcom-libdmabufheap 1.1.0, qrtr-tools 1.0 (qrtr-ns and it's hardened unit), and alsa-conf-qcom 1.18 as noarch (the monaco-gertrude UCM profile). Each spec carries a marker line naming the deb version it was cut from; the stage 5 build replaces that line with a real Provides.

Stage 5, the automation. It lives inside publish-desktop-kmods.yml rather than in a workflow of it's own, because the Pages deployment replaces the whole site tree: one publish owner is a hard constraint, not a preference. A detect job reads the three apt indices (Arduino stable, the Dragonwing PPA, noble ports), parses the tracked debs, and compares each deb version against the deb-version() Provides recorded in the live repo's primary.xml. A build job on an ARM runner extracts the deb, stamps version, release, and the Provides into a copy of the committed spec, and rpmbuilds inside the Fedora 45 container. Release is the highest published release for that name and version plus one. Two latent bugs surfaced on the first runs. The detect regex never matched real createrepo output, because attributes sit between the entry name and it's ver attribute, so published state never parsed as current and every run would have rebuilt everything forever. And a repack whose spec changed while it's deb stood still would never rebuild at all, which is exactly the change the alsa fixes below are. The fix (be3110f) corrects the pattern (including the ver and rel rejoin for versions that contain a dash, qrtr-tools 1.0-2ubuntu3) and stamps a spec-hash() Provides at build time, hashed from the pristine committed spec, which detect compares alongside the deb version. The canary proof: one run rebuilt all four repacks at release 2 on the hash change alone, and the next rebuilt only alsa-conf-qcom at release 3 when only it's spec changed.

The ARM transaction failures, both alsa. The first full ARM build with the stage 4 set (42732890295) failed the solve: 'nothing provides alsa-ucm-conf needed by alsa-conf-qcom'. The spec had carried the Debian package name out of the source deb's Depends; Azure and Fedora both name the base UCM package alsa-ucm. Fixed in be3110f, and the other three specs' requirements were audited at the same time. The second build (42740445949) passed the solve, downloaded 1,097 packages, and died in the transaction. Anaconda reports only that the transaction ended with errors, so the cause was measured on the board instead: the overlay's copies of five UCM files (the monaco-evk and lemans-evk profiles) differ in content from the stock alsa-ucm 1.2.15.3, which already ships those profiles, and RPM treats that as a hard file conflict. A full intersection of all four repacks, the hexagon packages, and Fedora's qcom-firmware against the entire RC image file manifest showed no other overlaps, directories aside. The fix (8a8b7c9) prunes the stock-carried profiles in the spec's %install and keeps everything else, including all of monaco-gertrude, which the stock package does not carry at all. The overlay is smaller and still necessary.

Final census (build 42743679537, ISO sha256 9b4420d499e7e96ef0255e47bbb0ccb0926bd7fe2339672449e516656dd6784d). Kernel 6.18.31-1.16.azl4.aarch64, 1,107 packages. The device tree blob sits in the modules dtb/qcom directory, byte-identical to the committed blob, sources beside it in /usr/share/azl/monza-dt. The four stage 4 packages are installed at their published releases, daemons and units on disk, the monaco-gertrude profile present next to the stock MONACO-EVK one. The policy package is the native aarch64 build. The Copilot flatpak and the Chromium and Edge bridge entries are present. Against the same day's x86_64 image (1,133 package names, 1,072 in common): the 26 ARM-only names are the enablement set plus ARM platform packages, the 61 x86_64-only names are the x86 kmod families and the generator's x86-only app drops with their dependency tails, and the version deltas on common names are the firmware family by design, langpacks from the ARM repo shaping, and five packages of Fedora updates drift between the two build times. Nothing unexplained.

What remains is Phase 1 and the checklist. Nothing in this section proves a driver binds, a module loads, or a daemon opens a DSP session: the census for that needs the Azure kernel booted on the board, and the sound module load check and the stage 4 runtime check fold into it. The three open decisions above stand.

Close-out (2026-11-09, later still). This branch was rebased onto PR #41's final squashed head, so the ARM image now carries the four field fixes from that branch (the 668-name claw-back, the Copilot GUI install, the current gh-cli keyring, the keyring helper rewrite) alongside the enablement set. The rebased tree was re-verified before the squash: the consistency check passes, the ARM generator runs clean, and it's output still shows the stage 1 unfreeze (649 names on the Fedora line, the 19 firmware entries gone) with the stage 4 packages and the device tree staging in place. The branch then went through the standing Copilot CLI review before the squash: verdict merge-safe, no blockers. It's one major did not survive triage: it asked for assertions that the hexagon package and the four repacks reach the ARM package set, and the generator already asserts exactly that (make-arm-ks.py, the assertion block after the favorites rewrite), along with the unfreeze check it's minor items asked for. The rest of the review was design commentary the sections above already record, including the device tree blob as a carried asset with it's sha256 pinned here and verified in the image.

The RC census caught one real interaction between the two branches (2026-11-09, night). The first ARM build from the final heads (42748166220) came back with the keyring helper and it's autostart entry missing from their installed locations, present only in the staged /root/assets copies. The image's %post log shows why: the generator neutralizes the thirdparty fetch for ARM, so /root/thirdparty/github-copilot.rpm never exists in an ARM build, and the chrooted %post still ran the Copilot GUI install against it. The PR #41 loud-failure checks after that install (correct on x86_64, where the RPM is staged) exited the %post at that point, and every later %post step dropped out of the image with it, the keyring install among them. On the pre-rebase base the same failed install only logged, so the script walked past it. The fix is in the generator: it replaces the install line and the two checks with an ARM skip comment, and asserts both are absent from the generated kickstart. The x86_64 kickstart is untouched. Everything else in that census matched the pre-rebase ARM image, with the keyring key and the 668-name list now current.
