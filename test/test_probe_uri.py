#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest

servers_list = [13301]

def test(servers, helpers):
    assert servers[13301].probe_uri('127.0.0.1:13301') == None
    assert servers[13301].probe_uri('localhost:13301') == True
    assert servers[13301].probe_uri('localhost:13302') == None
