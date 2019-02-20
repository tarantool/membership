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
opts.PROTOCOL_PERIOD_SECONDS = 0.2
opts.ACK_TIMEOUT_SECONDS = 0.1
opts.ANTI_ENTROPY_PERIOD_SECONDS = 2
opts.SUSPECT_TIMEOUT_SECONDS = 2

-- Monkeypatch socket library to validate MAX_PACKET_SIZE
local socket_lib = require('socket')

local socket_mt = getmetatable(socket_lib)
local create_socket = socket_mt.__call
socket_mt.__call = function(...)
    log.error('Monkeypatching socket')
    local sock = create_socket(...)
    local sendto = sock.sendto
    function sock.sendto(self, host, port, msg)
        if #msg > opts.MAX_PACKET_SIZE then
            log.error('Packet too big, %d > %d', #msg, opts.MAX_PACKET_SIZE)
            os.exit(220)
        end
        return sendto(self, host, port, msg)
    end

    return sock
end

local membership = require('membership')
_G.membership = membership
membership.init(hostname, tonumber(listen))
_G.is_initialized = true
