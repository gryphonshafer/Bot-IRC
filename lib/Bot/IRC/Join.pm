package Bot::IRC::Join;
# ABSTRACT: Bot::IRC Join and Part Channels; Remember State

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
                $bot->reply( '"' . $m->{channel} . q{" doesn't appear to be a channel I can join.} );
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
                $bot->reply( 'I will depart: ' . $m->{channel} );
                $bot->part( $m->{channel} );
            }
            else {
                $bot->reply( '"' . $m->{channel} . q{" doesn't appear to be a valid channel name.} );
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
            my @channels = @{ $bot->store->get('join') || [] };

            $bot->reply(
                (@channels)
                    ? 'I am currently in the following channels: ' .
                        $bot->list( ', ', 'and', sort { $a cmp $b } @channels ) . '.'
                    : 'I am currently not in any channels.'
            );
        },
    );

    $bot->helps(
        join => 'Join and part channels. Usage: join <channel>, part <channel>, channels.',
    );

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
            my %joined   = map { $_ => 1 } @{ $bot->store->get('join') || [] };
            @channels    = keys %joined unless (@channels);

            $bot->join_super(@channels);

            $joined{$_} = 1 for (@channels);
            $bot->store->set( 'join' => [ keys %joined ] );
        },
    );

    $bot->subs(
        part => sub {
            my $bot    = shift;
            my %joined = map { $_ => 1 } @{ $bot->store->get('join') || [] };

            $bot->part_super(@_);

            delete $joined{$_} for (@_);
            $bot->store->set( 'join' => [ keys %joined ] );
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

    join <channel>
    part <channel>

=for Pod::Coverage init

=cut
