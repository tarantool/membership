local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster2')

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

g.test_death = function()
    cluster.servers[2]:stop()
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'suspect'
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'dead'
    )

    cluster.servers[2]:start()
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

g.test_reinit = function()
    t.assert(cluster.servers[1]:add_member('localhost:13302'))
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'alive'
    )

    -- Change hostname
    t.assert(t.helpers.retrying(
        {},
        cluster.servers[1].eval,
        cluster.servers[1], "return membership.init('127.0.0.1', 13301)"
    ))
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'dead'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], '127.0.0.1:13301', 'alive'
    )

    -- Change port
    t.assert(t.helpers.retrying(
        {},
        cluster.servers[1].eval,
        cluster.servers[1], "return membership.init('127.0.0.1', 13303)"
    ))
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'dead'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], '127.0.0.1:13301', 'dead'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], '127.0.0.1:13303', 'alive'
    )

    -- Revert all changes
    t.assert(t.helpers.retrying(
        {},
        cluster.servers[1].eval,
        cluster.servers[1], "return membership.init('localhost', 13301)"
    ))
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

g.test_error = function()
    t.assert_error_msg_equals(
        'Socket bind error (13302/udp): Address already in use',
        cluster.servers[1].eval,
        cluster.servers[1],
        "return membership.init('localhost', 13302)"
    )

    t.assert(cluster.servers[1]:probe_uri('localhost:13301'))
    t.assert(cluster.servers[1]:probe_uri('localhost:13302'))
    t.assert(cluster.servers[2]:probe_uri('localhost:13301'))
end
