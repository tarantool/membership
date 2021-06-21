#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import socket


hostname = None


try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    hostname = s.getsockname()[0]
    s.close()
except:  # noqa: E722
    hostname = socket.gethostname()
    hostname = socket.gethostbyname(hostname)

print("Hostname detected: {}".format(hostname))

servers_list = [33001, 33002]


def test_join(servers, helpers):
    servers[33002].broadcast(33001)
    helpers.wait_for(servers[33002].check_status, [hostname + ':33001', 'alive'])
    helpers.wait_for(servers[33001].check_status, [hostname + ':33002', 'alive'])
    assert servers[33001].probe_uri(hostname + ':33002')
    assert servers[33002].probe_uri(hostname + ':33001')
