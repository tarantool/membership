#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302, 13303, 13304]


def test(servers, helpers):

    servers[13303].kill()
    servers[13304].kill()

    servers[13301].conn.eval("""
        return membership.set_allowed_members({
            'localhost:13301', 'localhost:13302', 'localhost:13303',
        })
    """)

    assert servers[13301].get_member('localhost:13302') is not None
    assert servers[13301].get_member('localhost:13303') is not None
    assert servers[13301].get_member('localhost:13304') is None
