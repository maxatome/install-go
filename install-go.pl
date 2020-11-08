#!/usr/bin/env perl

use strict;
use warnings;
use 5.010;

use JSON::PP;
use HTTP::Tiny;
use File::Spec;

@ARGV == 1 or @ARGV == 2 or die <<EOU;
usage:
  $0 1.14   [installation_directory/]
  $0 1.9.2  [installation_directory/]
  $0 1.15.x [installation_directory/]
  $0 tip    [installation_directory/]

installation_directory/ defaults to .
EOU


my($TARGET, $DESTDIR) = @ARGV;

$DESTDIR //= '.';

mkdir_p($DESTDIR);
-w $DESTDIR
    or die "$DESTDIR directory is not writable\n";

defined glob("$DESTDIR/go/*")
    and die "$DESTDIR/go directory already exists and not empty\n";

$DESTDIR = File::Spec::->rel2abs($DESTDIR);

my($ARCH, $EXT) = ('amd64', 'tar.gz');
my $OS;
if ($^O eq 'linux' or $^O eq 'freebsd' or $^O eq 'darwin') { $OS = $^O }
elsif ($^O eq 'msys')
{
    $OS = 'windows';
    $EXT = 'zip';
}
else
{
    die "Cannot recognize '$^O' system\n";
}

my $TIP;
if ($TARGET eq 'tip')
{
    my $goroot;
    if ($ENV{GOROOT} and -x "$ENV{GOROOT}/bin/go")
    {
        $goroot = $ENV{GOROOT};
    }
    elsif (system('which go') == 0)
    {
        chomp($goroot = `go env GOROOT`);
    }

    # If go is already installed somewhere, no need to install it
    if ($goroot)
    {
        install_tip("$goroot/bin/go", $DESTDIR);
        exit 0;
    }

    $TARGET = '1.15.x';
    $TIP = 1;
}

my $HTTP = HTTP::Tiny::->new;

# 1.12.3 -> (1.12.3, undef)
# 1.15.x -> (1.15, 4)
($TARGET, my $last_minor) = resolve_target($TARGET);

link_go_if_available($TARGET, $last_minor, $DESTDIR)
    or install_go(get_url($TARGET, $last_minor), $DESTDIR, $TIP);

exit 0;


sub resolve_target
{
    my $target = shift;

    my($vreg, $last_minor);
    if ($target =~ /^\d+\.\d+(?:\.\d+)?\z/a)
    {
        $vreg = quotemeta $target;
    }
    elsif ($target =~ /^(\d+\.\d+)\.x\z/a)
    {
        $target = $1;
        $vreg = quotemeta($target) . '(?:\.([0-9]+))?';
        $last_minor = -1;
    }
    else
    {
        die "Bad target $target, should be 1.12 or 1.12.1 or 1.12.x\n"
    }
    $vreg = qr/^go$vreg\z/;

    my $r = $HTTP->get('https://go.googlesource.com/go/+refs/tags?format=JSON');
    $r->{success} or die "Cannot retrieve tags: $r->{status} $r->{reason}\n$r->{content}\n";

    my $found;
    foreach (keys %{decode_json($r->{content} =~ s/^[^{]+//r)})
    {
        if (/$vreg/)
        {
            $last_minor // return ($target, undef); # OK found

            if ($last_minor < ($1 // 0))
            {
                $last_minor = $1 // 0;
                $found = 1;
            }
        }
    }
    $found or die "Version $target not found\n";

    return ($target, $last_minor);
}

# Github images provide sometimes some go versions. If one of them
# matches, link it instead of downloading a new one.
#
# Win env:
#   GOROOT=C:\hostedtoolcache\windows\go\1.14.10\x64
#   GOROOT_1_10_X64=C:\hostedtoolcache\windows\go\1.10.8\x64
#
# Linux env:
#   GOROOT=/opt/hostedtoolcache/go/1.14.10/x64
#   GOROOT_1_11_X64=/opt/hostedtoolcache/go/1.11.13/x64
sub link_go_if_available
{
    my($target, $last_minor, $dest_dir) = @_;

    my $full = $target;
    $full .= ".$last_minor" if defined $last_minor;

    my $vreg = qr,go[\\/]\Q$full\E[\\/]x64\z,;
    while (my($var, $value) = each %ENV)
    {
        if ($var =~ /^GOROOT(?:_\d+_\d+_X64)?\z/ and $value =~ $vreg)
        {
            say "Find already installed go version $full";
            rmdir "$dest_dir/go";
            symlink($value, "$dest_dir/go") or die "symlink($value, $dest_dir/go): $!\n";
            return 1;
        }
    }
    return;
}

sub get_url
{
    my($target, $last_minor) = @_;

    # Last tag found can be not downloadable yet (days preceding release)
    my $tries = 1 + defined($last_minor);
    for (;;)
    {
        my $full = $target;
        $full .= ".$last_minor" if defined $last_minor;

        say "Check https://golang.org/dl/go$full.$OS-$ARCH.$EXT";
        my $r = $HTTP->head("https://golang.org/dl/go$full.$OS-$ARCH.$EXT");
        return $r->{url} if $r->{success};
        say "=> $r->{status}";

        if ($r->{status} == 404)
        {
            if (defined $last_minor and $last_minor > 0 and $tries--)
            {
                $last_minor--;
                next;
            }
            last;
        }
        die "Cannot check go$full.$OS-$ARCH.$EXT: $r->{status} $r->{reason}\n";
    }

    die "$target archive not found\n";
}

sub install_go
{
    my($url, $dest_dir, $tip) = @_;

    chdir $dest_dir or die "Cannot chdir to $dest_dir: $!\n";

    if ($EXT eq 'zip')
    {
        exe(qw(curl -s -o x.zip), $url);
        exe(qw(unzip x.zip go/bin/* go/pkg/* go/src/*));
        unlink 'x.zip';
    }
    else
    {
        exe("curl -s \Q$url\E | tar zxf - go/bin go/pkg go/src");
    }

    install_tip("$dest_dir/go/bin/go", $dest_dir) if $tip;
}

sub install_tip
{
    my($go, $dest_dir) = @_;

    my $gopath = "$dest_dir/go/gopath";
    mkdir_p($gopath);
    {
        local $ENV{GOPATH} = $gopath;
        exe($go, 'version');
        exe($go, qw(get golang.org/dl/gotip));
    }

    my $gotip = "$gopath/bin/gotip";
    exe($gotip, 'download');

    my $final_go = "$dest_dir/go/bin/go";
    if (-e $final_go)
    {
        say "rename($final_go, $final_go.orig)";
        rename $final_go, "$final_go.orig"
            or die "rename($final_go, $final_go.orig): $!\n";
    }
    else
    {
        mkdir_p("$dest_dir/go/bin");
    }

    say "symlink($gotip, $final_go)";
    symlink($gotip, $final_go) or die "symlink($gotip, $final_go): $!\n";
    #rename $gotip, $final_go or die "rename($gotip, $final_go): $!\n";
}

sub exe
{
    say "> @_";
    system(@_) == 0 or die "@_: $?\n"
}

sub mkdir_p
{
    my $dir = shift;

    return if -d $dir;

    die "$dir is not a directory" if -e $dir;

    my $up = $dir =~ s,[\\/]*[^\\/]+[\\/]*\z,,r;
    mkdir_p($up) if $up ne '';

    mkdir $dir or d $dir or die "Cannot create $dir: $!\n";
}
