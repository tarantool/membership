local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster2')
local fiber = require('fiber')

local SERVER_LIST = { 13301, 13302, 13303, 13304 }

g.before_all(function()
    cluster.start(SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

local function get_member(server, port)
    local cmd_template = "return membership.get_member('localhost:%d')"
    local res, err = server:eval(cmd_template:format(port))
    t.assert_equals(err, nil)
    return res
end

local function check_status(server, port, status)
    local res = get_member(server, port)
    t.assert_equals(res.status, status)
end

g.test_smoke = function()
    local cmd_template = "return membership.probe_uri('localhost:%d')"

    for i = 1, 4 do
        cluster.servers[1]:eval(cmd_template:format(SERVER_LIST[i]))
    end

    cluster.servers[3]:stop()
    t.helpers.retrying(
            { timeout = 3, delay = 0.1 },
            check_status, cluster.servers[1], 13303, 'dead'
    )

    cluster.servers[4]:stop()
    t.helpers.retrying(
            { timeout = 3, delay = 0.1 },
            check_status, cluster.servers[1], 13304, 'dead'
    )

    local _, err = cluster.servers[1]:eval([[
        return membership.set_allowed_members({
            'localhost:13301', 'localhost:13302', 'localhost:13303',
        })
    ]])
    t.assert_equals(err, nil)

    fiber.sleep(2)

    check_status(cluster.servers[1], 13302, 'alive')
    check_status(cluster.servers[1], 13303, 'dead')
    local res = get_member(cluster.servers[1], 13304)
    t.assert_equals(res, nil)
end
