use strict;
use warnings;

use Test::Most;

use constant MODULE => 'Bot::IRC';

BEGIN { use_ok(MODULE); }
require_ok(MODULE);

throws_ok( sub { MODULE->new }, qr|connect/server not provided|, MODULE . '->new dies' );
lives_ok( sub { MODULE->new(
    connect => { server => 'irc.perl.org' }
) }, MODULE . '->new( connect => { server => $server } )' );

done_testing;
