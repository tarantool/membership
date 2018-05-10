#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging
import time

servers_list = [33001, 33002]

def check_payload(srv, uri, payload):
    member = srv.members()[uri]
    assert member['status'] == 'alive'
    assert member['payload'] == payload

def test_payload(servers, helpers):
    assert servers[33001].conn.eval('return membership.set_payload("foo1", {bar = "buzz"})')[0]
    assert servers[33001].add_member('localhost:33002')
    helpers.wait_for(check_payload, [
        servers[33002],
        'localhost:33001',
        {
            'foo1': {'bar': 'buzz'}
        }
    ])

    assert servers[33001].conn.eval('return membership.set_payload("foo2", 42)')[0]
    helpers.wait_for(check_payload, [
        servers[33002],
        'localhost:33001',
        {
            'foo1': {'bar': 'buzz'},
            'foo2': 42
        }
    ])

    assert servers[33001].conn.eval('return membership.set_payload("foo1", nil)')[0]
    helpers.wait_for(check_payload, [
        servers[33002],
        'localhost:33001',
        {
            'foo2': 42
        }
    ])
