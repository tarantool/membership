#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging
import time

servers_list = range(33001, 33012) # 10 instances

def check_everybody(servers, uri, status):
    for port, srv in servers.items():
        member = srv.members()[uri]
        assert member['status'] == status

def test(servers, helpers):
    for port, srv in servers.items():
        assert servers[33001].probe_uri('localhost:{}'.format(port))

    helpers.wait_for(check_everybody, [servers, 'localhost:33001', 'alive'], timeout=5)
    logging.warn('Killing localhost:33001')
    servers[33001].kill()
    del servers[33001]
    helpers.wait_for(check_everybody, [servers, 'localhost:33001', 'dead'], timeout=5)
