#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302]


def check_status(srv, uri, status):
    member = srv.members()[uri]
    assert member['status'] == status


def test_join(servers, helpers):
    assert servers[13301].add_member('localhost:13302')
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'alive'])


def test_dead(servers, helpers):
    servers[13302].kill()
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'suspect'])
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'dead'])


def test_recover(servers, helpers):
    servers[13302].start()
    helpers.wait_for(servers[13302].connect)
    helpers.wait_for(check_status, [servers[13301], 'localhost:13302', 'alive'])
    helpers.wait_for(check_status, [servers[13302], 'localhost:13301', 'alive'])
