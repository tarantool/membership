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

local function check_payload(server, uri, payload, status)
    local member = server:members()[uri]
    t.assert_equals(member['status'], status)
    t.assert_equals(member['payload'], payload)
end

g.test_payload = function()
    t.assert(cluster.servers[1]:exec(function()
        return membership.set_payload("foo1", { bar = "buzz" })
    end))
    t.assert(cluster.servers[1]:add_member('localhost:13302'))
    t.helpers.retrying(
        {},
        check_payload,
        cluster.servers[2], 'localhost:13301',
        {
            ['foo1'] = {
                ['bar'] = 'buzz'
            }
        },
        'alive'
    )

    t.assert(cluster.servers[1]:exec(function()
        return membership.set_payload("foo2", 42)
    end))
    t.helpers.retrying(
        {},
        check_payload,
        cluster.servers[2], 'localhost:13301',
        {
            ['foo1'] = {
                ['bar'] = 'buzz'
            },
            ['foo2'] = 42
        },
        'alive'
    )

    t.assert(cluster.servers[1]:exec(function()
        return membership.set_payload("foo1", nil)
    end))
    t.helpers.retrying(
        {},
        check_payload,
        cluster.servers[2], 'localhost:13301',
        {
            ['foo2'] = 42
        },
        'alive'
    )

    t.assert(cluster.servers[1]:exec(function()
        rawset(_G, "checks_disabled", true)
        local opts = require('membership.options')
        require('membership.events').generate('13301', opts.DEAD, 31, 37)
        rawset(_G, "checks_disabled", false)

        return true
    end))
    t.helpers.retrying(
        {},
        check_payload,
        cluster.servers[2], '13301',
        {},
        'dead'
    )
end
