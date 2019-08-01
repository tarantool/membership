#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging

hostname = "not-available"
servers_list = [13301]

def check_myself(srv, status):
    myself = srv.myself()
    assert myself['status'] == status

def test(servers, helpers):
    helpers.wait_for(check_myself, [servers[13301], 'dead'], timeout=5)
