#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302]


def check_clock_delta(srv, uri):
    member = srv.members()[uri]
    assert member['clock_delta'] is not None


def test_clock_diff(servers, helpers):
    servers[13301].probe_uri('localhost:13302')
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'alive'])

    helpers.wait_for(check_clock_delta, [servers[13302], 'localhost:13301'])
    helpers.wait_for(check_clock_delta, [servers[13301], 'localhost:13302'])
