# Repack of the Ubuntu qrtr-tools deb payload (QRTR name service).
# Deb-Version: 1.0-2ubuntu3 (last hand-verified snapshot; the repack pipeline stamps the live value as a Provides at build time)
Name:           qrtr-tools
Version:        1.0
Release:        2.azl
Summary:        Qualcomm IPC Router tools and name service
License:        BSD-3-Clause
BuildArch:      aarch64
Requires(pre):  systemd

%description
qrtr-ns, the QIPCRTR name service the Qualcomm DSP services
register with, plus the qrtr-cfg and qrtr-lookup utilities.
Repackaged from the Ubuntu qrtr-tools deb for Azure Linux Desktop.

%prep
test -d %{_sourcedir}/payload/usr/bin

%build

%install
P=%{_sourcedir}/payload
install -Dpm 0755 "$P"/usr/bin/qrtr-ns %{buildroot}%{_bindir}/qrtr-ns
install -Dpm 0755 "$P"/usr/bin/qrtr-cfg %{buildroot}%{_bindir}/qrtr-cfg
install -Dpm 0755 "$P"/usr/bin/qrtr-lookup %{buildroot}%{_bindir}/qrtr-lookup
install -Dpm 0644 "$P"/lib/systemd/system/qrtr-ns.service %{buildroot}%{_unitdir}/qrtr-ns.service
mkdir -p %{buildroot}%{_presetdir}
cat > %{buildroot}%{_presetdir}/90-qrtr-tools.preset <<PRE
enable qrtr-ns.service
PRE

%files
%{_bindir}/qrtr-ns
%{_bindir}/qrtr-cfg
%{_bindir}/qrtr-lookup
%{_unitdir}/qrtr-ns.service
%{_presetdir}/90-qrtr-tools.preset
