local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster')

local SERVER_LIST = { 13301, 13302 }

g.before_all(function()
    cluster.start('localhost', SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

g.test_reload_slow = function()
    -- Check that hot-reload doesn't affect statuses

    t.assert(cluster.servers[1]:probe_uri('localhost:13302'))

    local member = cluster.servers[2]:get_member('localhost:13301')
    t.assert_equals(member['status'], 'alive')

    cluster.servers[2]:exec(function()
        local log = require('log')
        local yaml = require('yaml')
        local fiber = require('fiber')

        rawset(_G, "guard", fiber.new(function()
            membership.subscribe():wait()
            fiber.testcancel()
            log.error('Unexpected event:')
            log.error(yaml.encode(membership.members()))
            os.exit(1)
        end))
    end)

    t.assert(cluster.servers[1]:exec(function()
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
    end))

    cluster.servers[2]:exec(function() _G.guard:cancel() end)
end

g.test_reload_fast = function()
    -- Check that hot-reload doesn't affect other features

    t.assert(cluster.servers[1]:probe_uri('localhost:13302'))

    local member = cluster.servers[2]:get_member('localhost:13301')
    t.assert_equals(member['status'], 'alive')

    t.assert(cluster.servers[1]:exec(function() return package.reload() end))

    t.assert(cluster.servers[2]:exec(function()
        return membership.set_payload("k", "v1")
    end))
    t.assert(cluster.servers[2]:probe_uri('localhost:13301'))
    local payload1 = cluster.servers[1]:members()['localhost:13302']['payload']
    t.assert_equals(payload1, { ['k'] = 'v1' })

    cluster.servers[1]:exec(function() rawset(_G, "cond", membership.subscribe()) end)

    t.assert(cluster.servers[1]:exec(function() return package.reload() end))
    t.assert(cluster.servers[2]:exec(function()
        return membership.set_payload("k", "v2")
    end))
    t.assert(cluster.servers[1]:exec(function() return _G.cond:wait(10) end))
    local payload2 = cluster.servers[1]:members()['localhost:13302']['payload']
    t.assert_equals(payload2, { ['k'] = 'v2'} )

    cluster.servers[2]:exec(function()
        return membership.set_encryption_key("YY")
    end)
    t.assert(cluster.servers[2]:exec(function() return package.reload() end))
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'non-decryptable'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'non-decryptable'
    )

    cluster.servers[1]:exec(function()
        return membership.set_encryption_key("YY")
    end)
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'alive'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'alive'
    )
end
