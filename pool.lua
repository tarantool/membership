#!/usr/bin/env tarantool

local net_box = require('net.box')
local errors = require('errors')
local fiber = require('fiber')

local CONNECTION_FAILED = errors.new_class('CONNECTION_FAILED')

local connections = {}
local pool_locks = {}

local function connect(uri, options)
    while pool_locks[uri] do
        fiber.sleep(0)
    end

    pool_locks[uri] = true

    if connections[uri] ~= nil and connections[uri]:is_connected() then
        pool_locks[uri] = false
        return connections[uri]
    end

    local rc, res = pcall(net_box.connect, uri, options)

    if not rc then
        pool_locks[uri] = false
        return CONNECTION_FAILED.new("pool connection to '%s' failed: %s", uri, res)
    end

    connections[uri] = res

    pool_locks[uri] = false

    return res
end


return {connect=connect}
