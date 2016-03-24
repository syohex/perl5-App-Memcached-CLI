package App::Memcached::CLI::Main;

use strict;
use warnings;
use 5.008_001;

use Carp;
use File::Basename 'basename';
use Getopt::Long qw(:config posix_default no_ignore_case no_ignore_case_always);
use IO::Socket::INET;
use List::Util qw(first);
use Term::ReadLine;

use App::Memcached::CLI;
use App::Memcached::CLI::DataSource;
use App::Memcached::CLI::Item;
use App::Memcached::CLI::Util ':all';

use version; our $VERSION = 'v0.5.2';

my $PROGRAM = basename $0;

my %COMMAND2ALIASES = (
    help       => ['\h'],
    version    => ['\v'],
    quit       => [qw(\q exit)],
    display    => [qw(\d)],
    stats      => [qw(\s)],
    settings   => [qw(\c config)],
    cachedump  => [qw(\cd dump)],
    detaildump => [qw(\dd)],
    detail     => [],
    get        => [],
    set        => [],
    delete     => [],
);
my %COMMAND_OF;
while (my ($cmd, $aliases) = each %COMMAND2ALIASES) {
    $COMMAND_OF{$cmd} = $cmd;
    $COMMAND_OF{$_}   = $cmd for @$aliases;
}

my $DEFAULT_CACHEDUMP_SIZE = 20;

sub new {
    my $class  = shift;
    my %params = @_;

    eval {
        $params{ds}
            = App::Memcached::CLI::DataSource->connect(
                $params{addr}, timeout => $params{timeout}
            );
    };
    if ($@) {
        warn "Can't connect to Memcached server! Addr=$params{addr}";
        debug "ERROR: " . $@;
        return;
    }

    bless \%params, $class;
}

sub parse_args {
    my $class = shift;

    my %params; # will be passed to new()
    if (defined $ARGV[0] and looks_like_addr($ARGV[0])) {
        $params{addr} = shift @ARGV;
    }
    GetOptions(
        \my %opts, 'addr|a=s', 'timeout|t=i',
        'debug|d', 'help|h', 'man',
    ) or return +{};

    if (defined $opts{debug}) {
        $App::Memcached::CLI::DEBUG = 1;
    }

    %params = (%opts, %params);
    $params{addr} = create_addr($params{addr});

    return \%params;
}

sub run {
    my $self = shift;
    if (@ARGV) {
        $self->run_batch;
    } else {
        $self->run_interactive;
    }
}

