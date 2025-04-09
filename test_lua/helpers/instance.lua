require('strict').on()
local log = require('log')
local fiber = require('fiber')

local checks = require('checks')
package.loaded['checks'] = function(...)
    if rawget(_G, "checks_disabled") == true then
        return
    end
    return checks(...)
end

local membership = require('membership')
_G.membership = membership

if rawget(_G, "is_initialized") == nil then
    _G.is_initialized = false
end

local listen = os.getenv('TARANTOOL_LISTEN') or '13301'
print("Starting Tarantool instance on port:", listen)
local wal_dir = arg[2] or '.'
local vinyl_dir = arg[4] or '.'
box.cfg({
    listen = listen,
    wal_dir = os.getenv('TARANTOOL_WAL_DIR') or './wal',
    vinyl_dir = os.getenv('TARANTOOL_VINYL_DIR') or './vinyl',
    work_dir = os.getenv('TARANTOOL_WORKDIR') or '.'
})
print("Starting server on port:", listen)
local hostname = os.getenv('TARANTOOL_HOSTNAME') or 'localhost'

box.schema.user.grant('guest', 'read,write,execute,create,alter,drop', 'universe', nil, {if_not_exists=true})

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

-- Вспомогательные функции для тестов
function get_members()
    return membership.members()
end

function get_my_uri()
    return hostname .. ':' .. listen
end

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
