# NAME

Bot::IRC - Yet Another IRC Bot

# VERSION

version 1.36

[![test](https://github.com/gryphonshafer/Bot-IRC/workflows/test/badge.svg)](https://github.com/gryphonshafer/Bot-IRC/actions?query=workflow%3Atest)
[![codecov](https://codecov.io/gh/gryphonshafer/Bot-IRC/graph/badge.svg)](https://codecov.io/gh/gryphonshafer/Bot-IRC)

# SYNOPSIS

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
            ipv6   => 0,
        },
        plugins => [
            ':core',
        ],
        vars => {
            store => 'bot.yaml',
        },
        send_user_nick => 'on_parent', # or 'on_connect' or 'on_reply'
    );

    $bot->load( 'Infobot', 'Karma' );

    ## Example inline plugin structure
    # $bot->load({
    #     hooks => [ [ {}, sub {}, {} ] ],
    #     helps => { name => 'String' },
    #     subs  => { name => sub {} },
    #     ticks => [ [ '0 * * * *', sub {} ] ],
    # });

    $bot->run;

# DESCRIPTION

Yet another IRC bot. Why? There are so many good bots and bot frameworks to
select from, but I wanted a bot framework that worked like a Unix service
out-of-the-box, operated in a pre-fork way to serve multiple concurrent
requests, and has a dirt-simple and highly extendable plugin mechanism. I also
wanted to keep the direct dependencies and core bot minimalistic, allowing as
much functionality as possible to be defined as optional plugins.

## Minimal Bot

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
reload, status, help, and so on. (See [Daemon::Control](https://metacpan.org/pod/Daemon%3A%3AControl) for more details.)

## Pre-Forking Device

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

(See [Daemon::Device](https://metacpan.org/pod/Daemon%3A%3ADevice) for more details.)

# MAIN METHODS

The following are the main or primary available methods from this class.

## new

This method instantiates a bot object that's potentially ready to start running.
All bot settings can be specified to the `new()` constructor, but some can be
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
            ipv6   => 0,
        },
        plugins => [],
        vars    => {},
    )->run;

`spawn` will default to 2. Under `connect`, `port` will default to 6667.
`join` can be either a string or an arrayref of strings representing channels
to join after connnecting. `ssl` is a true/false setting for whether to
connect to the server over SSL. `ipv6` is also true/false setting for whether
to forcibly connect to the server over IPv6.

You can optionally also provide an `encoding` string representing a strict name
of an encoding standard. If you don't set this, it will default to "UTF-8"
internally. The encoding string is used to set the binmode for log files and for
message text decoding as necessary. If you want to turn off this functionality,
set `encoding` to any defined false value.

Read more about plugins below for more information about `plugins` and `vars`.
Consult [Daemon::Device](https://metacpan.org/pod/Daemon%3A%3ADevice) and [Daemon::Control](https://metacpan.org/pod/Daemon%3A%3AControl) for more details about `spawn`
and `daemon`.

There's also an optional `send_user_nick` parameter, which you probably won't
need to use, which defines when the bot will send the `USER` and initial
`NICK` commands to the IRC server. There are 3 options: `on_connect`,
`on_parent` (the default), and `on_reply`. `on_connect` sends the `USER`
and initial `NICK` immediately upon establishing a connection to the IRC
server, prior to the parent runtime loop and prior to children creation.
`on_parent` (the default) sends the 2 commands within the parent runtime loop
prior to any responses from the IRC server. `on_reply` (the only option in
versions <= 1.23 of this module) sends the 2 commands after the IRC server
replies with some sort of content after connection.

## run

This should be the last call you make, which will cause your program to operate
like a Unix service from the command-line. (See [Daemon::Control](https://metacpan.org/pod/Daemon%3A%3AControl) for
additional details.)

`run` can optionally be passed a list of strings that will be executed after
connection to the IRC server. These should be string commands similar to what
you'd type in an IRC client. For example:

    Bot::IRC->new( connect => { server => 'irc.perl.org' } )->run(
        '/msg nickserv identify bot_password',
        '/msg operserv identify bot_password',
        '/oper bot_username bot_password',
        '/msg chanserv identify #bot_talk bot_password',
        '/join #bot_talk',
        '/msg chanserv op #bot_talk',
    );

# PLUGINS

To do anything useful with a bot, you have to load plugins. You can do this
either by specifying a list of plugins with the `plugins` key passed to
`new()` or by calling `load()`.

Plugins are just simple packages (or optionally a hashref, but more on that
later). The only requirement for plugins is that they provide an `init()`
method. This will get called by the bot prior to forking its worker children.
It will be passed the bot object. Within `init()`, you can call any number of
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
convention is to do so via the `vars` key to `new()`.

## Core Plugins

If you specify ":core" as a plugin name, it will be expanded to load all the
core plugins. Core plugins are all the plugins that are bundled and
distributed with [Bot::IRC](https://metacpan.org/pod/Bot%3A%3AIRC).

- [Bot::IRC::Ping](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3APing)
- [Bot::IRC::Join](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3AJoin)
- [Bot::IRC::Seen](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3ASeen)
- [Bot::IRC::Greeting](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3AGreeting)
- [Bot::IRC::Infobot](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3AInfobot)
- [Bot::IRC::Functions](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3AFunctions)
- [Bot::IRC::Convert](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3AConvert)
- [Bot::IRC::Karma](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3AKarma)
- [Bot::IRC::Math](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3AMath)
- [Bot::IRC::History](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3AHistory)

Some core plugins require a storage plugin. If you don't specify one in your
plugins list, then the default [Bot::IRC::Store](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3AStore) will be used, which is
probably not what you want (for performance reasons). Try
[Bot::IRC::Store::SQLite](https://metacpan.org/pod/Bot%3A%3AIRC%3A%3AStore%3A%3ASQLite) instead.

    plugins => [
        'Store::SQLite',
        ':core',
    ],

# PLUGIN METHODS

The following are methods available from this class related to plugins.

## load

This method loads plugins. It is the exact equivalent of passing strings to the
`plugins` key in `new()`. If a plugin has already been loaded, it'll get
skipped.

    my $bot = Bot::IRC->new(
        connect => { server => 'irc.perl.org' },
        plugins => [ 'Store', 'Infobot', 'Karma' ],
    );

    $bot->load( 'Infobot', 'Seen' );

From within your plugins, you can call `load()` to specify plugin dependencies
in your plugins.

    sub init {
        my ($bot) = @_;
        $bot->load('Dependency');
    }

## reload

If you need to actually reload a plugin, call `reload`. It operates in the same
was as `load`, only it won't skip already-loaded plugins.

## hook

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
            subs  => [],
            helps => [],
        },
    );

The conditions trigger is a hashref of key-value pairs where the key is a
component of the message and the value is either a value to exact match or a
regular expression to match.

The code block will receive a copy of the bot, a hashref of key-value pairs
representing the message the hook is responding to, and an optionally-available
hashref of any named matches from the regexes in the trigger.

The hashref representing the message the hook will have the following keys:

- `text`: text component of the message
- `command`: IRC "command" like PRIVMSG, MODE, etc.
- `forum`: origin location like #channel or the nick who privately messaged
- `private`: 1 or 0 representing if the message is private or in a channel
- `to_me`: 1 or 0 representing if the message is addressing the bot or not
- `nick`: nick of the sender of the message
- `source`: the source server's label/name
- `user`: username of the sender of the message
- `server`: server of the sender of the message
- `line`: full message line/text
- `full_text`: text component of the message with nick included

**The return value from the code block is important.** If you return a positive
value, all additional hooks are skipped because it will be assumed that this
hook properly responded to the message and no additional work needs to be done.
If the code block returns a false value, additional hooks will be checked as if
this hook's trigger caused the code block to be skipped.

The optional additional attributes hashref supports a handful of keys.
You can specify `subs` and `helps`, which are exactly equivalent to
calling `subs()` and `helps()`. (See below.)

## hooks

This method accepts a list of arrayrefs, each containing a trigger, code, and
attribute value and calls `hook` for each set.

    ## Example hooks call structure
    # $bot->hooks(
    #     [ {}, sub {}, {} ],
    #     [ {}, sub {}, {} ],
    # );

## helps

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

## tick

Sometimes you'll want the bot to do something at a specific time or at some sort
of interval. You can cause this to happen by filing ticks. A tick is similar to
a hook in that it's a bit of code that gets called, but not based on a message
but based on time. `tick()` expects two values. The first is either an integer
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

## ticks

This method accepts a list of arrayrefs, each containing a time value and code
block and calls `tick` for each set.

    $bot->ticks(
        [ 10,          sub {} ],
        [ '0 0 * * *', sub {} ],
    );

## subs

A plugin can also provide functionality to the bot for use in other plugins.
It can also override core methods of the bot. You do this with the `subs()`
method.

    $bot->subs(
        incr => sub {
            my ( $bot, $int ) = @_;
            return ++$int;
        },
    );

    my $value = $bot->incr(42); # value is 43

## register

There are rare cases when you're writing your plugin where you want to claim
that your plugin satisfies the requirements for a different plugin. In other
words, you want to prevent the future loading of a specific plugin or plugins.
You can do this by calling `register()` with the list of plugins (by full
namespace) that you want to skip.

    $bot->register('Bot::IRC::Storage');

Note that this will not block the reloading of plugins with `reload()`.

## vars

When you are within a plugin, you can call `vars()` to get the variables for
the plugin by it's lower-case "simplified" name, which is the plugin's class
name all lower-case, without the preceding "Bot::IRC::" bit, and with "::"s
replaced with dashes. For example, let's say you were writing a
"Bot::IRC::X::Something" plugin. You would have users set variables in their
instantiation like so:

    Bot::IRC->new
        plugins => ['Something'],
        vars    => { x-something => { answer => 42 } },
    )->run;

Then from within the "Bot::IRC::X::Something" plugin, you would access these
variables like so:

    my $my_vars = $bot->vars;
    say 'The answer to life, the universe, and everything is ' . $my_vars->{answer};

If you want to access the variables for a different namespace, pass into
`vars()` the "simplified" name you want to access.

    my $my_other_vars = $bot->vars('x-something-else');

## settings

If you need access to the bot's settings, you can do so with `settings()`.
Supply the setting name/key to get that setting, or provide no name/key to get
all settings as a hashref.

    my $connection_settings_hashref = $bot->settings('connect');

# INLINE PLUGINS

You can optionally inject inline plugins by providing them as hashref. This
works both with `load()` and the `plugins` key.

    ## Example inline plugin structure
    # $bot->load(
    #     {
    #         hooks => [ [ {}, sub {}, {} ], [ {}, sub {}, {} ] ],
    #         ticks => [ [ 10, sub {} ], [ '0 0 * * *', sub {} ] ],
    #         helps => { title => 'Description.' },
    #         subs  => { name => sub {} },
    #     },
    #     {
    #         hooks => [ [ {}, sub {}, {} ], [ {}, sub {}, {} ] ],
    #         ticks => [ [ 10, sub {} ], [ '0 0 * * *', sub {} ] ],
    #         helps => { title => 'Description.' },
    #         subs  => { name => sub {} },
    #     },
    # );

# OPERATIONAL METHODS

The following are operational methods available from this class, expected to be
used inside various code blocks passed to plugin methds.

## reply

If you're inside a hook, you can usually respond to most messages with the
`reply()` method, which accepts the text the bot should reply with. The method
returns the bot object.

    $bot->reply('This is a reply. Impressive, huh?');

If you want to emote something back or use any other IRC command, type it just
as you would in your IRC client.

    $bot->reply('/me feels something, which for a bot is rather impressive.');

## reply\_to

`reply_to` is exactly like `reply` except that if the forum for the reply is
a channel instead of to a specific person, the bot will prepend the message
by addressing the nick who was the source of the response the bot is responding
to.

## msg

Use `msg()` when you don't have a forum to reply to or want to reply in a
different forum (i.e. to a different user or channel). The method accepts the
forum for the message and the message text.

    $bot->msg( '#test', 'This is a message for everybody in #test.');

## say

Use `say()` to write low-level lines to the IRC server. The method expects a
string that's a properly IRC message.

    $bot->say('JOIN #help');
    $bot->say('PRIVMSG #help :I need some help.');

## nick

Use `nick` to change the bot's nick. If the nick is already in use, the bot
will try appending "\_" to it until it finds an open nick.

## join

Use `join()` to join channels.

    $bot->join('#help');

If some sort of persistent storage plugin is loaded, the bot will remember the
channels it has joined or parted and use that as it's initial join on restart.

## part

Use `part()` to part channels.

    $bot->part('#help');

If some sort of persistent storage plugin is loaded, the bot will remember the
channels it has joined or parted and use that as it's initial join on restart.

# RANDOM HELPFUL METHODS

The following are random additional methods that might be helpful in your
plugins.

## list

This method is a simple string method that takes a list and crafts it for
readability. It expects a separator string, a final item conjunction string,
and a list of items.

    $bot->list( ', ', 'and', 'Alpha', 'Beta', 'Delta', 'Gamma' );
    # returns "Alpha, Beta, Delta, and Gamma"

    $bot->list( ', ', 'and', 'Alpha', 'Beta' );
    # returns "Alpha and Beta"

## health

This method returns a hashref of simple key value pairs for different "health"
aspects (or current state) of the bot. It includes things like server and port
connection, number of children, and so on.

## note

While in theory you shouldn't ever need to use it, there is a method called
"note" which is a handler for writing to the log and error files. If you
`warn` or `die`, this handler steps in automatically. If you'd like to
`print` to STDOUT, which you really shouldn't need to do, then it's best to
call this method instead. The reason being is that the log file is designed to
be parsed in a specific way. If you write whatever you want to it, it will
corrupt the log file. That said, if you really, really want to, here's how you
use `note`:

    $bot->note('Message');           # writes a message to the log file
    $bot->note( 'Message', 'warn' ); # writes a message to the error file
    $bot->note( 'Message', 'die' );  # writes a message to the error file the dies

# SEE ALSO

You can look for additional information at:

- [GitHub](https://github.com/gryphonshafer/Bot-IRC)
- [MetaCPAN](https://metacpan.org/pod/Bot::IRC)
- [GitHub Actions](https://github.com/gryphonshafer/Bot-IRC/actions)
- [Codecov](https://codecov.io/gh/gryphonshafer/Bot-IRC)
- [CPANTS](http://cpants.cpanauthors.org/dist/Bot-IRC)
- [CPAN Testers](http://www.cpantesters.org/distro/T/Bot-IRC.html)

# AUTHOR

Gryphon Shafer <gryphon@cpan.org>

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2016-2021 by Gryphon Shafer.

This is free software, licensed under:

    The Artistic License 2.0 (GPL Compatible)
