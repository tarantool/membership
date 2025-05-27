local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster')
local fiber = require('fiber')
local log = require('log')

local FIRST_PORT = 13301
local SERVER_COUNT = 100
local SERVER_LIST = {}
for i = 1, SERVER_COUNT do
    SERVER_LIST[i] = FIRST_PORT + i - 1
end

g.before_all(function()
    cluster.start('localhost', SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

g.test_discover_join = function()
    local start = fiber.clock()
    for i = 1, SERVER_COUNT do
        t.assert(cluster.servers[1]:probe_uri(
            string.format('localhost:%s', FIRST_PORT + i - 1)))
    end
    local duration = fiber.clock() - start
    log.info(string.format("Probe all in %.3fs", duration))

    start = fiber.clock()
    t.helpers.retrying({}, function()
        for _, server in ipairs(cluster.servers) do
            local alive_count = server:eval([[
                local alive_count = 0
                for uri, m in membership.pairs() do
                    if m.status == 'alive' then
                        alive_count = alive_count + 1
                    end
                end
                return alive_count
            ]])
            t.assert_equals(alive_count, SERVER_COUNT)
        end
    end)
    duration = fiber.clock() - start
    log.info(string.format('Full mesh in %.3fs', duration))
end

g.test_discover_kill = function()
    cluster.servers[1]:stop()

    t.helpers.retrying({}, function()
        -- Check that all members consider URI has given STATUS

        local uri = string.format('localhost:%s', FIRST_PORT)
        for i = 2, SERVER_COUNT do
            local member = cluster.servers[i]:get_member(uri)
            t.assert_not_equals(member, nil)
            t.assert_not_equals(member['status'], 'alive')
        end
    end)
end
