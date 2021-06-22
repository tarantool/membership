#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import time

servers_list = [13301, 13302, 13303]


def check_rumors(srv, expected):
    assert srv.conn.eval("return rumors")[0] == expected


def test_setup(servers, helpers):
    # Monkeypatch the instance to collect all rumors
    assert servers[13301].conn.eval('''
        rumors = setmetatable({ }, {__serialize = 'map'})

        local fiber = require('fiber')
        local members = require('membership.members')
        local opts = require('membership.options')

        local function collect_rumors()
            for uri, m in members.pairs() do
                if m.status ~= opts.ALIVE then
                    rumors[uri] = opts.STATUS_NAMES[m.status]
                end
            end
        end

        _G._collector_fiber = fiber.create(function()
            local cond = membership.subscribe()
            while true do
                cond:wait()
                fiber.testcancel()
                collect_rumors()
            end
        end)

        return true
    ''')[0] is True

    assert servers[13301].probe_uri('localhost:13302')
    assert servers[13301].probe_uri('localhost:13303')
    check_rumors(servers[13301], {})


def test_indirect_ping(servers, helpers):
    # Ack timeout shouldn't trigger failure detection
    # because inderect pings still work

    servers[13301].conn.eval('''
        local opts = require('membership.options')
        opts.ACK_TIMEOUT_SECONDS = 0
    ''')

    time.sleep(2)
    check_rumors(servers[13301], {})


def test_flickering(servers, helpers):
    # Cluster starts flickering if indirect pings are disabled

    servers[13301].conn.eval('''
        local opts = require('membership.options')
        opts.NUM_FAILURE_DETECTION_SUBGROUPS = 0
    ''')

    helpers.wait_for(check_rumors, [servers[13301], {
        'localhost:13301': 'suspect',
        'localhost:13302': 'suspect',
        'localhost:13303': 'suspect',
    }])
