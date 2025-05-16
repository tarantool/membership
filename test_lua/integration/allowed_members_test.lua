local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster2')
local fiber = require('fiber')

local SERVER_LIST = { 13301, 13302, 13303, 13304 }

g.before_all(function()
    cluster.start('localhost', SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

g.test_smoke = function()
    local cmd_template = "return membership.probe_uri('localhost:%d')"

    for i = 1, 4 do
        cluster.servers[1]:eval(cmd_template:format(SERVER_LIST[i]))
    end

    cluster.servers[3]:stop()
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13303', 'dead'
    )

    cluster.servers[4]:stop()
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13304', 'dead'
    )

    cluster.servers[1]:eval([[
        return membership.set_allowed_members({
            'localhost:13301', 'localhost:13302', 'localhost:13303',
        })
    ]])

    fiber.sleep(2)

    cluster.servers[1]:check_status('localhost:13302', 'alive')
    cluster.servers[1]:check_status('localhost:13303', 'dead')

    local res = cluster.servers[1]:get_member('localhost:13304')
    t.assert_equals(res, nil)
end
