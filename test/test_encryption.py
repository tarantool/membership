#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302]


def check_status(srv, uri, status):
    member = srv.members()[uri]
    assert member['status'] == status


def test_join(servers, helpers):
    assert servers[13301].add_member('localhost:13302')
    assert servers[13301].conn.eval('return membership.get_encryption_key()')[0] is None

    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'alive'])
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'alive'])


def test_enable_encryption(servers, helpers):
    servers[13302].conn.eval('return membership.set_encryption_key("XXXXXX")')
    assert servers[13302].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                          XXXXXX"
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'non-decryptable'], timeout=5)
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'non-decryptable'], timeout=5)

    servers[13301].conn.eval('return membership.set_encryption_key("XXXXXX")')
    assert servers[13301].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                          XXXXXX"
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'alive'])
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'alive'])

    servers[13302].conn.eval('return membership.leave()')
    check_status(servers[13301], 'localhost:13302', 'left')

    servers[13302].conn.eval("""
        assert(membership.init("localhost", 13302))
        assert(membership.probe_uri("localhost:13301"))
    """)
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'alive'])


def test_change_encryption(servers, helpers):
    servers[13301].conn.eval('return membership.set_encryption_key("YY")')
    assert servers[13301].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                              YY"
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'non-decryptable'])
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'non-decryptable'])

    servers[13302].conn.eval('return membership.set_encryption_key("YY")')
    assert servers[13302].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                              YY"
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'alive'])
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'alive'])


def test_disable_encryption(servers, helpers):
    servers[13302].conn.eval('return membership.set_encryption_key(nil)')
    assert servers[13302].conn.eval(
        'return membership.get_encryption_key()')[0] is None
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'non-decryptable'])
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'non-decryptable'])

    servers[13301].conn.eval('return membership.set_encryption_key(nil)')
    assert servers[13301].conn.eval(
        'return membership.get_encryption_key()')[0] is None
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'alive'])
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'alive'])
