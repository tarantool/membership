#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging
import tarantool
import time
import os

servers_list = [30301, 30302]

def test_join(servers):
    for port, srv in servers.items():
        conn = tarantool.connect('127.0.0.1', port)
        logging.warn("{}: {}".format(port, conn.eval('return membership.members()')))

    assert 1 == 2