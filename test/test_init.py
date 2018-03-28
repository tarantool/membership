#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging

servers_list = [33001, 33002]
def check_status(srv, uri, status):
    member = srv.members()[uri]
    # logging.warn(member)
    return member['status_name'] == status


def test_join(servers, helpers):
    assert servers[33001].add_member('localhost:33002')
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])

def test_dead(servers, helpers):
    servers[33002].kill()
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'suspect'])
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'dead'])

def test_recover(servers, helpers):
    servers[33002].start()
    helpers.wait_for(servers[33002].connect)
    helpers.wait_for(check_status, [servers[33001], 'localhost:33002', 'alive'])
    helpers.wait_for(check_status, [servers[33002], 'localhost:33001', 'alive'])
