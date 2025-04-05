local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster2')

local SERVER_LIST = {13301, 13302, 13303, 13304}

g.before_all(function()
    cluster.start(SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

g.test_mytest = function()
    t.assert(true)
end
