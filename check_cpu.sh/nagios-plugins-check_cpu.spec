%define debug_package %{nil}

Summary:	A Nagios plugin to check CPU on Linux servers
Name:		nagios-plugins-check_cpu
Version:	0.2
Release:	1%{?dist}
License:	GPLv2+
Group:		Applications/System
URL:		http://www.matejunkie.com/cpu-check-plugin-for-nagios/
Source0:	http://opensource.ok.is/trac/browser/nagios-plugins/check_cpu/releases/nagios-plugins-check_cpu-%{version}.tar.gz
Requires:	nrpe
BuildRoot:	%{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
Packager:	Tomas Edwardsson <tommi@ok.is>

%description
This shell script checks cpu utilization (user,system,iowait,idle in %) 
through /proc/stat accepting seperate threshholds and returning the data in a 
format suitable for performance data processing

%prep
%setup -q
perl -pi -e "s|/usr/lib/|%{_libdir}/|g" nrpe.d/check_cpu.cfg
perl -pi -e "s|/usr/lib64/|%{_libdir}/|g" nrpe.d/check_cpu.cfg

%build


%install
rm -rf %{buildroot}
install -D -p -m 0755 check_cpu.sh %{buildroot}%{_libdir}/nagios/plugins/check_cpu.sh
install -D -p -m 0755 nrpe.d/check_cpu.cfg %{buildroot}/etc/nrpe.d/check_cpu.cfg

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
#%doc README LICENSE
%{_libdir}/nagios/plugins/*
/etc/nrpe.d/check_cpu.cfg


%changelog
* Thu Nov 25 2010  Pall Sigurdsson <palli@opensource.is> 0.1-2
- Nrpe config now ships with plugin by default
* Mon Mar  1 2010  Tomas Edwardsson <tommi@ok.is> 0.1-1
- Initial packaging
