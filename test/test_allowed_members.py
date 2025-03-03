#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import time

servers_list = [13301, 13302, 13303, 13304]


def test(servers, helpers):

    servers[13303].kill()
    helpers.wait_for(servers[13301].check_status, ['localhost:13303', 'suspect'])

    servers[13304].kill()
    helpers.wait_for(servers[13301].check_status, ['localhost:13304', 'dead'])

    servers[13301].conn.eval("""
        return membership.set_allowed_members({
            'localhost:13301', 'localhost:13302', 'localhost:13303',
        })
    """)

    time.sleep(2)  # wait for dead events to expire

    assert servers[13301].get_member('localhost:13302')['status'] == 'alive'
    assert servers[13301].get_member('localhost:13303')['status'] == 'alive'
    assert servers[13301].get_member('localhost:13304') is None
