#!/usr/bin/env tarantool

require('strict').on()
local log = require('log')

if rawget(_G, "is_initialized") == nil then
    _G.is_initialized = false
end

local listen = os.getenv('TARANTOOL_LISTEN')
local workdir = os.getenv('TARANTOOL_WORKDIR') or './tmp'
os.execute('mkdir -p ' .. workdir)
box.cfg({
    listen = listen,
    memtx_dir = workdir,
    vinyl_dir = workdir,
    wal_dir = workdir,
})
box.once('tarantool-entrypoint', function ()
    box.schema.user.grant("guest", 'read,write,execute', 'universe', nil, {if_not_exists = true})
    box.schema.user.grant("guest", 'replication',        nil,        nil, {if_not_exists = true})
end)

membership = require('membership')
-- tune periods to speed up test
opts = require('membership.options')
opts.PROTOCOL_PERIOD_SECONDS = 0.4
opts.ACK_TIMEOUT_SECONDS = 0.2
opts.ANTI_ENTROPY_PERIOD_SECONDS = 1.0
opts.SUSPECT_TIMEOUT_SECONDS = 1.0

membership.init('localhost', tonumber(listen))
_G.is_initialized = true
