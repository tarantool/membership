#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging
import time

servers_list = [33001, 33002]

def check_status(srv, uri, status):
    member = srv.members()[uri]
    assert member['status_name'] == status

def test_sync(servers, helpers):
    assert servers[33001].add_member('localhost:33088')
    helpers.wait_for(check_status, [servers[33001], 'localhost:33088', 'dead'])
    time.sleep(2) # wait for dead events to expire

    # Make sure dead members are synced
    assert servers[33002].add_member('localhost:33001')
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33088', 'dead'])
