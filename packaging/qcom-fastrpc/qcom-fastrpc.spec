# Repack of the Canonical Dragonwing qcom-fastrpc1 deb payload
# (daemons, rpc libraries, units, udev rules). The build stages the
# extracted deb tree at %{_sourcedir}/payload before rpmbuild runs;
# scripts/repack-deb-rpms.sh (stage 5) refreshes it from upstream.
# Deb-Version: 1.0.15+repack2 (last hand-verified snapshot; the repack pipeline stamps the live value as a Provides at build time)
Name:           qcom-fastrpc
Version:        1.0.15
Release:        1.azl
Summary:        Qualcomm FastRPC userspace daemons and libraries
License:        BSD-3-Clause
BuildArch:      aarch64
Requires:       qcom-libdmabufheap
Requires:       (linux-firmware-dragonwing or qcom-firmware)
Requires(pre):  systemd

%description
FastRPC remote processor call daemons (adsprpcd, cdsprpcd,
gdsprpcd) and the libadsprpc/libcdsprpc libraries they serve, for
Qualcomm SoCs with DSP remote processors. Repackaged from the
Ubuntu Dragonwing qcom-fastrpc1 deb for Azure Linux Desktop.

%prep
test -d %{_sourcedir}/payload/usr/sbin

%build

%install
P=%{_sourcedir}/payload
install -Dpm 0755 "$P"/usr/sbin/adsprpcd %{buildroot}%{_sbindir}/adsprpcd
install -Dpm 0755 "$P"/usr/sbin/cdsprpcd %{buildroot}%{_sbindir}/cdsprpcd
install -Dpm 0755 "$P"/usr/sbin/gdsprpcd %{buildroot}%{_sbindir}/gdsprpcd
for so in libadsprpc libcdsprpc libadsp_default_listener libcdsp_default_listener; do
  install -Dpm 0755 "$P"/usr/lib/aarch64-linux-gnu/$so.so.1.0.0 %{buildroot}%{_libdir}/$so.so.1.0.0
  ln -s $so.so.1.0.0 %{buildroot}%{_libdir}/$so.so.1
done
for u in adsprpcd cdsprpcd cdsp1rpcd gdsprpcd gdsp1rpcd; do
  install -Dpm 0644 "$P"/usr/lib/systemd/system/$u.service %{buildroot}%{_unitdir}/$u.service
done
install -Dpm 0644 "$P"/usr/lib/udev/rules.d/60-fastrpc.rules %{buildroot}%{_udevrulesdir}/60-fastrpc.rules
install -Dpm 0644 "$P"/usr/lib/udev/rules.d/60-fastrpc-dmaheap.rules %{buildroot}%{_udevrulesdir}/60-fastrpc-dmaheap.rules
mkdir -p %{buildroot}%{_sysusersdir}
cat > %{buildroot}%{_sysusersdir}/qcom-fastrpc.conf <<SYU
u fastrpc - "Qualcomm FastRPC daemons" - -
SYU
mkdir -p %{buildroot}%{_presetdir}
cat > %{buildroot}%{_presetdir}/90-qcom-fastrpc.preset <<PRE
enable adsprpcd.service
enable cdsprpcd.service
enable gdsprpcd.service
PRE

%files
%{_sbindir}/adsprpcd
%{_sbindir}/cdsprpcd
%{_sbindir}/gdsprpcd
%{_libdir}/libadsprpc.so.1*
%{_libdir}/libcdsprpc.so.1*
%{_libdir}/libadsp_default_listener.so.1*
%{_libdir}/libcdsp_default_listener.so.1*
%{_unitdir}/adsprpcd.service
%{_unitdir}/cdsprpcd.service
%{_unitdir}/cdsp1rpcd.service
%{_unitdir}/gdsprpcd.service
%{_unitdir}/gdsp1rpcd.service
%{_udevrulesdir}/60-fastrpc.rules
%{_udevrulesdir}/60-fastrpc-dmaheap.rules
%{_sysusersdir}/qcom-fastrpc.conf
%{_presetdir}/90-qcom-fastrpc.preset
