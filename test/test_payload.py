#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302]


def check_payload(srv, uri, payload, status='alive'):
    member = srv.members()[uri]
    assert member['status'] == status
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

    assert servers[13301].conn.eval('''
        _G.checks_disabled = true
        local opts = require('membership.options')
        require('membership.events').generate('13301', opts.DEAD, 31, 37)
        _G.checks_disabled = false

        return true
    ''')[0]
    helpers.wait_for(check_payload, [
        servers[13302],
        '13301',
        [],
        'dead',
    ])
