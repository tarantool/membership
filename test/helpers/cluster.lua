local fio = require('fio')
local log = require('log')
local socket = require('socket')
local Server = require('test.helpers.server')
local cluster = {}

function cluster.start(hostname, ports)
    local datadir = fio.pathjoin(fio.cwd(), 'test_cluster_data')
    if fio.path.exists(datadir) then
        fio.rmtree(datadir)
    end
    fio.mkdir(datadir)

    if cluster.servers ~= nil then
        log.warn("Cluster is already running")
        return
    end

    if type(ports) ~= 'table' or #ports == 0 then
        error("Ports for cluster servers are not specified")
    end

    for _, port in ipairs(ports) do
        local sock = socket.tcp()
        local is_busy = sock:connect(hostname, port)
        sock:close()
        if is_busy then
            error("Port " .. port .. " is already in use!")
        end
    end

    log.info("Starting a cluster with ports: " .. table.concat(ports, ", "))

    cluster.servers = {}

    local instance_path = fio.pathjoin(fio.cwd(), "test", "helpers", 'instance.lua')

    for i, port in ipairs(ports) do
        local alias = 'server-' .. i
        local workdir = fio.pathjoin(datadir, 'server-' .. i)

        fio.mkdir(workdir)
        fio.mkdir(fio.pathjoin(workdir, 'wal'))
        fio.mkdir(fio.pathjoin(workdir, 'vinyl'))

        local server_config = {
            alias = alias,
            command = instance_path,
            workdir = workdir,
            args = {
                '--wal-dir', fio.pathjoin(workdir, 'wal'),
                '--vinyl-dir', fio.pathjoin(workdir, 'vinyl')
            },
            advertise_port = tonumber(port),
            env = {
                TARANTOOL_LISTEN = tostring(port),
                TARANTOOL_HOSTNAME = hostname,
            },

            net_box_credentials = {
                user = 'guest',
                password = "",
            },
            cluster_cookie = ""

        }

        local server = Server:new(server_config)
        table.insert(cluster.servers, server)

        server:start()

        log.info("Server " .. alias .. " is running on port " .. port)
    end

    for _, server in ipairs(cluster.servers) do
        server:wait_until_ready({ timeout = 10 })
    end

    log.info("The cluster was successfully started, the number of servers: " .. #cluster.servers)
    return true
end

function cluster.stop()
    if cluster.servers == nil then
        log.warn("The cluster was not started")
        return
    end

    log.info("Stopping the cluster...")

    for _, server in ipairs(cluster.servers) do
        server:stop()
        log.info("The server " .. server.alias .. " is stopped")
    end

    cluster.servers = nil

    log.info("Cluster has been successfully stopped")
    return true
end

return cluster
