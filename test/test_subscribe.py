#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging

servers_list = [33001, 33002]

def test_subscribe(servers, helpers):
    assert servers[33001].add_member('localhost:33002')
    servers[33001].conn.eval('_G.cond = membership.subscribe()')
    assert servers[33001].conn.eval('return _G.cond:wait(1)')[0] == False
    assert servers[33002].conn.eval('return membership.set_payload("foo", "bar")')[0]
    assert servers[33001].conn.eval('return _G.cond:wait(1)')[0] == True
