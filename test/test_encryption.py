#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302]


def test_join(servers, helpers):
    assert servers[13301].add_member('localhost:13302')
    assert servers[13301].conn.eval('return membership.get_encryption_key()')[0] is None

    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'alive'])


def test_enable_encryption(servers, helpers):
    servers[13302].conn.eval('return membership.set_encryption_key("XXXXXX")')
    assert servers[13302].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                          XXXXXX"
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'non-decryptable'], timeout=5)
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'non-decryptable'], timeout=5)

    servers[13301].conn.eval('return membership.set_encryption_key("XXXXXX")')
    assert servers[13301].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                          XXXXXX"
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'alive'])
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])

    servers[13302].conn.eval('return membership.leave()')
    servers[13301].check_status('localhost:13302', 'left')

    servers[13302].conn.eval("""
        assert(membership.init("localhost", 13302))
        assert(membership.probe_uri("localhost:13301"))
    """)
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'alive'])


def test_change_encryption(servers, helpers):
    servers[13301].conn.eval('return membership.set_encryption_key("YY")')
    assert servers[13301].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                              YY"
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'non-decryptable'])
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'non-decryptable'])

    servers[13302].conn.eval('return membership.set_encryption_key("YY")')
    assert servers[13302].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                              YY"
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'alive'])
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])


def test_disable_encryption(servers, helpers):
    servers[13302].conn.eval('return membership.set_encryption_key(nil)')
    assert servers[13302].conn.eval(
        'return membership.get_encryption_key()')[0] is None
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'non-decryptable'])
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'non-decryptable'])

    servers[13301].conn.eval('return membership.set_encryption_key(nil)')
    assert servers[13301].conn.eval(
        'return membership.get_encryption_key()')[0] is None
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'alive'])
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])


def test_gh36(servers, helpers):
    # There was a bug in nslookup function which prevented
    # discovering non-decryptable members
    for i in range(1, 10):
        # Flood resolve_cache with non-resolvable uris
        uri = 's%03d:oO' % i
        servers[13302].conn.eval('membership.probe_uri("%s")' % uri)

    servers[13301].conn.eval('return membership.set_encryption_key("ZZ")')
    assert servers[13301].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                              ZZ"
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'non-decryptable'])
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'non-decryptable'])
