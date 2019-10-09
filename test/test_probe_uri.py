#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301]


def test(servers, helpers):
    assert servers[13301].probe_uri('127.0.0.1:13301') is None
    assert servers[13301].probe_uri('localhost:13301') is True
    assert servers[13301].probe_uri('localhost:13302') is None
