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

g.test_join = function()
    t.assert(cluster.servers[1]:add_member('localhost:13302'))

    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'alive'
    )
end

g.test_quit = function()
    t.assert(cluster.servers[2]:eval('return membership.leave()'))

    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'left'
    )

    t.assert(not cluster.servers[2]:eval('return membership.leave()'))
end

g.test_rejoin = function()
    t.assert(cluster.servers[2]:eval('return membership.init("localhost", 13302)'))
    t.assert(cluster.servers[1]:add_member('localhost:13302'))

    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'alive'
    )
end

g.test_mark_left = function()
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'alive'
    )

    t.assert(cluster.servers[1]:eval('return membership.mark_left("localhost:13302")'))

    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'left'
    )

    -- already has left
    t.assert(not cluster.servers[1]:eval('return membership.mark_left("localhost:13302")'))

    -- there are no such member
    t.assert(not cluster.servers[1]:eval('return membership.mark_left("localhost:10000")'))
end
