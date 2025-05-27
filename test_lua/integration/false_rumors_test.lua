local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster')
local fiber = require('fiber')

local SERVER_LIST = { 13301, 13302, 13303 }

g.before_all(function()
    cluster.start('localhost', SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

local function check_rumors(server, expected)
    t.assert_equals(server:eval('return rumors'), expected)
end

g.test_setup = function()
    -- Monkeypatch the instance to collect all rumors
    t.assert(cluster.servers[1]:eval([[
        rumors = setmetatable({ }, {__serialize = 'map'})

        local fiber = require('fiber')
        local members = require('membership.members')
        local opts = require('membership.options')

        local function collect_rumors()
            for uri, m in members.pairs() do
                if m.status ~= opts.ALIVE then
                    rumors[uri] = opts.STATUS_NAMES[m.status]
                end
            end
        end

        _G._collector_fiber = fiber.create(function()
            local cond = membership.subscribe()
            while true do
                cond:wait()
                fiber.testcancel()
                collect_rumors()
            end
        end)

        return true
    ]]))

    t.assert(cluster.servers[1]:probe_uri('localhost:13302'))
    t.assert(cluster.servers[1]:probe_uri('localhost:13303'))
    check_rumors(cluster.servers[1], {})
end

g.test_indirect_ping = function()
    -- Ack timeout shouldn't trigger failure detection
    -- because indirect pings still work
    cluster.servers[1]:eval([[
        local opts = require('membership.options')
        opts.ACK_TIMEOUT_SECONDS = 0
    ]])

    fiber.sleep(2)
    check_rumors(cluster.servers[1], {})
end

g.test_flickering = function()
    -- Cluster starts flickering if indirect pings are disabled

    cluster.servers[1]:eval([[
        local opts = require('membership.options')
        opts.NUM_FAILURE_DETECTION_SUBGROUPS = 0
    ]])

    t.helpers.retrying(
        {},
        check_rumors,
        cluster.servers[1],
        {
            ['localhost:13301'] = 'suspect',
            ['localhost:13302'] = 'suspect',
            ['localhost:13303'] = 'suspect',
        }
    )
end

g.test_nonsuspiciousness = function()
    -- With disabled suspiciousness it stops flickering again

    cluster.servers[1]:eval([[
        local opts = require('membership.options')
        opts.SUSPICIOUSNESS = false
    ]])

    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13301', 'alive'
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'alive'
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13303', 'alive'
    )
    cluster.servers[1]:eval('table.clear(rumors)')

    fiber.sleep(2)
    check_rumors(cluster.servers[1], {})
end
