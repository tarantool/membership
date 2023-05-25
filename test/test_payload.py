#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302]


def check_payload(srv, uri, payload):
    member = srv.members()[uri]
    assert member['status'] == 'alive'
    assert member['payload'] == payload


def test(servers, helpers):
    assert servers[13301].conn.eval('return membership.set_payload("foo1", {bar = "buzz"})')[0]
    assert servers[13301].add_member('localhost:13302')
    helpers.wait_for(check_payload, [
        servers[13302],
        'localhost:13301',
        {
            'foo1': {'bar': 'buzz'}
        }
    ])

    assert servers[13301].conn.eval('return membership.set_payload("foo2", 42)')[0]
    helpers.wait_for(check_payload, [
        servers[13302],
        'localhost:13301',
        {
            'foo1': {'bar': 'buzz'},
            'foo2': 42
        }
    ])

    assert servers[13301].conn.eval('return membership.set_payload("foo1", nil)')[0]
    helpers.wait_for(check_payload, [
        servers[13302],
        'localhost:13301',
        {
            'foo2': 42
        }
    ])

    assert servers[13301].conn.eval('return membership.set_table_payload{foo1 = 42, foo2 = 43}')[0]
    helpers.wait_for(check_payload, [
        servers[13302],
        'localhost:13301',
        {
            'foo1': 42,
            'foo2': 43,
        }
    ])
