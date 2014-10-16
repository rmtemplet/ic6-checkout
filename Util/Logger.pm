package Util::Logger;

use strict;
use warnings;

use feature qw/say/;

use POSIX qw/strftime/;
use Scalar::Util qw/openhandle/;
use IO::Handle;
use Time::HiRes qw();
use Dancer ':syntax';

use Data::Dumper qw();
use YAML qw();
use JSON qw();

use constant SERIALIZER => 'Data::Dumper';

my @allowed_serializers = qw/
    Data::Dumper
    YAML
    JSON
/;

sub new {
    my $class = shift;
    my %opt = @_;

    unless ($opt{quiet}) {
        $opt{file} or die "No file path provided for logging\n";

        my $file = config->{logdir} . $opt{file};
        (my $dir = $file) =~ s{[^/]+$}{};

        system ("mkdir -p $dir")
            unless -d $dir;

        open (my $fh, '>>:encoding(UTF-8)', $file)
            or die "Cannot open $file: $!\n";

        $fh->autoflush(1);

        $opt{fh} = $fh;
        $opt{seq} = 0;
        $opt{ts_fmt} ||= '%FT%T%z';
    }

    my $pkg = $opt{serializer} ||= SERIALIZER;
    grep { $_ eq $pkg } @allowed_serializers
        or die "'$pkg' not an allowed serialization module";

    return bless (\%opt, $class);
}

sub _common_log {
    my $self = shift;

    my $hdr =
        sprintf (
            '%s %%d %s | ',
            $self->anchor,
            strftime($self->{ts_fmt}, localtime()),
        )
    ;

    local $_ = shift;

    s/\s+$//;
    s/^/sprintf ($hdr, ++$self->{seq})/gsme;

    $self->{fh}->say($_);

    return 1;
}

sub log {
    my $self = shift;
    return if $self->{quiet};
    return $self->_common_log(join ('', grep { defined } @_));
}

sub logf {
    my $self = shift;
    return if $self->{quiet};

    my $msg = shift;
    my @args = map { $self->_uneval($_) } @_;

    return $self->_common_log(sprintf ($msg, @args));
}

sub anchor {
    my $self = shift;
    $self->{anchor} = shift
        if @_;
    return $self->{anchor} ||= sprintf ('%.3f', Time::HiRes::time());
}

sub _uneval {
    my $self = shift;
    my $arg = shift;

    return $arg unless ref ($arg);

    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Indent = 1;

    my $pkg = $self->{serializer};

    my $uneval =
        $pkg eq 'YAML' ? YAML::Dump($arg) :
        $pkg eq 'JSON' ? JSON->new->pretty(1)->encode($arg)
                       : Data::Dumper::Dumper($arg)
    ;

    return $self->_scrub($uneval);
}

sub _scrub {
    my $self = shift;
    local $_ = shift;

    return $_ unless ref (my $keys = $self->{scrub}) eq 'ARRAY';

    for my $k (@$keys) {
        s/$k/'X' x length ($1)/eg;
    }

    return $_;
}

sub DESTROY {
    my $self = shift;
    openhandle($_) && $_->close
        for ($self->{fh});
    return 1;
}

1;
