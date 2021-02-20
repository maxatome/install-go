#!/usr/bin/env perl

use strict;
use warnings;
use 5.010;

use JSON::PP;
use HTTP::Tiny;
use File::Spec;
use Getopt::Long;

my($NO_GITHUB_PATH, $NO_GITHUB_ENV);
GetOptions('p|dont-alter-github-path' => \$NO_GITHUB_PATH,
           'e|dont-alter-github-env' => \$NO_GITHUB_ENV)
    and (@ARGV == 1 or @ARGV == 2)
    or die <<EOU;
usage: $0 [-p|--dont-alter-github-path] GO_VERSION [INSTALL_DIR]
  $0 1.14   [installation_directory/]
  $0 1.9.2  [installation_directory/]
  $0 1.15.x [installation_directory/]
  $0 tip    [installation_directory/]

INSTALL_DIR defaults to .

By default, if GITHUB_PATH environment variable exists *AND*
references a writable file, INSTALL_DIR/go/bin and
INSTALL_DIR/go/gopath/bin (aka \$GOPATH/bin except if -e or no
GITHUB_ENV) are automatically appended to this file.
-p or --dont-alter-github-path option disables this behavior.

By default, if GITHUB_ENV environment variable exists *AND* references
a writable file, GOROOT and GOPATH are set respectively to "" and
INSTALL_DIR/go/gopath.
-e or --dont-alter-github-env option disables this behavior.
EOU


my($TARGET, $DESTDIR) = @ARGV;

$DESTDIR //= '.';

mkdir_p($DESTDIR);
-w $DESTDIR
    or die "$DESTDIR directory is not writable\n";

defined glob("$DESTDIR/go/*")
    and die "$DESTDIR/go directory already exists and is not empty\n";

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
        my $goroot_tip = install_tip($goroot, $DESTDIR);
        export_env("$DESTDIR/go", $goroot_tip);
        exit 0;
    }

    $TARGET = '1.15.x';
    $TIP = 1;
}


# 1.12.3 -> (1.12.3, undef)
# 1.15.x -> (1.15, 4)
($TARGET, my $last_minor) = resolve_target($TARGET);

my $goroot_env;
link_go_if_available($TARGET, $last_minor, $DESTDIR)
    or $goroot_env = install_go(get_url($TARGET, $last_minor), $DESTDIR, $TIP);

