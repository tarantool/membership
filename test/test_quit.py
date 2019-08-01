#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging
import time

servers_list = [13301, 13302]
def check_status(srv, uri, status):
    member = srv.members()[uri]
    assert member['status'] == status

def test_join(servers, helpers):
    assert servers[13301].add_member('localhost:13302')
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'alive'])

def test_quit(servers, helpers):
    assert servers[13302].conn.eval('return membership.leave()')[0]
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'left'])

def test_rejoin(servers, helpers):
    assert servers[13302].conn.eval('return membership.init("localhost", 13302)')[0]
    assert servers[13301].add_member('localhost:13302')
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'alive'])
