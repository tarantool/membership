#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging
import time

servers_list = range(33001, 33022) # 20 instances

def check_everybody(servers, uri, status):
    for port, srv in servers.iteritems():
        member = srv.members()[uri]
        assert member['status_name'] == status

def test_payload(servers, helpers):
    for port, srv in servers.iteritems():
        if port+1 in servers_list:
            srv.add_member('localhost:{}'.format(port+1))

    helpers.wait_for(check_everybody, [servers, 'localhost:33001', 'alive'], timeout=5)
    logging.warn('Killing localhost:33001')
    servers[33001].kill()
    del servers[33001]
    helpers.wait_for(check_everybody, [servers, 'localhost:33001', 'dead'], timeout=5)
