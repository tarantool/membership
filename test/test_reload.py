#!/usr/bin/env python3
# -*- coding: utf-8 -*-

servers_list = [13301, 13302]


def test_reload_slow(servers, helpers):
    """ Check that hot-reload doesn't affect statuses """

    assert servers[13301].probe_uri('localhost:13302') is True
    assert servers[13302].get_member('localhost:13301')['status'] == 'alive'

    servers[13302].conn.eval('''
        local log = require('log')
        local yaml = require('yaml')
        local fiber = require('fiber')

        _G.guard = fiber.new(function()
            membership.subscribe():wait()
            fiber.testcancel()
            log.error('Unexpected event:')
            log.error(yaml.encode(membership.members()))
            os.exit(1)
        end)
    ''')

    assert servers[13301].conn.eval('''
        local log = require('log')
        local fiber = require('fiber')

        package.loaded['membership'] = nil
        log.info('Membership unloaded')
        fiber.sleep(1)

        _G.membership = require('membership')
        log.info('Membership reloaded')
        fiber.sleep(1)

        log.info('Doing file %s...', arg[0])
        dofile(arg[0])
        log.info('Dofile succeeded')
        fiber.sleep(1)

        return membership.probe_uri('localhost:13302')
    ''') == [True]

    servers[13302].conn.eval('''
        _G.guard:cancel()
    ''')


def test_reload_fast(servers, helpers):
    """ Check that hot-reload doesn't affect other features """

    assert servers[13301].probe_uri('localhost:13302') is True
    assert servers[13302].get_member('localhost:13301')['status'] == 'alive'

    assert servers[13301].conn.eval('return package.reload()') == [True]

    assert servers[13302].conn.eval('return membership.set_payload("k", "v1")')[0]
    assert servers[13302].probe_uri('localhost:13301') is True
    assert servers[13301].members()['localhost:13302']['payload'] == {'k': 'v1'}

    servers[13301].conn.eval('_G.cond = membership.subscribe()')
    assert servers[13301].conn.eval('return package.reload()') == [True]
    assert servers[13302].conn.eval('return membership.set_payload("k", "v2")')[0]
    assert servers[13301].conn.eval('return _G.cond:wait(1)')[0]
    assert servers[13301].members()['localhost:13302']['payload'] == {'k': 'v2'}

    servers[13302].conn.eval('return membership.set_encryption_key("YY")')
    assert servers[13302].conn.eval('return package.reload()') == [True]
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'non-decryptable'])
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'non-decryptable'])

    servers[13301].conn.eval('return membership.set_encryption_key("YY")')
    helpers.wait_for(servers[13301].check_status, ['localhost:13302', 'alive'])
    helpers.wait_for(servers[13302].check_status, ['localhost:13301', 'alive'])
