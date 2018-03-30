#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging
import time

servers_list = [33001, 33002, 33003]
def check_status(srv, uri, status):
    member = srv.members()[uri]
    return member['status_name'] == status

def test_split(servers, helpers):
    """Setup two separate clusters"""
    assert servers[33001].add_member('localhost:33002')
    assert servers[33001].add_member('localhost:33088')
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])
    helpers.wait_for(check_status, [servers[33001], 'localhost:33088', 'dead'])

    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33088', 'dead'])
    
def test_merge(servers, helpers):
    """Merge clusters, make sure dead members are synced"""
    time.sleep(3) # wait for dead events to expire
    assert servers[33003].add_member('localhost:33001')
    helpers.wait_for(check_status, [servers[33003], 'localhost:33001', 'alive'])
    helpers.wait_for(check_status, [servers[33003], 'localhost:33002', 'alive'])
    helpers.wait_for(check_status, [servers[33003], 'localhost:33088', 'dead'])
