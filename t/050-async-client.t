#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);
use lib qw(blib/lib blib/arch ../blib/lib ../blib/arch);

use constant PLAN       => 38;
use Test::More tests    => PLAN;
use Encode qw(decode encode);


BEGIN {
    # Подготовка объекта тестирования для работы с utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";

    use_ok 'DR::Tarantool::LLClient', 'tnt_connect';
    use_ok 'DR::Tarantool::StartTest';
    use_ok 'DR::Tarantool', ':constant';
    use_ok 'File::Spec::Functions', 'catfile';
    use_ok 'File::Basename', 'dirname', 'basename';
    use_ok 'AnyEvent';
    use_ok 'DR::Tarantool::AsyncClient';
}

my $cfg_dir = catfile dirname(__FILE__), 'test-data';
ok -d $cfg_dir, 'directory with test data';
my $tcfg = catfile $cfg_dir, 'llc-easy2.cfg';
ok -r $tcfg, $tcfg;

my $tnt = run DR::Tarantool::StartTest( cfg => $tcfg );

my $spaces = {
    0   => {
        name            => 'first_space',
        fields  => [
            {
                name    => 'id',
                type    => 'NUM',
            },
            {
                name    => 'name',
                type    => 'UTF8STR',
            },
            {
                name    => 'key',
                type    => 'NUM',
            },
            {
                name    => 'password',
                type    => 'STR',
            }
        ],
        indexes => {
            0   => 'id',
            1   => 'name',
            2   => [ 'key', 'password' ],
        },
    }
};

SKIP: {
    unless ($tnt->started and !$ENV{SKIP_TNT}) {
        diag $tnt->log unless $ENV{SKIP_TNT};
        skip "tarantool isn't started", PLAN - 9;
    }

    my $client;

    # connect
    for my $cv (condvar AnyEvent) {
        DR::Tarantool::AsyncClient->connect(
            port                    => $tnt->primary_port,
            reconnect_period        => 0.1,
            spaces                  => $spaces,
            cb      => sub {
                $client = shift;
                $cv->send;
            }
        );

        $cv->recv;
    }
    unless ( isa_ok $client => 'DR::Tarantool::AsyncClient' ) {
        diag eval { decode utf8 => $client } || $client;
        last;
    }



    # ping
    for my $cv (condvar AnyEvent) {
        $client->ping(
            sub {
                my ($status) = @_;
                cmp_ok $status, '~~', 'ok', '* ping';
                $cv->send;
            }
        );
        $cv->recv;
    }

    # insert
    for my $cv (condvar AnyEvent) {
        $cv->begin;
        $client->insert(
            'first_space',
            [
                10,
                'user',
                11,
                'password'
            ],
            TNT_FLAG_RETURN,
            sub {
                my ($status, $res) = @_;
                cmp_ok $status, '~~', 'ok', '* insert status';
                cmp_ok $res->id, '~~', 10, 'id';
                cmp_ok $res->name, '~~', 'user', 'name';
                cmp_ok $res->key, '~~', 11, 'key';
                cmp_ok $res->password, '~~', 'password', 'password';
                $cv->end;
            }
        );

        $cv->begin;
        $client->insert(
            'first_space',
            [
                10,
                'user',
                11,
                'password'
            ],
            TNT_FLAG_RETURN | TNT_FLAG_ADD,
            sub {
                my ($status, $code, $error) = @_;
                cmp_ok $status, '~~', 'error', 'status';
                ok $code, 'code';
                like $error, qr{exists}, 'tuple already exists';
                $cv->end;
            }
        );
        $cv->recv;
    }

    # call lua
    for my $cv (condvar AnyEvent) {
        $cv->begin;
        $client->call_lua(
            'box.select' => [ 0, 0, 10 ],
            fields  => [
                { type => 'NUM', name => 'a' },
                'b',
                { type => 'NUM', name => 'c'},
                'd'
            ],
            args    => [ 's', 'i', { type => 'NUM' } ],
            sub {
                my ($status, $tuple) = @_;
                cmp_ok $status, '~~', 'ok', '* call status';
                isa_ok $tuple => 'DR::Tarantool::Tuple', 'tuple packed';
                cmp_ok $tuple->a, '~~', 10, 'id';
                cmp_ok $tuple->b, '~~', 'user', 'name';
                cmp_ok $tuple->c, '~~', 11, 'key';
                $cv->end;
            }
        );
        $cv->begin;
        $client->call_lua(
            'box.select' => [ 0, 0, 10 ],
            space => 'first_space',
            args    => [ 's', 'i', { type => 'NUM' } ],
            sub {
                my ($status, $tuple) = @_;
                cmp_ok $status, '~~', 'ok', 'status';
                isa_ok $tuple => 'DR::Tarantool::Tuple', 'tuple packed';
                cmp_ok $tuple->id, '~~', 10, 'id';
                cmp_ok $tuple->name, '~~', 'user', 'name';
                cmp_ok $tuple->key, '~~', 11, 'key';
                cmp_ok $tuple->password, '~~', 'password', 'password';
                $cv->end;
            }
        );
        $cv->begin;
        $client->call_lua(
            'box.select' => [ 0, 0, pack 'L<' => 10 ],
            'first_space',
            sub {
                my ($status, $tuple) = @_;
                cmp_ok $status, '~~', 'ok', 'status';
                isa_ok $tuple => 'DR::Tarantool::Tuple', 'tuple packed';
                cmp_ok $tuple->id, '~~', 10, 'id';
                cmp_ok $tuple->name, '~~', 'user', 'name';
                cmp_ok $tuple->key, '~~', 11, 'key';
                cmp_ok $tuple->password, '~~', 'password', 'password';
                $cv->end;
            }
        );
        $cv->begin;
        $client->call_lua(
            'box.select' => [ 0, 0, pack 'L<' => 11 ],
            'first_space',
            sub {
                my ($status, $tuple) = @_;
                cmp_ok $status, '~~', 'ok', 'status';
                cmp_ok $tuple, '~~', undef, 'there is no tuple';
                $cv->end;
            }
        );

        $cv->recv;
    }
}


