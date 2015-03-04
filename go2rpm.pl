#!/usr/bin/perl

=head1 NAME

go2rpm - Create RPM packages from Go packages

=head1 SYNOPSIS

go2rpm <package>

go2rpm [--spec | --srpm] [--workspace <directory>] [--pkg] <package>

go2rpm --man

go2rpm --help

=head1 DESCRIPTION

B<go2rpm> is a tool that helps packaging Go modules into RPM packages. RPM is a
tool that makes it possible to build and distribute software in a
language-agnostic and runtime-agnostic manner.

=cut

use JSON;
use LWP::Simple;
use Getopt::Long;
use File::Temp qw/tempdir/;
use Pod::Usage;

use strict;
use warnings;

# Command line options
my $pkg;
my $spec;
my $srpm;
my $workspace;

=head1 OPTIONS

=over 4

=item B<-h>, B<--help>

Print a brief help message and exits.

=item B<-m>, B<--man>

Prints the manual page and exits.

=item B<--spec> B<< <filename> >>

Save the generated RPM SPEC file into given file.
Defaults to standard output.

=item B<--srpm>

Fetch the distribution file and build a source RPM package.

=item B<--workspace> B<< <directory> >>

Specify workspace. It will be used to keep SCM checkouts (and SPEC files in
case you're building a SRPM unless you've overriden it).

By default, a temporary directory will be used, that will be cleand up upon
exit.

=item [ B<--pkg> ] B<< <package> >>

Name of the Go package to generate RPM for.

=back

=cut

GetOptions (
	'pkg=s'		=> \$pkg,
	'spec=s'	=> \$spec,
	'srpm'		=> \$srpm,
	'workspace=s'	=> \$workspace,
	"h|help"	=> sub { pod2usage (0) },
	"m|man"		=> sub { pod2usage (-verbose => 2) },
) or pod2usage (2);

$pkg = shift @ARGV if @ARGV and not $pkg;
pod2usage ('Package name not specified') unless $pkg;
$workspace = tempdir (CLEANUP => 1) unless $workspace;

# Beautiful, isn't it?
my $template = <<'EOF';
%global debug_package   %{nil}
%global import_path     @PKG@
%global gopath          %{_datadir}/gocode
%global commit          @COMMIT@
%global shortcommit     %(c=%{commit}; echo ${c:0:@SHORTCOMMIT@})

Name:           @NAME@
Version:        0
Release:        0.1.git%{shortcommit}%{?dist}
Summary:        @SUMMARY@
License:        @LICENSE@
URL:            http://%{import_path}
Source0:        @SOURCE@
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
%setup @SETUP@

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
$substs{LICENSE} = 'XXX: FIXME: Determine proper license';
$substs{NAME} = "golang-$pkg";
$substs{NAME} =~ s/\.[^\/]*//;
$substs{NAME} =~ s/\//-/g;
$substs{DESCRIPTION} = '%{summary}';

# Try to fetch this from github.
# XXX: Add google code and maybe some more
if ($pkg =~ /^github.com\/(.*\/([^\/]*))$/) {
	$substs{SUMMARY} = eval { from_json (get ("https://api.github.com/repos/$1"))->{description} };
	$substs{SOURCE} = "https://%{import_path}/archive/%{commit}/$2-%{shortcommit}.tar.gz";
	$substs{SETUP} = "-n $2-%{commit}";
} elsif ($pkg =~ /^code.google.com\/p\/([^\/]*)/) {
	$substs{SOURCE} = "http://$1.googlecode.com/archive/%{commit}.zip";
	$substs{SETUP} = "-n $1-%{shortcommit}";
	$substs{SHORTCOMMIT} = 12;
	$substs{NAME} =~ s/^golang-code-p-/golang-googlecode-/g
}
$substs{SOURCE} ||= 'XXX: FIXME: Determine source distribution location';
$substs{SUMMARY} ||= 'XXX: FIXME: Determine a short summary';
$substs{SETUP} ||= "# XXX: FIXME: Add source tree name";
$substs{SHORTCOMMIT} ||= 7;

# Now fetch the code. We'll need that to determine license, dependencies,
# topmost commit and such stuff.
# XXX: Add Mercurial, etc?
my $localpath = $workspace.'/'.$substs{NAME};
my $scm;
unless (-d $localpath) {
	system ("git clone https://$pkg $localpath") == 0
		or system ("hg clone https://$pkg $localpath") == 0
		or die 'Error cloning repository';
}

# Determine the repository tip.
# XXX: Add Mercurial, etc?
if (-d "$localpath/.git") {
	$substs{COMMIT} = `git --git-dir=$localpath/.git log --format=%H -1`;
} elsif (-d "$localpath/.hg") {
	$substs{COMMIT} = `hg --repository $localpath --debug id -i`;
}
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
	my $replaced;

	foreach my $key (keys %substs) {
		next unless $line =~ /\@$key\@/;

		# A line replace?
		if (ref $substs{$key}) {
			# At most one line key per line
			die if $replaced;

			$replaced = '';
			foreach (@{$substs{$key}}) {
				my $this = $line;
				$replaced .= $this if $this =~ s/\@$key\@/$_/g;
			}
		} else {
			my $this = $line;
			$replaced .= $this if $this =~ s/\@$key\@/$substs{$key}/g;
		}

	}

	print $specfile defined $replaced ? $replaced : $line;
}

# Build srpm
if ($srpm) {
	system ('rpmbuild', '--define', '_disable_source_fetch 0', '-bs', $spec)
		and die 'Could not create the SRPM';
}

=head1 EXAMPLES

=over

=item B<go2rpm.pl --srpm github.com/ActiveState/tail>

Genreate the SRPM, leaving no other arficacts around.

=item B<< go2rpm.pl --workspace ./stuff github.com/ActiveState/tail >golang-Activestate-tail.spec >>

Genreate the SPEC file, leaving the checked out repository around.

=back

=head1 BUGS

Plenty, likely. Fixes are more than welcome!

=over

=item * Only supports GitHub and Google code


=item * Is very hackish

You're supposed to read and fix up the generated SPEC file by hand.

=back

=head1 SEE ALSO

=over

=item *

L<rpm> -- RPM Package manager

=item *

L<rpmbuild> -- Build a RPM package

=back

=head1 COPYRIGHT

Copyright 2014, 2015 Lubomir Rintel

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 AUTHOR

Lubomir Rintel C<lkundrak@v3.sk>

=cut