sub run_batch {
    my $self = shift;
    debug "Run batch mode with @ARGV" if (@ARGV);
    my ($_command, @args) = @ARGV;
    my $command = $COMMAND_OF{$_command};
    unless ($command) {
        print "Unknown command - $_command\n";
        return;
    } elsif ($command eq 'quit') {
        print "Nothing to do with $_command\n";
        return;
    }

    my $ret = $self->$command(@args);
    unless ($ret) {
        print qq[Command seems failed. Run \`$PROGRAM help\` or \`$PROGRAM help $command\` for usage.\n];
    }
}

sub run_interactive {
    my $self = shift;
    debug "Start interactive mode. $self->{addr}";
    my $isa_tty = -t STDIN && (-t STDOUT || !(-f STDOUT || -c STDOUT));
    unless ($isa_tty) {
        croak "TTY Not Found! Quit.";
    }
    my $exit_loop = 0;
    local $SIG{INT} = local $SIG{QUIT} = sub {
        $exit_loop = 1;
        warn "Caught INT or QUIT. Exiting...";
    };

    $self->{term} = Term::ReadLine->new($PROGRAM);
    print "Type '\\h' or 'help' to show help.\n\n";
    while (! $exit_loop) {
        my ($command, @args) = $self->prompt;
        next unless $command;
        if ($command eq 'quit') {
            $exit_loop = 1;
            next;
        }

        my $ret = $self->$command(@args);
        unless ($ret) {
            print "Command seems failed. Type \\h $command for help.\n\n";
        }
    }
    debug "Finish interactive mode. $self->{addr}";
}

sub prompt {
    my $self = shift;

    local $| = 1;
    local $\;

    my $input = $self->{term}->readline("memcached\@$self->{addr}> ");
    chomp($input);
    return unless $input;
    $self->{term}->addhistory($input) if ($input =~ m/\S/);

    my ($_command, @args) = split(m/\s+/, $input);
    my $command = $COMMAND_OF{$_command};
    print "Unknown command - $input\n" unless $command;

    return $command, @args;
}

sub help {
    my $self    = shift;
    my $command = shift || q{};

    my @command_info = (
        +{
            command => 'help',
            summary => 'Show help (this)',
        },
        +{
            command => 'version',
            summary => 'Show server version',
        },
        +{
            command => 'quit',
            summary => 'Exit',
        },
        +{
            command => 'display',
            summary => 'Display slabs info',
        },
        +{
            command => 'stats',
            summary => 'Show stats',
        },
        +{
            command => 'settings',
            summary => 'Show settings',
        },
        +{
            command => 'cachedump',
            summary => 'Show cachedump of specified slab',
            description => <<'EODESC',
Usage:
    > cachedump <CLASS> <NUMBER>
    > cachedump 1 10
    > cachedump 3     # default <NUMBER>
EODESC
        },
        +{
            command => 'detaildump',
            summary => 'Show detail dump',
            description => <<'EODESC',
Description:
    Report statistics about data access using KEY prefix. The default separator
    for prefix is ':'.
    If you have not enabled reporting at Memcached start-up, run "detail on".
    See man memcached(1) for details.
EODESC
        },
        +{
            command => 'detail',
            summary => 'Enable/Disable detail dump',
            description => <<'EODESC',
Usage:
    > detail on
    > detail off

Description:
    See "\h detaildump"
EODESC
        },
        +{
            command => 'get',
            summary => 'Get data of KEY',
            description => <<'EODESC',
Usage:
    > get <KEY>
EODESC
        },
        +{
            command => 'set',
            summary => 'Set data with KEY, VALUE',
            description => <<'EODESC',
Usage:
    > set <KEY> <VALUE> [<EXPIRE> [<FLAGS>]]
    > set mykey1 MyValue1
    > set mykey2 MyValue2 0     # Never expires. Default
    > set mykey3 MyValue3 120 1
EODESC
        },
        +{
            command => 'delete',
            summary => 'Delete data of KEY',
            description => <<'EODESC',
Usage:
    > delete <KEY>
EODESC
        },
    );
    my $body   = q{};
    my $space  = ' ' x 4;

    # Help for specified command
    if (my $function = $COMMAND_OF{$command}) {
        my $aliases = join(q{, }, _sorted_aliases_of($function));
        my $info = (grep { $_->{command} eq $function } @command_info)[0];
        $body .= sprintf qq{\n[Command "%s"]\n\n}, $command;
        $body .= "Summary:\n";
        $body .= sprintf "%s%s\n\n", $space, $info->{summary};
        $body .= "Aliases:\n";
        $body .= sprintf "%s%s\n\n", $space, $aliases;
        if ($info->{description}) {
            $body .= $info->{description};
            $body .= "\n";
        }
        print $body;
        return 1;
    }
    # Command not found, but continue
    elsif ($command) {
        $body .= "Unknown command: $command\n";
    }

    # General help
    $body .= "\n[Available Commands]\n";
    for my $info (@command_info) {
        my $cmd = $info->{command};
        my $commands = join(q{, }, _sorted_aliases_of($cmd));
        $body .= sprintf "%-24s%s%s\n", $commands, $space, $info->{summary};
    }
    $body .= "\nType \\h <command> for each.\n\n";
    print $body;
    return 1;
}

sub _sorted_aliases_of {
    my $command = shift;
    my @aliases = @{$COMMAND2ALIASES{$command}};
    return (shift @aliases, $command, @aliases) if @aliases;
    return ($command);
}

sub get {
    my $self = shift;
    my $key  = shift;
    unless ($key) {
        print "No KEY specified.\n";
        return;
    }
    my $item = App::Memcached::CLI::Item->find_by_get($key, $self->{ds});
    unless ($item) {
        print "Not found - $key\n";
    } else {
        print $item->output;
    }
    return 1;
}

sub set {
    my $self = shift;
    my ($key, $value, $expire, $flags) = @_;
    unless ($key and $value) {
        print "KEY or VALUE not specified.\n";
        return;
    }
    my $item = App::Memcached::CLI::Item->new(
        key    => $key,
        value  => $value,
        expire => $expire,
        flags  => $flags,
    );
    unless ($item->save($self->{ds})) {
        warn "Failed to store item. KEY $key, VALUE $value";
        return;
    }
    print "OK\n";
    return 1;
}

sub delete {
    my $self = shift;
    my $key  = shift;
    unless ($key) {
        print "No KEY specified.\n";
        return;
    }
    my $item = App::Memcached::CLI::Item->new(key => $key);
    unless ($item->remove($self->{ds})) {
        warn "Failed to delete item. KEY $key";
        return;
    }
    print "OK\n";
    return 1;
}

sub version {
    my $self = shift;
    my $version = $self->{ds}->version;
    print "$version\n";
    return 1;
}

sub cachedump {
    my $self  = shift;
    my $class = shift;
    my $num   = shift || $DEFAULT_CACHEDUMP_SIZE;

    unless ($class) {
        print "No slab class specified.\n";
        return;
    }
    my $response = $self->{ds}->query("stats cachedump $class $num");
    print "$_\n" for @$response;
    return 1;
}

sub display {
    my $self = shift;

    my %stats;
    my $max = 1;

    my $resp_items = $self->{ds}->query('stats items');
    for my $line (@$resp_items) {
        if ($line =~ m/^STAT items:(\d+):(\w+) (\d+)/) {
            $stats{$1}{$2} = $3;
        }
    }

    my $resp_slabs = $self->{ds}->query('stats slabs');
    for my $line (@$resp_slabs) {
        if ($line =~ m/^STAT (\d+):(\w+) (\d+)/) {
            $stats{$1}{$2} = $3;
            $max = $1;
        }
    }

    print "  #  Item_Size  Max_age   Pages   Count   Full?  Evicted Evict_Time OOM\n";
    for my $class (1..$max) {
        my $slab = $stats{$class};
        next unless $slab->{total_pages};

        my $size
            = $slab->{chunk_size} < 1024 ? "$slab->{chunk_size}B"
            : sprintf("%.1fK", $slab->{chunk_size} / 1024.0) ;

        my $full = ($slab->{free_chunks_end} == 0) ? 'yes' : 'no';
        printf(
            "%3d %8s %9ds %7d %7d %7s %8d %8d %4d\n",
            $class, $size, $slab->{age} || 0, $slab->{total_pages},
            $slab->{number} || 0, $full, $slab->{evicted} || 0,
            $slab->{evicted_time} || 0, $slab->{outofmemory} || 0,
        );
    }

    return 1;
}

sub stats {
    my $self = shift;
    my $response = $self->{ds}->query('stats');
    my %stats;
    for my $line (@$response) {
        if ($line =~ m/^STAT\s+(\S*)\s+(.*)/) {
            $stats{$1} = $2;
        }
    }
    print "# stats - $self->{addr}\n";
    printf "#%23s  %16s\n", 'Field', 'Value';
    for my $field (sort {$a cmp $b} (keys %stats)) {
        printf ("%24s  %16s\n", $field, $stats{$field});
    }
    return 1;
}

sub settings {
    my $self = shift;
    my $response = $self->{ds}->query('stats settings');
    my %stats;
    for my $line (@$response) {
        if ($line =~ m/^STAT\s+(\S*)\s+(.*)/) {
            $stats{$1} = $2;
        }
    }
    print "# stats settings - $self->{addr}\n";
    printf "#%23s  %16s\n", 'Field', 'Value';
    for my $field (sort {$a cmp $b} (keys %stats)) {
        printf ("%24s  %16s\n", $field, $stats{$field});
    }
    return 1;
}

sub detaildump {
    my $self  = shift;
    my $response = $self->{ds}->query("stats detail dump");
    print "$_\n" for @$response;
    return 1;
}

sub detail {
    my $self = shift;
    my $mode = shift || q{};
    unless (first { $_ eq $mode } qw/on off/) {
        print "Mode must be 'on' or 'off'!\n";
        return;
    }
    my $response = $self->{ds}->query("stats detail $mode");
    print "$_\n" for @$response;
    my %result = (
        on  => 'Enabled',
        off => 'Disabled',
    );
    print "$result{$mode} stats collection for detail dump.\n";
    return 1;
}

1;
__END__

=encoding utf-8

=head1 NAME

App::Memcached::CLI::Main - Interactive/Batch CLI for Memcached

=head1 SYNOPSIS

    use App::Memcached::CLI::Main;
    my $params = App::Memcached::CLI->parse_args;
    App::Memcached::CLI->new(%$params)->run;

=head1 DESCRIPTION

This module is used for CLI of Memcached.

The CLI can be both interactive one or batch script.

See L<memcached-cli> for details.

=head1 SEE ALSO

L<memcached-cli>

=head1 LICENSE

Copyright (C) YASUTAKE Kiyoshi.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

YASUTAKE Kiyoshi E<lt>yasutake.kiyoshi@gmail.comE<gt>

=cut

