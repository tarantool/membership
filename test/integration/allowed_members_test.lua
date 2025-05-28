local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster')
local fiber = require('fiber')

local SERVER_LIST = { 13301, 13302, 13303, 13304, 13305 }
--[[
    13301: myself                   -> visible
    13302: alive and     allowed    -> visible
    13303: alive and not allowed    -> visible
    13304: dead  and     allowed    -> visible
    13305: dead  and not allowed    -> removed
]]

g.before_all(function()
    cluster.start('localhost', SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

g.test_smoke = function()
    for i = 1, 5 do
        t.assert(cluster.servers[1]:exec(function(port)
            return membership.probe_uri(string.format('localhost:%d', port))
        end, { SERVER_LIST[i] }))
    end

    -- Everyone is allowed
    cluster.servers[1]:exec(function()
        return membership.set_allowed_members({
            'localhost:13301', 'localhost:13302', 'localhost:13304',
        })
    end)

    -- Wait for the new events
    fiber.sleep(2)

    -- Everyone is visible, because everyone is alive
    for i = 2, 5 do
        t.assert_equals(cluster.servers[1]:get_member(
            string.format('localhost:%d', SERVER_LIST[i])
        )['status'], 'alive')
    end

    cluster.servers[4]:stop()
    cluster.servers[5]:stop()

    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13304', 'dead'
    )

    t.assert_equals(
        cluster.servers[1]:get_member('localhost:13302')['status'],
        'alive'
    )
    t.assert_equals(
        cluster.servers[1]:get_member('localhost:13303')['status'],
        'alive'
    )
    t.assert_equals(
        cluster.servers[1]:get_member('localhost:13304')['status'],
        'dead'
    )
    t.assert_equals(cluster.servers[1]:get_member('localhost:13305'), nil)
end
