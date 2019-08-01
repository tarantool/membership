#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging

servers_list = [13301, 13302]

def test_subscribe(servers, helpers):
    assert servers[13301].add_member('localhost:13302')
    servers[13301].conn.eval('_G.cond = membership.subscribe()')
    assert servers[13301].conn.eval('return _G.cond:wait(1)')[0] == False
    assert servers[13302].conn.eval('return membership.set_payload("foo", "bar")')[0]
    assert servers[13301].conn.eval('return _G.cond:wait(1)')[0] == True
