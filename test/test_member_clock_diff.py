#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302]


def check_status(srv, uri, status):
    member = srv.members()[uri]
    assert member['status'] == status


def check_clock_delta(srv, uri):
    member = srv.members()[uri]
    assert member['clock_delta'] >= 0


def test_clock_diff(servers, helpers):
    servers[13301].probe_uri('localhost:13302')
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'alive'])
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'alive'])

    helpers.wait_for(check_clock_delta, [servers[13302], 'localhost:13301'])
    helpers.wait_for(check_clock_delta, [servers[13301], 'localhost:13302'])