export_env("$DESTDIR/go", $goroot_env);

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

    my $r = http_get('https://go.googlesource.com/go/+refs/tags?format=JSON');
    $r->{success} or die "Cannot retrieve tags: $r->{status} $r->{reason}\n$r->{content}\n";

    my $found;
    foreach (keys %{decode_json($r->{content} =~ s/^[^{]+//r)})
    {
        if (/$vreg/)
        {
            $last_minor // return ($target, undef); # OK found

            if ($last_minor < ($1 // 0))
            {
                $last_minor = $1;
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
        if ($var =~ /^GOROOT(?:_\d+_\d+_X64)?\z/
            and $value =~ $vreg
            and -f -x "$value/bin/go")
        {
            say "Find already installed go version $full";
            mkdir_p("$dest_dir/go");
            foreach my $subdir (qw(bin src pkg))
            {
                symlink("$value/$subdir", "$dest_dir/go/$subdir")
                    or die "symlink($value/$subdir, $dest_dir/go/$subdir): $!\n";
            }
            say "go version $full symlinked and available as $dest_dir/go/bin/go";
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
        my $r = http_head("https://golang.org/dl/go$full.$OS-$ARCH.$EXT");
        return ($r->{url}, $full) if $r->{success};
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
    my($url, $version, $dest_dir, $tip) = @_;

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

    my $goroot_env;
    if ($tip)
    {
        my $goroot_env = install_tip("$dest_dir/go", $dest_dir);
    }
    else
    {
        say "go $version installed as $dest_dir/go/bin/go";
    }

    return $goroot_env;
}

sub install_tip
{
    my($goroot, $dest_dir) = @_;

    my $gopath = "$dest_dir/go/gopath";
    mkdir_p($gopath);
    {
        my $go = "$goroot/bin/go";

        local $ENV{GOPATH} = $gopath;
        local $ENV{GOROOT} = $goroot;
        exe($go, 'version');
        exe($go, qw(get golang.org/dl/gotip));
    }

    my $gotip = "$gopath/bin/gotip";
    exe($gotip, 'download');

    my $final_go = "$dest_dir/go/bin/go";
    if (-e $final_go)
    {
        rename $final_go, "$final_go.orig"
            or die "rename($final_go, $final_go.orig): $!\n";
    }
    else
    {
        mkdir_p("$dest_dir/go/bin");
    }

    symlink($gotip, $final_go) or die "symlink($gotip, $final_go): $!\n";

    say "go tip installed as $final_go";

    return do
    {
        delete local $ENV{GOROOT};
        chomp(my $goroot_env = `$gotip env GOROOT`);
        $goroot_env;
    };
}

sub export_env
{
    my($goroot, $goroot_env) = @_;

    my $gopath;
    if (not $NO_GITHUB_ENV
        and $ENV{GITHUB_ENV}
        and open(my $fh, '>>', $ENV{GITHUB_ENV}))
    {
        $goroot_env //= $goroot;
        $gopath = "$goroot/gopath";
        mkdir_p($gopath);
        print $fh <<EOF;
GOROOT=$goroot_env
GOPATH=$gopath
EOF
        close $fh;
    }

    if (not $NO_GITHUB_PATH
        and $ENV{GITHUB_PATH}
        and open(my $fh, '>>', $ENV{GITHUB_PATH}))
    {
        say $fh "$goroot/bin";
        if (defined $gopath)
        {
            mkdir_p("$gopath/bin");
            say $fh "$gopath/bin";
        }
        close $fh;
    }
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

my $use_curl;

sub http_get
{
    my $url = shift;

    if ($use_curl)
    {
        my %r;
        open(my $fh, '-|', curl => -sLD => '/dev/fd/1', $url)
            or die "Cannot fork: $!\n";

        for (;;)
        {
            my $status_line = <$fh>;
            unless (defined $status_line)
            {
                return {
                    status  => 599,
                    reason  => 'EOF',
                    content => '',
                };
            }

            (undef, $r{status}, $r{reason}) = split(' ', $status_line, 3);
            $r{success} = $r{status} < 400;

            # Consume headers
            { local $/ = "\r\n\r\n"; <$fh> }

            # Redirect -> new header
            last if $r{status} != 302 and $r{status} != 307;
        }

        local $/;
        $r{content} = <$fh>;
        close $fh;
        return \%r;
    }

    my $r = HTTP::Tiny::->new->get($url);
    if (not $r->{success}
        and $r->{status} == 599
        and $r->{content} =~ /must be installed for https support/)
    {
        $use_curl = 1;
        return http_get($url)
    }
    return $r;
}

sub http_head
{
    my $url = shift;

    if ($use_curl)
    {
        my %r = (url => $url);
        open(my $fh, '-|', curl => '--head' => -sL => $url)
            or die "Cannot fork: $!\n";

        for (;;)
        {
            my $status_line = <$fh>;
            unless (defined $status_line)
            {
                return {
                    status  => 599,
                    reason  => 'EOF',
                    content => '',
                };
            }

            (undef, $r{status}, $r{reason}) = split(' ', $status_line, 3);
            $r{success} = $r{status} < 400;

            # Redirect -> new header
            last if $r{status} != 302 and $r{status} != 307;

            # Consume headers and catch location header
            local $/ = "\r\n\r\n";
            $r{url} = $1 if <$fh> =~ /^location:\s*([^\r\n]+)/mi;
        }

        close $fh;
        return \%r;
    }

    return HTTP::Tiny::->new->head($url);
}
