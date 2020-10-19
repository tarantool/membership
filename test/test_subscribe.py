#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302]


def test_subscribe(servers, helpers):
    assert servers[13301].add_member('localhost:13302')
    servers[13301].conn.eval('_G.cond = membership.subscribe()')
    assert not servers[13301].conn.eval('return _G.cond:wait(1)')[0]
    assert servers[13302].conn.eval('return membership.set_payload("foo", "bar")')[0]
    assert servers[13301].conn.eval('return _G.cond:wait(1)')[0]


def test_weakness(servers, helpers):
    assert servers[13301].conn.eval('''
        local weaktable = setmetatable({}, {__mode = 'k'})
        weaktable[_G.cond] = true
        _G.cond = nil
        collectgarbage()
        collectgarbage()
        return next(weaktable)
    ''')[0] is None
