package Bot::IRC;
# ABSTRACT: Yet Another IRC Bot

use strict;
use warnings;

use Carp 'croak';
use Daemon::Device;
use IO::Socket;
use IO::Socket::SSL;
use Time::Crontab;

# VERSION

sub new {
    my $class = shift;
    my $self  = bless( {@_}, $class );

    croak('Odd number of elements passed to new()') if ( @_ % 2 );
    croak('connect/server not provided to new()')
        unless ( ref $self->{connect} eq 'HASH' and $self->{connect}{server} );

    $self->{spawn} ||= 2;

    $self->{connect}{nick} //= 'bot';
    $self->{connect}{name} //= 'Yet Another IRC Bot';
    $self->{connect}{port} ||= 6667;

    $self->{daemon}           //= {};
    $self->{daemon}{name}     //= $self->{connect}{nick};
    $self->{daemon}{pid_file} //= $self->{daemon}{name} . '.pid';

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
    my $session  = { start => time };
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
                not ref $_->{timing} and ( ( $time - $session->{start} ) % $_->{timing} == 0 )
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
                $self->join;
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
        elsif ( $line =~ /^:(\S+?)!~?(\S+?)@(\S+?)\s(\S+)\s(\S+)/ ) {
            @{ $self->{in} }{ qw( nick user server command forum ) } = ( $1, $2, $3, $4, $5, $6 );
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

sub load {
    my $self = shift;

    for my $plugin (@_) {
        unless ( ref $plugin ) {
            my $namespace;
            for (
                $plugin,
                __PACKAGE__ . "::Y::$plugin",
                __PACKAGE__ . "::X::$plugin",
                __PACKAGE__ . "::$plugin",
            ) {
                eval "require $_";
                unless ($@) {
                    $namespace = $_;
                    last;
                }
                else {
                    croak($@) unless ( $@ =~ /^Can't locate/ );
                }
            }
            croak("Unable to find or properly load $plugin") unless ($namespace);

            next if ( $self->{loaded}{$namespace} );

            $namespace->import if ( $namespace->can('import') );
            croak("$namespace does not implement init()") unless ( $namespace->can('init') );

            eval "${namespace}::init(\$self)";
            die($@) if ($@);

            $self->{loaded}{$namespace} = time;
        }
        else {
            $self->$_( @{ $plugin->{$_} } ) for ( qw( hooks ticks ) );
            $self->$_( $plugin->{$_} ) for ( qw( helps subs ) );
        }
    }

    return $self;
}

sub reload {
    my $self = shift;
    delete $self->{loaded}{$_} for (@_);
    return $self->load(@_);
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

sub hooks {
    my $self = shift;
    $self->hook(@$_) for (@_);
    return $self;
}

sub helps {
    my $self = shift;
    $self->{helps} = { %{ $self->{helps} }, @_ };
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

sub ticks {
    my $self = shift;
    $self->tick(@$_) for (@_);
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

sub register {
    my $self = shift;
    $self->{loaded}{$_} = time for (@_);
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

sub msg {
    my ( $self, $target, $message ) = @_;
    $self->say("PRIVMSG $target :$message");
    return $self;
}

sub say {
    my $self = shift;

    for (@_) {
        $self->{socket}->print( $_ . "\r\n" );
        print '<<< ', $_, "\n";
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

sub join {
    my $self = shift;

    my @join = @{ ( $self->can('store') ) ? $self->store->get('join') || [] : [] };

    unless (@_) {
        if (@join) {
            $self->say("JOIN $_") for (@join);
        }
        elsif ( $self->{connect}{join} ) {
            for (
                ( ref $self->{connect}{join} eq 'ARRAY' )
                    ? @{ $self->{connect}{join} }
                    : $self->{connect}{join}
            ) {
                push( @join, $_ );
                $self->say("JOIN $_");
            }
        }
    }
    else {
        for (@_) {
            push( @join, $_ );
            $self->say("JOIN $_");
        }
    }

    $self->store->set( 'join' => \@join ) if ( $self->can('store') );

    return $self;
}

sub part {
    my $self = shift;

    my @join = @{ ( $self->can('store') ) ? $self->store->get('join') || [] : [] };

    for my $channel (@_) {
        $self->say("PART $channel");
        @join = grep { $_ ne $channel } @join;
    }

    $self->store->set( 'join' => \@join ) if ( $self->can('store') );

    return $self;
}

1;
__END__
=pod

=begin :badges

=for markdown
[![Build Status](https://travis-ci.org/gryphonshafer/Bot-IRC.svg)](https://travis-ci.org/gryphonshafer/Bot-IRC)
[![Coverage Status](https://coveralls.io/repos/gryphonshafer/Bot-IRC/badge.png)](https://coveralls.io/r/gryphonshafer/Bot-IRC)

=end :badges

=head1 SYNOPSIS

    use Bot::IRC;

    # minimal bot instance that does basically nothing except join a channel
    Bot::IRC->new(
        connect => {
            server => 'irc.perl.org',
            join   => '#test',
        },
    )->run;

    # illustrative example of most settings and various ways to get at them
    my $bot = Bot::IRC->new(
        spawn  => 2,
        daemon => {
            name        => 'bot',
            lsb_sdesc   => 'Yet Another IRC Bot',
            pid_file    => 'bot.pid',
            stderr_file => 'bot.err',
            stdout_file => 'bot.log',
        },
        connect => {
            server => 'irc.perl.org',
            port   => '6667',
            nick   => 'yabot',
            name   => 'Yet Another IRC Bot',
            join   => [ '#test', '#perl' ],
            ssl    => 0,
        },
        plugins => [
            'Store',
            'Bot::IRC::X::Random',
            'My::Own::Plugin',
        ],
        vars => {
            store => 'bot.yaml',
        },
    );

    $bot->load( 'Infobot', 'Karma' );
    $bot->load({
        hooks => [ [ {}, sub {}, {} ] ],
        helps => { name => 'String' },
        subs  => { name => sub {} },
        ticks => [ [ '0 * * * *', sub {} ] ],
    });

    $bot->run;

=head1 DESCRIPTION

Yet another IRC bot. Why? There are so many good bots and bot frameworks to
select from, but I wanted a bot framework that worked like a Unix service
out-of-the-box, operated in a pre-fork way to serve multiple concurrent
requests, and has a dirt-simple and highly extendable plugin mechanism. I also
wanted to keep the direct dependencies and core bot minimalistic, allowing as
much functionality as possible to be defined as optional plugins.

=head2 Minimal Bot

You can have a running IRC bot with as little as:

    use Bot::IRC;

    Bot::IRC->new(
        connect => {
            server => 'irc.perl.org',
        },
    )->run;

This won't actually do much apart from connecting to the server and responding
to pings, but it's useful to understand how this works. Let's say you place the
above code into a "bot.pl" file. You start the bot with:

    ./bot.pl start

This will startup the bot. Command-line commands include: start, stop, restart,
reload, status, help, and so on. (See L<Daemon::Control> for more details.)

=head2 Pre-Forking Device

When the bot is started, the parent process will fork or spawn a given number
of children workers. You can control their number along with setting locations
for things like PID file, log files, and so on.

    Bot::IRC->new(
        spawn  => 2,
        daemon => {
            name        => 'bot',
            lsb_sdesc   => 'Yet Another IRC Bot',
            pid_file    => 'bot.pid',
            stderr_file => 'bot.err',
            stdout_file => 'bot.log',
        },
    )->run;

(See L<Daemon::Device> for more details.)

=head1 MAIN METHODS

The following are the main or primary available methods from this class.

=head2 new

This method instantiates a bot object that's potentially ready to start running.
All bot settings can be specified to the C<new()> constructor, but some can be
set or added to through other methods off the instantiated object.

    Bot::IRC->new(
        spawn  => 2,
        daemon => {},
        connect => {
            server => 'irc.perl.org',
            port   => '6667',
            nick   => 'yabot',
            name   => 'Yet Another IRC Bot',
            join   => [ '#test', '#perl' ],
            ssl    => 0,
        },
        plugins => [],
        vars    => {},
    )->run;

C<spawn> will default to 2. Under C<connect>, C<port> will default to 6667.
C<join> can be either a string or an arrayref of strings representing channels
to join after connnecting. C<ssl> is a true/false setting for whether to
connect to the server over SSL.

Read more about plugins below for more information about C<plugins> and C<vars>.
Consult L<Daemon::Device> and L<Daemon::Control> for more details about C<spawn>
and C<daemon>.

=head2 run

This should be the last call you make, which will cause your program to operate
like a Unix service from the command-line. (See L<Daemon::Control> for
additional details.)

=head1 PLUGINS

To do anything useful with a bot, you have to load plugins. You can do this
either by specifying a list of plugins with the C<plugins> key passed to
C<new()> or by calling C<load()>.

Plugins are just simple packages (or optionally a hashref, but more on that
later). The only requirement for plugins is that they provide an C<init()>
method. This will get called by the bot prior to forking its worker children.
It will be passed the bot object. Within C<init()>, you can call any number of
plugin methods (see the list of methods below) to setup desired functionality.

    package Your::Plugin;
    use strict;
    use warnings;

    sub init {
        my ($bot) = @_;

        $bot->hook(
            {
                to_me => 1,
                text  => qr/\b(?<word>w00t|[l1][e3]{2}[t7])\b/i,
            },
            sub {
                my ( $bot, $in, $m ) = @_;
                $bot->reply("$in->{nick}, don't use the word: $m->{word}.");
            },
        );
    }

    1;

When you load plugins, you can specify their packages a few different ways. When
attempting to load a plugin, the bot will start by looking for the name you
provided as a sub-class of itself. Then it will look for the plugin under the
assumption you provided it's full name.

    plugins => [
        'Store',           # matches "Bot::IRC::Store"
        'Random',          # matches "Bot::IRC::X::Random"
        'Thing',           # matches "Bot::IRC::Y::Thing"
        'My::Own::Plugin', # matches "My::Own::Plugin"
    ],

An unenforced convention for public/shared plugins is to have non-core plugins
(all plugins not provided directly by this CPAN library) subclasses of
"Bot::IRC::X". For private/unshared plugins, you can specify whatever name you
want, but maybe consider something like "Bot::IRC::Y". Plugins set in the X or
Y subclass namespaces will get matched just like core plugins. "Y" plugins will
have precedence over "X" which in turn will have precedence over core.

If you need to allow for variables to get passed to your plugins, an unenforced
convention is to do so via the C<vars> key to C<new()>.

=head1 PLUGIN METHODS

The following are methods available from this class related to plugins.

=head2 load

This method loads plugins. It is the exact equivalent of passing strings to the
C<plugins> key in C<new()>. If a plugin has already been loaded, it'll get
skipped.

    my $bot = Bot::IRC->new(
        connect => { server => 'irc.perl.org' },
        plugins => [ 'Store', 'Infobot', 'Karma' ],
    );

    $bot->load( 'Infobot', 'Seen' );

From within your plugins, you can call C<load()> to specify plugin dependencies
in your plugins.

    sub init {
        my ($bot) = @_;
        $bot->load('Dependency');
    }

=head2 reload

If you need to actually reload a plugin, call C<reload>. It operates in the same
was as C<load>, only it won't skip already-loaded plugins.

=head2 hook

This is the method you'll call to add a hook, which is basically a message
response handler. A hook includes a conditions trigger, some code to run
when the trigger fires, and an optional additional attributes hashref.

    $bot->hook(
        {
            to_me => 1,
            text  => qr/\b(?<word>w00t|[l1][e3]{2}[t7])\b/i,
        },
        sub {
            my ( $bot, $in, $m ) = @_;
            $bot->reply("$in->{nick}, don't use the word: $m->{word}.");
        },
        {
            priority => 42,
            subs     => [],
            helps    => [],
        },
    );

The conditions trigger is a hashref of key-value pairs where the key is a
component of the message and the value is either a value to exact match or a
regular expression to match.

The code block will receive a copy of the bot, a hashref of key-value pairs
representing the message the hook is responding to, and an optionally-available
hashref of any named matches from the regexes in the trigger.

The hashref representing the message the hook will have the following keys:

=for :list
* C<text>: text component of the message
* C<command>: IRC "command" like PRIVMSG, MODE, etc.
* C<forum>: origin location like #channel or the nick who privately messaged
* C<private>: 1 or 0 representing if the message is private or in a channel
* C<to_me>: 1 or 0 representing if the message is addressing the bot or not
* C<nick>: nick of the sender of the message
* C<source>: the source server's label/name
* C<user>: username of the sender of the message
* C<server>: server of the sender of the message
* C<line>: full message line/text

B<The return value from the code block is important.> If you return a positive
value, all additional hooks are skipped because it will be assumed that this
hook properly responded to the message and no additional work needs to be done.
If the code block returns a false value, additional hooks will be checked as if
this hook's trigger caused the code block to be skipped.

The optional additional attributes hashref supports a handful of keys. The
C<priority> value is used to sort the global set of hooks. The value is expected
to be an integer value. The higher value priority hooks are sorted first.
You can also specify C<subs> and C<helps>, which are exactly equivalent to
calling C<subs()> and C<helps()>. (See below.)

=head2 hooks

This method accepts a list of arrayrefs, each containing a trigger, code, and
attribute value and calls C<hook> for each set.

    $bot->hooks(
        [ {}, sub {}, {} ],
        [ {}, sub {}, {} ],
    );

=head2 helps

This method is how you'd setup any help text you'd like the bot to provide to
users. It expects some number of key-value pairs where the key is the topic
title of the set of functionality and the value is the string of instructions.

    $bot->helps(
        seen => 'Tracks when and where people were seen. Usage: seen <nick>, hide, unhide.',
        join => 'Join and leave channels. Usage: join <channel>, leave <channel>, channels.',
    );

In the example above, let's say your bot had the nick of "bot" and you were in
the same channel as your bot and you typed "bot, help" in your IRC channel. The
bot would respond with a list of available  topics. Then if you typed "bot, help
seen" in the channel, the bot would reply with the "seen" string of
instructions. If typing directly to the bot (in a private message directly to
the bot), you don't need to specify the bot's name.

=head2 tick

Sometimes you'll want the bot to do something at a specific time or at some sort
of interval. You can cause this to happen by filing ticks. A tick is similar to
a hook in that it's a bit of code that gets called, but not based on a message
but based on time. C<tick()> expects two values. The first is either an integer
representing the number of seconds of interval between calls to the code or a
crontab-like time expression. The second value is the code to call, which will
receive a copy of the bot object.

    $bot->tick(
        10,
        sub {
            my ($bot) = @_;
            $bot->msg( '#test', '10-second interval.' );
        },
    );

    $bot->tick(
        '0 0 * * *',
        sub {
            my ($bot) = @_;
            $bot->msg( '#test', "It's midnight!" );
        },
    );

=head2 ticks

This method accepts a list of arrayrefs, each containing a time value and code
block and calls C<tick> for each set.

    $bot->ticks(
        [ 10,          sub {} ],
        [ '0 0 * * *', sub {} ],
    );

=head2 subs

A plugin can also provide functionality to the bot for use in other plugins.
It can also override core methods of the bot. You do this with the C<subs()>
method.

    $bot->subs(
        incr => sub {
            my ( $bot, $int ) = @_;
            return ++$int;
        },
    );

    my $value = $bot->incr(42); # value is 43

=head2 register

There are rare cases when you're writing your plugin where you want to claim
that your plugin satisfies the requirements for a different plugin. In other
words, you want to prevent the future loading of a specific plugin or plugins.
You can do this by calling C<register()> with the list of plugins (by full
namespace) that you want to skip.

    $bot->register('Bot::IRC::Storage');

Note that this will not block the reloading of plugins with C<reload()>.

=head1 INLINE PLUGINS

You can optionally inject inline plugins by providing them as hashref. This
works both with C<load()> and the C<plugins> key.

    $bot->load(
        {
            hooks => [ [ {}, sub {}, {} ], [ {}, sub {}, {} ] ],
            ticks => [ [ 10, sub {} ], [ '0 0 * * *', sub {} ] ],
            helps => { title => 'Description.' },
            subs  => { name => sub {} },
        },
        {
            hooks => [ [ {}, sub {}, {} ], [ {}, sub {}, {} ] ],
            ticks => [ [ 10, sub {} ], [ '0 0 * * *', sub {} ] ],
            helps => { title => 'Description.' },
            subs  => { name => sub {} },
        },
    );

=head1 OPERATIONAL METHODS

The following are operational methods available from this class, expected to be
used inside various code blocks passed to plugin methds.

=head2 reply

If you're inside a hook, you can usually respond to most messages with the
C<reply()> method, which accepts the text the bot should reply with. The method
returns the bot object.

    $bot->reply('This is a reply. Impressive, huh?');

If you want to emote something back or use any other IRC command, type it just
as you would in your IRC client.

    $bot->reply('/me feels something, which for a bot is rather impressive.');

=head2 msg

Use C<msg()> when you don't have a forum to reply to or want to reply in a
different forum (i.e. to a different user or channel). The method accepts the
forum for the message and the message text.

    $bot->msg( '#test', 'This is a message for everybody in #test.');

=head2 say

Use C<say()> to write low-level lines to the IRC server. The method expects a
string that's a properly IRC message.

    $bot->say('JOIN #help');
    $bot->say('PRIVMSG #help :I need some help.');

=head2 nick

Use C<nick> to change the bot's nick. If the nick is already in use, the bot
will try appending "_" to it until it finds an open nick.

=head2 join

Use C<join()> to join channels.

    $bot->join('#help');

If some sort of persistent storage plugin is loaded, the bot will remember the
channels it has joined or parted and use that as it's initial join on restart.

=head2 part

Use C<part()> to part channels.

    $bot->part('#help');

If some sort of persistent storage plugin is loaded, the bot will remember the
channels it has joined or parted and use that as it's initial join on restart.

=head1 SEE ALSO

You can look for additional information at:

=for :list
* L<GitHub|https://github.com/gryphonshafer/Bot-IRC>
* L<CPAN|http://search.cpan.org/dist/Bot-IRC>
* L<MetaCPAN|https://metacpan.org/pod/Bot::IRC>
* L<AnnoCPAN|http://annocpan.org/dist/Bot-IRC>
* L<Travis CI|https://travis-ci.org/gryphonshafer/Bot-IRC>
* L<Coveralls|https://coveralls.io/r/gryphonshafer/Bot-IRC>
* L<CPANTS|http://cpants.cpanauthors.org/dist/Bot-IRC>
* L<CPAN Testers|http://www.cpantesters.org/distro/T/Bot-IRC.html>

=cut
