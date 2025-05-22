local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster2')
local fiber = require('fiber')

local SERVER_LIST = { 13301, 13302 }

g.before_all(function()
    cluster.start('localhost', SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

g.test_sync = function()
    t.assert(cluster.servers[1]:add_member('localhost:33088'))

    t.helpers.retrying(
        {},
        cluster.servers[1].check_status, cluster.servers[1],
        'localhost:33088', 'dead'
    )

    -- Wait for dead events to expire
    fiber.sleep(2)

    -- Make sure dead members are synced
    t.assert(cluster.servers[2]:add_member('localhost:13301'))

    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'alive'
    )

    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:33088', 'dead'
    )
end
