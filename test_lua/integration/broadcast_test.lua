local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster2')
local socket = require("socket")

local function get_local_ip()
    local hostname = nil

    local udp_socket = socket('AF_INET', 'SOCK_DGRAM', 'udp')
    local ok, _ = pcall(function()
        udp_socket:sysconnect("8.8.8.8", 80)
        hostname = udp_socket:name().host
        udp_socket:close()
    end)

    if not ok then
        hostname = 'localhost'
    end

    return hostname
end

local HOSTNAME = get_local_ip()
local SERVER_LIST = { 33001, 33002 }

g.before_all(function()
    cluster.start(HOSTNAME, SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

g.test_join = function()
    cluster.servers[2]:broadcast(33001)

    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], HOSTNAME .. ':33001', 'alive'
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], HOSTNAME .. ':33002', 'alive'
    )

    t.assert(cluster.servers[1]:probe_uri(HOSTNAME .. ':33002'))
    t.assert(cluster.servers[2]:probe_uri(HOSTNAME .. ':33001'))
end
