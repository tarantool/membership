#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import time

servers_list = [13301, 13302]


def test(servers, helpers):
    assert servers[13301].add_member('localhost:33088')
    helpers.wait_for(servers[13301].check_status, ['localhost:33088', 'dead'])
    time.sleep(2)  # wait for dead events to expire

    # Make sure dead members are synced
    assert servers[13302].add_member('localhost:13301')
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])
    helpers.wait_for(servers[13302].check_status, ['localhost:33088', 'dead'])
