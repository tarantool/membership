#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging

servers_list = [33001, 33002]
def check_status(srv, uri, status):
    member = srv.members()[uri]
    assert member['status'] == status

def test_join(servers, helpers):
    assert servers[33001].add_member('localhost:33002')
    assert servers[33001].conn.eval('return membership.get_encryption_key()')[0] == None

    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])

def test_enable_encryption(servers, helpers):
    servers[33002].conn.eval('return membership.set_encryption_key("XXXXXX")')
    assert servers[33002].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                          XXXXXX"
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'non-decryptable'], timeout=5)
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'non-decryptable'], timeout=5)

    servers[33001].conn.eval('return membership.set_encryption_key("XXXXXX")')
    assert servers[33001].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                          XXXXXX"
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])
    

def test_change_encryption(servers, helpers):
    servers[33001].conn.eval('return membership.set_encryption_key("YY")')
    assert servers[33001].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                              YY"
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'non-decryptable'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'non-decryptable'])

    servers[33002].conn.eval('return membership.set_encryption_key("YY")')
    assert servers[33002].conn.eval(
        'return membership.get_encryption_key()')[0] == \
        "                              YY"
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])

def test_disable_encryption(servers, helpers):
    servers[33002].conn.eval('return membership.set_encryption_key(nil)')
    assert servers[33002].conn.eval(
        'return membership.get_encryption_key()')[0] == None
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'non-decryptable'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'non-decryptable'])

    servers[33001].conn.eval('return membership.set_encryption_key(nil)')
    assert servers[33001].conn.eval(
        'return membership.get_encryption_key()')[0] == None
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])
