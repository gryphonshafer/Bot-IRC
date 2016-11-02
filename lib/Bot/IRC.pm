package Bot::IRC;
use strict;
use warnings;
use Carp 'croak';
use Daemon::Device;
use IO::Socket;
use IO::Socket::SSL;
use Time::Crontab;

sub new {
    my $class = shift;
    my $self  = bless( {@_}, $class );

    croak('Odd number of elements passed to new()') if ( @_ % 2 );
    croak('Spawn value must be an integer (or undefined)')
        if ( defined $self->{spawn} and not ( $self->{spawn} or $self->{spawn} =~ /^\d+$/ ) );
    croak('connect/server not provided to new()')
        unless ( ref $self->{connect} eq 'HASH' and $self->{connect}{server} );

    for ( qw( name pid_file ) ) {
        croak("daemon/$_ not provided to new()")
            unless ( ref $self->{daemon} eq 'HASH' and $self->{daemon}{$_} );
    }

    $self->{connect}{nick} //= 'bot';
    $self->{connect}{name} //= 'Yet Another IRC Bot';
    $self->{connect}{port} //= 6667;

    $self->{nick} = $self->{connect}{nick};

    $self->{hooks}  = [];
    $self->{ticks}  = [];
    $self->{helps}  = {};
    $self->{loaded} = {};

    $self->load(
        ( ref $self->{plugins} eq 'ARRAY' ) ? @{ $self->{plugins} } : $self->{plugins}
    ) if ( $self->{plugins} );

    return $self;
}

sub load {
    my $self = shift;

    for my $plugin (@_) {
        unless ( ref $plugin ) {
            my $namespace;

            eval 'require ' . __PACKAGE__ . "::$plugin";
            unless ($@) {
                $namespace = __PACKAGE__ . "::$plugin";
            }
            else {
                eval "require $plugin";
                unless ($@) {
                    $namespace = $plugin;
                }
                else {
                    croak("Unable to find or properly load $plugin");
                }
            }

            next if ( $self->{loaded}{$namespace} );

            $namespace->import if ( $namespace->can('import') );
            croak("$namespace does not implement init()") unless ( $namespace->can('init') );

            eval "${namespace}::init(\$self)";
            die($@) if ($@);

            $self->{loaded}{$namespace} = time;
        }
        else {
            $self->$_( @{ $plugin->{$_} } ) for ( qw( hooks helps subs ) );
        }
    }

    return $self;
}

sub reload {
    my $self = shift;
    delete $self->{loaded}{$_} for (@_);
    return $self->load(@_);
}

sub hooks {
    my $self = shift;
    $self->hook( @{$_} ) for (@_);
    return $self;
}

sub hook {
    my ( $self, $when, $code, $attr ) = @_;

    $attr //= {};
    $attr->{priority} //= 0;

    $self->{hooks} = [
        sort {
            $b->{attr} <=> $a->{attr}
        }
        @{ $self->{hooks} },
        {
            when => $when,
            code => $code,
            attr => $attr,
        },
    ];

    $self->subs(  %{ $attr->{subs}  } ) if ( ref $attr->{subs}  eq 'HASH' );
    $self->helps( %{ $attr->{helps} } ) if ( ref $attr->{helps} eq 'HASH' );

    return $self;
}

sub helps {
    my $self = shift;
    $self->{helps} = { %{ $self->{helps} }, @_ };
    return $self;
}

sub subs {
    my $self = shift;
    my $subs = {@_};

    for my $name ( keys %$subs ) {
        no strict 'refs';
        *{ __PACKAGE__ . '::' . $name } = $subs->{$name};
    }
    return $self;
}

sub tick {
    my ( $self, $timing, $code ) = @_;

    push( @{ $self->{ticks} }, {
        timing => ( $timing =~ /^\d+$/ ) ? $timing : Time::Crontab->new($timing),
        code   => $code,
    } );
    return $self;
}

sub run {
    my ($self) = @_;

    $self->{socket} = ( ( $self->{connect}{ssl} ) ? 'IO::Socket::SSL' : 'IO::Socket::INET' )->new(
        PeerAddr        => $self->{connect}{server},
        PeerPort        => $self->{connect}{port},
        Proto           => 'tcp',
        Type            => SOCK_STREAM,
        SSL_verify_mode => SSL_VERIFY_NONE,
    ) or die $!;

    eval {
        $self->{device} = Daemon::Device->new(
            parent     => \&_parent,
            on_message => \&_on_message,
            spawn      => $self->{spawn},
            daemon     => $self->{daemon},
            data       => { self => $self },
        );
    };
    croak($@) if ($@);
    $self->{device}->run;
}

sub _parent {
    my ($device) = @_;
    my $self     = $device->data('self');
    my $session  = {};
    my $delegate = sub {
        my ($random_child) =
            map { $_->[0] }
            sort { $a->[1] <=> $b->[1] }
            map { [ $_, rand() ] }
            @{ $device->children };

        $device->message( $random_child, @_ );
    };

    local $SIG{ALRM} = sub {
        alarm 1;
        my $time = time;

        $_->{code}->($self) for (
            grep {
                ref $_->{timing} and ( $time % 60 == 0 ) and $_->{timing}->match($time) or
                not ref $_->{timing} and ( $time % $_->{timing} == 0 )
            } @{ $self->{ticks} }
        );
    };

    while ( my $line = $self->{socket}->getline ) {
        print $line;
        chomp($line);

        if ( not $session->{established} ) {
            if ( not $session->{user} ) {
                $self->say("USER $self->{nick} 0 * :$self->{connect}{name}");
                $self->say("NICK $self->{nick}");
                $session->{user} = 1;
            }
            elsif ( $line =~ /^:\S+\s433\s/ ) {
                $self->nick( $self->{nick} . '_' );
            }
            elsif ( $line =~ /^:\S+\s001\s/ ) {
                $self->say("JOIN $_") for (
                    ( ref $self->{connect}{join} eq 'ARRAY' )
                        ? @{ $self->{connect}{join} }
                        : $self->{connect}{join}
                );
                $session->{established} = 1;
                alarm 1 if ( @{ $self->{ticks} } );
            }
        }

        $delegate->($line);
    }
}

