package Bot::IRC::Store;
use strict;
use warnings;
use YAML::XS qw( LoadFile DumpFile );

sub init {
    my ($bot) = @_;
    my $obj = __PACKAGE__->new($bot);

    $bot->subs( 'store' => sub { return $obj } );
}

sub new {
    my ( $class, $bot ) = @_;
    my $self = bless( {}, $class );
    $self->file( $bot->{store} || 'store.yaml' );
    return $self;
}

sub file {
    my ( $self, $file ) = @_;

    if ( defined $file ) {
        DumpFile( $file, {} ) unless ( -f $file );
        $self->{file} = $file;
    }

    return $self->{file};
}

sub get {
    my ( $self, $key ) = @_;
    return LoadFile( $self->{file} )->{ ( caller() )[0] }{$key};
}

sub set {
    my ( $self, $key, $value ) = @_;

    my $data = LoadFile( $self->{file} );
    $data->{ ( caller() )[0] }{$key} = $value;

    DumpFile( $self->{file}, $data );
    return $self;
}

1;
