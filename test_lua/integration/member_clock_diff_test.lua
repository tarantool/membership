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

local function check_clock_delta(server, uri)
    local member = server:members()[uri]
    t.assert(member['clock_delta'] ~= nil)
end

g.test_clock_diff = function()
    cluster.servers[1]:probe_uri('localhost:13302')

    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'alive'
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'alive'
    )

    t.helpers.retrying(
        {},
        check_clock_delta, cluster.servers[2], 'localhost:13301'
    )
    t.helpers.retrying(
        {},
        check_clock_delta, cluster.servers[1], 'localhost:13302'
    )
end
