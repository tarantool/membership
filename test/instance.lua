#!/usr/bin/env tarantool

require('strict').on()
local log = require('log')
local fiber = require('fiber')
local console = require('console')
local membership = require('membership')
_G.membership = membership

if rawget(_G, "is_initialized") == nil then
    _G.is_initialized = false
end

local listen = os.getenv('TARANTOOL_LISTEN')
local hostname = os.getenv('TARANTOOL_HOSTNAME') or 'localhost'

if not _G.is_initialized then
    local c = console.listen('127.0.0.1:'..listen)
    log.info('Console started at %s:%s', c:name().host, c:name().port)
end

-- Tune periods to speed up tests
-- Supposing loopback roundtrip is about 0.1ms
local opts = require('membership.options')
opts.PROTOCOL_PERIOD_SECONDS = 0.2
opts.ACK_TIMEOUT_SECONDS = 0.1
opts.ANTI_ENTROPY_PERIOD_SECONDS = 2
opts.SUSPECT_TIMEOUT_SECONDS = 2

if not _G.is_initialized then
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
end

membership.init(hostname, tonumber(listen))
_G.is_initialized = true

_G.package.reload = function()
    local csw1 = fiber.info()[fiber.id()].csw

    package.loaded['membership'] = nil
    log.info('Doing file %s...', arg[0])
    dofile(arg[0])

    local csw2 = fiber.info()[fiber.id()].csw
    assert(csw1 == csw2, 'Unexpected yield')

    log.info('Dofile succeeded')
    return true
end
