package Bot::IRC::Join;
# ABSTRACT: Bot::IRC join and part channels and remember channels state

use strict;
use warnings;

# VERSION

sub init {
    my ($bot) = @_;
    $bot->load('Store');

    $bot->hook(
        {
            to_me => 1,
            text  => qr/\bjoin\s+(?<channel>\S+)/i,
        },
        sub {
            my ( $bot, $in, $m ) = @_;

            if ( $m->{channel} =~ /^#\w+$/ ) {
                $bot->reply( 'I will attempt to join: ' . $m->{channel} );
                $bot->join( $m->{channel} );
            }
            else {
                $bot->reply_to( '"' . $m->{channel} . q{" doesn't appear to be a channel I can join.} );
            }
        },
    );

    $bot->hook(
        {
            to_me => 1,
            text  => qr/\b(?:part|leave)\s+(?<channel>\S+)/i,
        },
        sub {
            my ( $bot, $in, $m ) = @_;

            if ( $m->{channel} =~ /^#\w+$/ ) {
                $bot->reply_to( 'I will depart: ' . $m->{channel} );
                $bot->part( $m->{channel} );
            }
            else {
                $bot->reply_to( '"' . $m->{channel} . q{" doesn't appear to be a valid channel name.} );
            }
        },
    );

    $bot->hook(
        {
            to_me => 1,
            text  => qr/\bchannels\b/i,
        },
        sub {
            my ($bot)    = @_;
            my @channels = @{ $bot->store->get('channels') || [] };

            $bot->reply_to(
                (@channels)
                    ? 'I am currently in the following channels: ' .
                        $bot->list( ', ', 'and', sort { $a cmp $b } @channels ) . '.'
                    : 'I am currently not in any channels.'
            );
        },
    );

    $bot->helps( join => 'Join and part channels. Usage: join <channel>, part <channel>, channels.' );

    {
        no strict 'refs';
        for ( qw( join part ) ) {
            my $name = ref($bot) . '::' . $_;
            *{ $name . '_super' } = *$name{CODE};
        }
    }

    $bot->subs(
        join => sub {
            my $bot      = shift;
            my @channels = @_;
            my %channels = map { $_ => 1 } @{ $bot->store->get('channels') || [] };
            @channels    = keys %channels unless (@channels);

            if ( not @channels and $bot->{connect}{join} ) {
                @channels = ( ref $bot->{connect}{join} eq 'ARRAY' )
                    ? @{ $bot->{connect}{join} }
                    : $bot->{connect}{join}
            }

            $bot->join_super(@channels);

            $channels{$_} = 1 for (@channels);
            $bot->store->set( 'channels' => [ keys %channels ] );

            return $bot;
        },
    );

    $bot->subs(
        part => sub {
            my $bot    = shift;
            my %channels = map { $_ => 1 } @{ $bot->store->get('channels') || [] };

            $bot->part_super(@_);

            delete $channels{$_} for (@_);
            $bot->store->set( 'channels' => [ keys %channels ] );

            return $bot;
        },
    );
}

1;
__END__
=pod

=head1 SYNOPSIS

    use Bot::IRC;

    Bot::IRC->new(
        connect => { server => 'irc.perl.org' },
        plugins => ['Join'],
    )->run;

=head1 DESCRIPTION

This L<Bot::IRC> plugin handles messages instructing the bot to join or
part channels. Tell the bot to join and part channels as such:

=head2 join <channel>

Join a given channel.

=head2 part <channel>

Depart a given channel.

=head2 SEE ALSO

L<Bot::IRC>

=for Pod::Coverage init

=cut
