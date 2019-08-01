#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging
import time

servers_list = [13301, 13302]

def check_status(srv, uri, status):
    member = srv.members()[uri]
    assert member['status'] == status

def test(servers, helpers):
    assert servers[13301].add_member('localhost:33088')
    helpers.wait_for(check_status, [servers[13301], 'localhost:33088', 'dead'])
    time.sleep(2) # wait for dead events to expire

    # Make sure dead members are synced
    assert servers[13302].add_member('localhost:13301')
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'alive'])
    helpers.wait_for(check_status, [servers[13302], 'localhost:33088', 'dead'])
