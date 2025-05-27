local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster')

local SERVER_LIST = { 13301 }

g.before_all(function()
    cluster.start('not-available', SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

g.test_dead = function()
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'not-available:13301', 'dead'
    )
end
