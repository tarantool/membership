#!/usr/bin/env python3
# -*- coding: utf-8 -*-

hostname = "not-available"
servers_list = [13301]


def test(servers, helpers):
    helpers.wait_for(servers[13301].check_status, ['not-available:13301', 'dead'])
