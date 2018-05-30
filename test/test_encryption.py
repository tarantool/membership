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
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])

def test_encryption(servers, helpers):
    assert servers[33001].conn.eval('return membership.is_encrypted()')[0] == False

    servers[33002].conn.eval('return membership.set_encryption_key("XXXXXX")')
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'dead'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'dead'])

    servers[33001].conn.eval('return membership.set_encryption_key("XXXXXX")')
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])

    servers[33001].conn.eval('return membership.set_encryption_key("YY")')
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'dead'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'dead'])

    servers[33002].conn.eval('return membership.set_encryption_key("YY")')
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])

    servers[33002].conn.eval('return membership.set_encryption_key(nil)')
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'dead'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'dead'])

    servers[33001].conn.eval('return membership.set_encryption_key(nil)')
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])
