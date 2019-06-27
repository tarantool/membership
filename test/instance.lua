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

membership = require('membership')
-- tune periods to speed up test
opts = require('membership.options')
opts.PROTOCOL_PERIOD_SECONDS = 0.4
opts.ACK_TIMEOUT_SECONDS = 0.2
opts.ANTI_ENTROPY_PERIOD_SECONDS = 1.0
opts.SUSPECT_TIMEOUT_SECONDS = 1.0

membership.init(hostname, tonumber(listen))
_G.is_initialized = true