sub _on_message {
    my $device = shift;
    my $self   = $device->data('self');

    for my $line (@_) {
        if ( $line =~ /^>>>\sNICK\s(.*)/ ) {
            $self->{nick} = $1;
            next;
        }
        elsif ( $line =~ /^:\S+\s433\s/ ) {
            $self->nick( $self->{nick} . '_' );
            next;
        }

        $self->{in} = { map { $_ => '' } qw( line source nick user server command forum text ) };
        $self->{in}{$_} = 0 for ( qw( private to_me ) );
        $self->{in}{line} = $line;

        if ( $line =~ /^:(\S+?)!~?(\S+?)@(\S+?)\s(\S+)\s(\S+)\s:(.*)/ ) {
            @{ $self->{in} }{ qw( nick user server command forum text ) } = ( $1, $2, $3, $4, $5, $6 );
        }
        elsif ( $line =~ /^:(\S+?)!~?(\S+?)@(\S+?)\s(\S+)\s:(.*)/ ) {
            @{ $self->{in} }{ qw( nick user server command text ) } = ( $1, $2, $3, $4, $5 );
        }
        elsif ( $line =~ /^:(\S+?)!~?(\S+?)@(\S+?)\s(\S+)\s(\S+)\s(.*)/ ) {
            @{ $self->{in} }{ qw( nick user server command forum text ) } = ( $1, $2, $3, $4, $5, $6 );
        }
        elsif ( $line =~ /^(PING)\s(.+)/ ) {
            @{ $self->{in} }{ qw( command text ) } = ( $1, $2 );
            $self->say( 'PONG ' . $self->{in}{text} );
            next;
        }
        elsif ( $line =~ /^:(\S+)\s(NOTICE|\d+)\s(\S+)\s(.*)/ ) {
            @{ $self->{in} }{ qw( source command forum text ) } = ( $1, $2, $3, $4 );
        }
        elsif ( $line =~ /^(ERROR)\s/ ) {
            warn $line . "\n";
        }
        else {
            warn 'Unparsed line (probably a bug in Bot::IRC; please report it): ', $line . "\n";
        }

        next unless ( $self->{in}{nick} ne $self->{nick} );

        if ( $self->{in}{command} eq 'PRIVMSG' ) {
            $self->{in}{private} = 1 if ( $self->{in}{forum} and $self->{in}{forum} eq $self->{nick} );
            $self->{in}{to_me}   = 1 if (
                $self->{in}{text} =~ s/^\s*$self->{nick}\b\W*//i or
                $self->{in}{private}
            );
        }

        if ( $self->{in}{to_me} ) {
            if ( $self->{in}{text} =~ /^\s*help\W*$/i ) {
                $self->reply(
                    ( ( $self->{in}{private} ) ? '' : $self->{in}{nick} . ': ' ) .
                    'Ask me for help with "help topic" where the topic is one of the following: ' .
                    join( ', ', sort keys %{ $self->{helps} } ) . '.'
                );
                next;
            }
            elsif ( $self->{in}{text} =~ /^\s*help\s+(.+?)\W*$/i ) {
                $self->reply(
                    ( ( $self->{in}{private} ) ? '' : $self->{in}{nick} . ': ' ) .
                    ( $self->{helps}{$1} || "Couldn't find the help topic: $1." )
                );
                next;
            }
        }

        hook: for my $hook ( @{ $self->{hooks} } ) {
            my $captured_matches = {};

            for my $type ( keys %{ $hook->{when} } ) {
                next hook unless (
                    ref( $hook->{when}{$type} ) eq 'Regexp' and $self->{in}{$type} =~ $hook->{when}{$type} or
                    ref( $hook->{when}{$type} ) eq 'CODE' and $hook->{when}{$type}->(
                        $self,
                        $self->{in}{$type},
                        { %{ $self->{in} } },
                    ) or
                    $self->{in}{$type} eq $hook->{when}{$type}
                );

                $captured_matches = { %$captured_matches, %+ } if ( keys %+ );
            }

            last if ( $hook->{code}->(
                $self,
                { %{ $self->{in} } },
                $captured_matches,
            ) );
        }
    }
}

sub say {
    my $self = shift;

    for (@_) {
        $self->{socket}->print( $_ . "\r\n" );
        print '<<< ', $_, "\n";
    }
    return $self;
}

sub msg {
    my ( $self, $target, $message ) = @_;
    $self->say("PRIVMSG $target :$message");
    return $self;
}

sub reply {
    my ( $self, $message ) = @_;

    if ( $self->{in}{forum} ) {
        $self->msg(
            ( ( $self->{in}{forum} eq $self->{nick} ) ? $self->{in}{nick} : $self->{in}{forum} ),
            $message,
        );
    }
    else {
        warn "Didn't have a target to send reply to.\n";
    }
    return $self;
}

sub nick {
    my ( $self, $nick ) = @_;

    if ($nick) {
        $self->{nick} = $nick;
        $self->{device}->message( $_, ">>> NICK $self->{nick}" )
            for ( grep { $_ != $$ } $self->{device}->ppid, @{ $self->{device}->children } );
        $self->say("NICK $self->{nick}");
    }
    return $self->{nick};
}

1;
