# Repack of the Canonical Dragonwing qcom-libdmabufheap deb payload.
# Deb-Version: 1.1.0+250131+rel1.0+nmu1 (last hand-verified snapshot; the repack pipeline stamps the live value as a Provides at build time)
Name:           qcom-libdmabufheap
Version:        1.1.0
Release:        1.azl
Summary:        Qualcomm DMA-BUF heap library
License:        BSD-3-Clause
BuildArch:      aarch64

%description
libdmabufheap, the DMA-BUF heap allocation library the Qualcomm
FastRPC userspace links against. Repackaged from the Ubuntu
Dragonwing qcom-libdmabufheap deb for Azure Linux Desktop.

%prep
test -d %{_sourcedir}/payload/usr/lib/aarch64-linux-gnu

%build

%install
P=%{_sourcedir}/payload
install -Dpm 0755 "$P"/usr/lib/aarch64-linux-gnu/libdmabufheap.so.0.0.0 %{buildroot}%{_libdir}/libdmabufheap.so.0.0.0
ln -s libdmabufheap.so.0.0.0 %{buildroot}%{_libdir}/libdmabufheap.so.0

%files
%{_libdir}/libdmabufheap.so.0*
