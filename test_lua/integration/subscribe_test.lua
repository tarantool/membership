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

g.test_subscribe = function()
    t.assert(cluster.servers[1]:add_member('localhost:13302'))

    cluster.servers[1]:exec(function()
        rawset(_G, "cond", membership.subscribe())
    end)

    t.assert(not cluster.servers[1]:exec(function()
        return _G.cond:wait(1)
    end))
    t.assert(cluster.servers[2]:exec(function()
        return membership.set_payload("foo", "bar")
    end))
    t.assert(cluster.servers[1]:exec(function()
        return _G.cond:wait(1)
    end))
end
