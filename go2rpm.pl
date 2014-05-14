#!/usr/bin/perl

use JSON;
use LWP::Simple;
use Getopt::Long;
use File::Temp qw/tempdir/;

use strict;
use warnings;

# Command line options
my $pkg;
my $spec;
my $srpm;
my $workspace;
GetOptions (
	'pkg=s'		=> \$pkg,
	'spec=s'	=> \$spec,
	'srpm'		=> \$srpm,
	'workspace=s'	=> \$workspace,	
) or die 'Bad command line arguments';

$pkg = shift @ARGV if @ARGV and not $pkg;
die 'Package name not specified' unless $pkg;
$workspace = tempdir (CLEANUP => 1) unless $workspace;

# Beautiful, isn't it?
my $template = <<'EOF';
%global debug_package   %{nil}
%global import_path     @PKG@
%global gopath          %{_datadir}/gocode
%global commit          @COMMIT@
%global shortcommit     %(c=%{commit}; echo ${c:0:7})

Name:           @NAME@
Version:        0
Release:        0.1.git%{shortcommit}%{?dist}
Summary:        @SUMMARY@
License:        @LICENSE@
URL:            http://%{import_path}
Source0:        https://%{import_path}/archive/%{commit}/@REPO@-%{shortcommit}.tar.gz
BuildArch:      noarch
%if 0%{?fedora} < 19 && 0%{?rhel} < 7
ExclusiveArch:  %{ix86} x86_64 %{arm} noarch
%endif

%description
@DESCRIPTION@

%package devel
Requires:       golang
Requires:       golang(@GOREQUIRES@)
Summary:        A golang library for logging to systemd
Provides:       golang(%{import_path}/log) = %{version}-%{release}

%description devel
%{summary}

This package contains library source intended for building other packages
which use %{import_path}.

%prep
%setup -n @REPO@-%{commit}

%build

%install
install -d -p %{buildroot}/%{gopath}/src/%{import_path}
tar cf - $(find -name '*.go') |tar xf - -C %{buildroot}/%{gopath}/src/%{import_path}

%files devel
%doc @DOCFILES@
%{gopath}

%changelog
@CHANGELOG@
EOF

# Reasonable defaults, hopefully
my %substs;
$substs{PKG} = $pkg;
($substs{REPO}) = $pkg =~ /([^\/]*)$/ or die 'Bad (empty?) pkg name given';
$substs{LICENSE} = 'XXX: FIXME: Determine proper license';
$substs{NAME} = "golang-$pkg";
$substs{NAME} =~ s/\.[^\/]*//;
$substs{NAME} =~ s/\//-/g;
$substs{DESCRIPTION} = '%{summary}';

# Try to fetch this from github.
# XXX: Add google code and maybe some more
$substs{SUMMARY} = eval { from_json (get ("https://api.github.com/repos/$1"))->{description} }
	if ($pkg =~ /^github.com\/(.*)/);
$substs{SUMMARY} ||= 'XXX: FIXME: Determine a short summary';

# Now fetch the code. We'll need that to determine license, dependencies, 
# topmost commit and such stuff.
# XXX: Add Mercurial, etc?
my $localpath = $workspace.'/'.$substs{REPO};
unless (-d $localpath) {
	system "git clone http://$pkg $localpath" and die 'Error cloning repository';
}

# Determine the repository tip.
# XXX: Add Mercurial, etc?
$substs{COMMIT} = `git --git-dir=$localpath/.git log --format=%H -1`;
chomp $substs{COMMIT};
die 'Unable to determine topmost commit' unless $substs{COMMIT};

# Find dependencies.
# Maybe there's an easier way to do this? Who knows.
$substs{GOREQUIRES} = [keys %{{
	map { $_ => 1 }
	grep { index ($_, $pkg) != 0 }
	grep { /\./ }
	split /\s+/, `find $localpath -name '*.go' -exec go list -f '{{range .Imports}}{{.}} {{end}}' {} \\;`
}}];

# Crude heuristics to locate documentation files.
$substs{DOCFILES} = [
	map { substr $_, length ($localpath)+1 - length ($_) }
	grep { /\.(md|txt)$/ or /\/[A-Z]+$/ }
	<$localpath/*>
];

# Let's see if we can guess the license
foreach (@{$substs{DOCFILES}}) {
	open my $file, '<', "$localpath/$_" or die "$_: $!";
	my @content = <$file>;
	$substs{LICENSE} = 'MIT'
		if grep { /free of charge, to any person/ } @content
		and grep { /without restriction/ } @content
		and grep { /without limitation the rights to use/ } @content
		and grep { /substantial portions of the Software/ } @content
		and grep { /INCLUDING BUT NOT LIMITED TO THE WARRANTIES/ } @content;
	$substs{LICENSE} = 'BSD'
		if grep { /Redistributions of source code must retain/ } @content
		and grep { /Redistributions in binary form must reproduce/ } @content;
}

# The hardest part. Crafting the change log entry.
my $shortcommit = substr $substs{COMMIT}, 0, 7;
my $date = `date +'%a %b %d %Y'`;
chomp $date;
my $realname = `git config user.name`
	|| `getent passwd $< |cut -d: -f5`
	|| 'Silvester Standalone';
chomp $realname;
my $email = `git config user.email`
	|| 'FIXME';
chomp $email;
$substs{CHANGELOG} = "* $date $realname <$email> - 0-0.1.git$shortcommit\n".
	'- Created by go2rpm';

# Fill in the template
$spec ||= $workspace.'/'.$substs{NAME}.'.spec' if $srpm;
my $specfile;
if ($spec) {
	open $specfile, '>', $spec or die "$spec: $!";
} else {
	open $specfile, '>&STDOUT' or die $!;
}
foreach my $line (split /\n\K/, $template) {
	my $replaced = '';

	foreach my $key (keys %substs) {
		# Maybe there's multiple values to fill in
		my @replaces = ref $substs{$key}
			? @{$substs{$key}}
			: $substs{$key};
		foreach (@replaces) {
			my $this = $line;
			$replaced .= $this if $this =~ s/\@$key\@/$_/g;
		}
			
	}

	print $specfile $replaced || $line;
}

# Build srpm
if ($srpm) {
	system ('rpmbuild', '--define', '_disable_source_fetch 0', '-bs', $spec)
		and die 'Could not create the SRPM';
}
