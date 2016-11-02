#!/usr/bin/env perl
use Modern::Perl '2015';
use lib 'lib';
use Bot::IRC;

my $bot = Bot::IRC->new(
    spawn  => 3,
    daemon => {
        name        => 'bot',
        lsb_sdesc   => 'IRC Bot',
        pid_file    => 'bot.pid',
        stderr_file => 'bot.err',
        stdout_file => 'bot.log',
    },
    connect => {
        server => 'irc.perl.org',
        port   => '6667',
        nick   => 'bot',
        name   => 'Yet Another IRC Bot',
        join   => '#test',
        ssl    => 0,
    },
    plugins => [ qw( Store ) ],
    store   => 'bot.yaml',
)->run;
