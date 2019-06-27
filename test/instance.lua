#!/usr/bin/env tarantool

require('strict').on()
local log = require('log')
local console = require('console')

if rawget(_G, "is_initialized") == nil then
    _G.is_initialized = false
end

local listen = os.getenv('TARANTOOL_LISTEN')
local hostname = os.getenv('TARANTOOL_HOSTNAME') or 'localhost'

local console_sock = '127.0.0.1:'..listen
console.listen(console_sock)
log.info('Console started at %s', console_sock)

-- Tune periods to speed up tests
-- Supposing loopback roundtrip is about 0.1ms
local opts = require('membership.options')
opts.PROTOCOL_PERIOD_SECONDS = 0.050
opts.ACK_TIMEOUT_SECONDS = 0.025
opts.ANTI_ENTROPY_PERIOD_SECONDS = 0.100
opts.SUSPECT_TIMEOUT_SECONDS = 0.100

local membership = require('membership')
_G.membership = membership
membership.init(hostname, tonumber(listen))

_G.is_initialized = true
