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

    cluster.servers[1]:eval('_G.cond = membership.subscribe()')

    t.assert(not cluster.servers[1]:eval('return _G.cond:wait(1)'))
    t.assert(cluster.servers[2]:eval('return membership.set_payload("foo", "bar")'))
    t.assert(cluster.servers[1]:eval('return _G.cond:wait(1)'))
end

g.test_weakness = function()
    local res = cluster.servers[1]:eval([[
        local weaktable = setmetatable({}, {__mode = 'k'})
        weaktable[_G.cond] = true
        _G.cond = nil
        collectgarbage()
        collectgarbage()
        return next(weaktable)
    ]])
    t.assert_equals(res, nil)
end
