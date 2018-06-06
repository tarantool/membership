#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest

servers_list = [33001]

def test(servers, helpers):
    assert servers[33001].probe_uri('127.0.0.1:33001') == None
    assert servers[33001].probe_uri('localhost:33001') == True
    assert servers[33001].probe_uri('localhost:33002') == None
