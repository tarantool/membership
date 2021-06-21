#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302]


def test_join(servers, helpers):
    assert servers[13301].add_member('localhost:13302')
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])


def test_death(servers, helpers):
    servers[13302].kill()
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'suspect'])
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'dead'])

    servers[13302].start()
    helpers.wait_for(servers[13302].connect)
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'alive'])
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])


def test_reinit(servers, helpers):
    assert servers[13301].add_member('localhost:13302')
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])

    # Change hostname
    cmd = "return membership.init('127.0.0.1', 13301)"
    assert servers[13301].conn.eval(cmd)[0]
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'dead'])
    helpers.wait_for(servers[13302].check_status, ['127.0.0.1:13301', 'alive'])

    # Change port
    cmd = "return membership.init('127.0.0.1', 13303)"
    assert servers[13301].conn.eval(cmd)[0]
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'dead'])
    helpers.wait_for(servers[13302].check_status, ['127.0.0.1:13301', 'dead'])
    helpers.wait_for(servers[13302].check_status, ['127.0.0.1:13303', 'alive'])

    # Revert all changes
    cmd = "return membership.init('localhost', 13301)"
    assert servers[13301].conn.eval(cmd)[0]
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'alive'])
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])


def test_error(servers, helpers):
    cmd = "return membership.init('localhost', 13302)"
    assert servers[13301].conn.eval(cmd)[0] == \
        {'error': 'Socket bind error (13302/udp): Address already in use'}

    assert servers[13301].probe_uri('localhost:13301') is True
    assert servers[13301].probe_uri('localhost:13302') is True
    assert servers[13302].probe_uri('localhost:13301') is True
