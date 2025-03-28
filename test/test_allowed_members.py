#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import time

servers_list = [13301, 13302, 13303, 13304, 13305]
'''
13301: myself                   -> visible
13302: alive and     allowed    -> visible
13303: alive and not allowed    -> visible
13304: dead  and     allowed    -> visible
13305: dead  and not allowed    -> removed
'''


def test(servers, helpers):
    for i in servers_list:
        assert servers[13301].probe_uri(f'localhost:{i}')

    # everyone is allowed
    servers[13301].conn.eval("""
        return membership.set_allowed_members({
            'localhost:13301', 'localhost:13302', 'localhost:13304',
        })
    """)

    time.sleep(2)  # wait for the new events

    # everyone is visible, because everyone is alive
    for i in [13302, 13303, 13304, 13305]:
        assert servers[13301].get_member(f'localhost:{i}')['status'] == 'alive'

    for i in [13304, 13305]:
        servers[i].kill()

    helpers.wait_for(servers[13301].check_status, ['localhost:13304', 'dead'])

    assert servers[13301].get_member('localhost:13302')['status'] == 'alive'
    assert servers[13301].get_member('localhost:13303')['status'] == 'alive'
    assert servers[13301].get_member('localhost:13304')['status'] == 'dead'
    assert servers[13301].get_member('localhost:13305') is None
