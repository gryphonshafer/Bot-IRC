package Bot::IRC::Store::SQLite;
# ABSTRACT: Bot::IRC Persistent Data Storage with SQLite

use strict;
use warnings;

use DBI;
use DBD::SQLite;
use JSON::XS;

# VERSION

sub init {
    my ($bot) = @_;
    my $obj = __PACKAGE__->new($bot);

    $bot->subs( 'store' => sub { return $obj } );
    $bot->register('Bot::IRC::Store');
}

sub new {
    my ( $class, $bot ) = @_;
    my $self = bless( {}, $class );

    $self->{file} = $bot->{vars}{store} || 'store.sqlite';
    my $pre_exists = ( -f $self->{file} ) ? 1 : 0;

    $self->{dbh} = DBI->connect( 'dbi:SQLite:dbname=' . $self->{file} ) or die "$@\n";

    $self->{dbh}->do(q{
        CREATE TABLE IF NOT EXISTS bot_store (
            id INTEGER PRIMARY KEY ASC,
            namespace TEXT,
            key TEXT,
            value TEXT
        )
    }) unless ($pre_exists);

    $self->{json} = JSON::XS->new->ascii;

    return $self;
}

sub get {
    my ( $self, $key ) = @_;
    my $namespace = ( caller() )[0];

    my $sth = $self->{dbh}->prepare(q{
        INSERT INTO bot_store ( namespace, key, value ) VALUES ( ?, ?, ? )
    });
    $sth->execute( $namespace, $key );
    my $value = $sth->fetchrow_array;
    $value = $self->{json}->decode($value) if ($value);

    return $value;
}

sub set {
    my ( $self, $key, $value ) = @_;
    my $namespace = ( caller() )[0];

    $self->{dbh}->prepare(q{
        DELETE FROM bot_store WHERE namespace = ? AND key = ?
    })->execute( $namespace, $key );

    $self->{dbh}->prepare(q{
        INSERT INTO bot_store ( namespace, key, value ) VALUES ( ?, ?, ? )
    })->execute( $namespace, $key, $self->{json}->encode( { value => $value } ) );

    return $self;
}

1;
__END__
=pod

=head1 SYNOPSIS

    use Bot::IRC;

    Bot::IRC->new(
        connect => { server => 'irc.perl.org' },
        plugins => ['Store::SQLite'],
        vars    => { store => 'bot.sqlite' },
    )->run;

=head1 DESCRIPTION

This L<Bot::IRC> plugin provides a persistent storage mechanism with a SQLite
database file. By default, it's the "store.sqlite" file, but this can be changed
with the C<vars>, C<store> value.

=head1 EXAMPLE USE

This plugin adds a single sub to the bot object called C<store()>. Calling it
will return a storage object which itself provides C<get()> and C<set()>
methods. These operate just like you would expect.

=head2 set

    $bot->store->set( user => { nick => 'gryphon', score => 42 } );

=head2 get

    my $score = $bot->store->set('user')->{score};

=for Pod::Coverage init new

=cut
