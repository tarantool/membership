#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging
import time

servers_list = [33001, 33002]
def check_status(srv, uri, status):
    member = srv.members()[uri]
    assert member['status'] == status

def test_join(servers, helpers):
    assert servers[33001].add_member('localhost:33002')
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])

def test_quit(servers, helpers):
    assert servers[33002].conn.eval('return membership.leave()')[0]
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'left'])

def test_rejoin(servers, helpers):
    assert servers[33002].conn.eval('return membership.init("localhost", 33002)')[0]
    assert servers[33001].add_member('localhost:33002')
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])
