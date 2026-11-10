# Repack of the Canonical Dragonwing alsa-conf-qcom deb payload:
# the Qualcomm UCM profiles the stock alsa-ucm package does not
# carry, including the monaco-gertrude card the Ventuno Q enumerates.
# Deb-Version: 1.18 (last hand-verified snapshot; the repack pipeline stamps the live value as a Provides at build time)
Name:           alsa-conf-qcom
Version:        1.18
Release:        1.azl
Summary:        Qualcomm ALSA UCM profiles (Dragonwing overlay)
License:        BSD-3-Clause
BuildArch:      noarch
Requires:       alsa-ucm

%description
Use Case Manager profiles for Qualcomm sound cards (qcs8300,
qcs9100, qcm6490, sa8775p), including monaco-gertrude, plus the
card configuration fragments and the topology source files.
Repackaged from the Ubuntu Dragonwing alsa-conf-qcom deb for
Azure Linux Desktop. Profiles the stock alsa-ucm package
already ships (monaco-evk, lemans-evk) are pruned at build time;
their overlap is the signal to prune further, and a stock
monaco-gertrude profile would retire this overlay outright.
The base package is alsa-ucm in Azure Linux and Fedora naming;
alsa-ucm-conf is the Debian package name the deb Depends on.

%prep
test -d %{_sourcedir}/payload/usr/share/alsa

%build

%install
P=%{_sourcedir}/payload
mkdir -p %{buildroot}%{_datadir}/alsa
cp -a "$P"/usr/share/alsa/ucm2 %{buildroot}%{_datadir}/alsa/
cp -a "$P"/usr/share/alsa/topology %{buildroot}%{_datadir}/alsa/
install -Dpm 0644 "$P"/var/lib/alsa/conf.d/qcom.conf %{buildroot}%{_sysconfdir}/alsa/conf.d/qcom.conf
# The stock alsa-ucm package (1.2.15.3 in Azure Linux) already
# ships the monaco-evk and lemans-evk profiles, with content that
# differs from this overlay's copies. Shipping both file-conflicts
# at transaction time, so the overlay drops the profiles the
# stock package carries and keeps what it lacks, above all
# monaco-gertrude.
rm -rf %{buildroot}%{_datadir}/alsa/ucm2/Qualcomm/qcs8300/monaco-evk
rm -rf %{buildroot}%{_datadir}/alsa/ucm2/Qualcomm/sa8775p/lemans-evk
rm -f %{buildroot}%{_datadir}/alsa/ucm2/conf.d/qcs8300/MONACO-EVK.conf
rm -f %{buildroot}%{_datadir}/alsa/ucm2/conf.d/sa8775p/LEMANS-EVK.conf

%files
%{_datadir}/alsa/ucm2/Qualcomm/
%{_datadir}/alsa/ucm2/conf.d/qcm6490/
%{_datadir}/alsa/ucm2/conf.d/qcs8275
%{_datadir}/alsa/ucm2/conf.d/qcs8300/
%{_datadir}/alsa/ucm2/conf.d/qcs9075
%{_datadir}/alsa/ucm2/conf.d/qcs9100/
%{_datadir}/alsa/ucm2/conf.d/sa8775p/
%{_datadir}/alsa/topology/
%config(noreplace) %{_sysconfdir}/alsa/conf.d/qcom.conf
