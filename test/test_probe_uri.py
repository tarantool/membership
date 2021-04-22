#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import platform
servers_list = [13301]


def test(servers, helpers):
    assert servers[13301].conn.eval('''
        warnings = { }
        package.loaded.log.warn = function(...)
            table.insert(warnings, string.format(...))
        end
        return true
    ''')

    def probe_uri(uri):
        cmd = "return membership.probe_uri('{}')".format(uri)
        return servers[13301].conn.eval(cmd)

    assert probe_uri('localhost:13301') == [True]
    assert probe_uri('localhost:13302') == [None, 'no response']
    assert probe_uri('127.0.0.1:13301') == [None, 'no response']
    assert probe_uri(':::') == [None, 'parse error']

    assert probe_uri('unix/:/dev/null') == [None, 'ping was not sent']
    assert probe_uri('unknown-host:9') == [None, 'ping was not sent']
    assert probe_uri('unknown-host:9') == [None, 'ping was not sent']
    assert probe_uri('-:/') == [None, 'ping was not sent']

    # https://github.com/tarantool/tarantool/commit/92fe50fa999d6153e8c4d5d43fb0c419ce05350e
    # Tarantool didn't return error message up to 2.5
    version = servers[13301].conn.eval('return _TARANTOOL')[0]
    major, minor = (int(x) for x in version.split('.')[0:2])
    expected_warnings = None
    if (major < 2) or (major == 2 and minor < 5):
        expected_warnings = [
            'getaddrinfo: Unknown error (unix/:/dev/null)',
            'getaddrinfo: Unknown error (unknown-host:9)',
            'getaddrinfo: Unknown error (-)'
        ]
    elif platform.system() == 'Linux':
        expected_warnings = [
            'getaddrinfo: Servname not supported for ai_socktype (unix/:/dev/null)',
            'getaddrinfo: Temporary failure in name resolution (unknown-host:9)',
            'getaddrinfo: Name or service not known (-)'
        ]
    else:
        expected_warnings = [
            'getaddrinfo: nodename nor servname provided, or not known (unix/:/dev/null)',
            'getaddrinfo: nodename nor servname provided, or not known (unknown-host:9)',
            'getaddrinfo: nodename nor servname provided, or not known (-)'
        ]

    assert servers[13301].conn.eval('return warnings')[0] == expected_warnings
