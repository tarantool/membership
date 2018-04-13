#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pytest
import logging

hostname = "not-available"
servers_list = [33001]

def check_myself(srv, status):
    myself = srv.myself()
    assert myself['status_name'] == status

def test_myself(servers, helpers):
    helpers.wait_for(check_myself, [servers[33001], 'dead'], timeout=5)
