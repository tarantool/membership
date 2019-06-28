#!/usr/bin/env tarantool

local log = require('log')
local uri_tools = require('uri')
local json = require('json')
local fiber = require('fiber')
local checks = require('checks')
local socket = require('socket')
local msgpack = require('msgpack')

local opts = require('membership.options')
local events = require('membership.events')
local members = require('membership.members')
local network = require('membership.network')

local _sock = nil
local _sync_trigger = fiber.cond()
local _ack_trigger = fiber.cond()
local _ack_cache = {}

local _resolve_cache = {}
local function resolve(uri)
    checks('string')

    local member = members.get(uri)
    if member and member.status == opts.ALIVE then
        local _cached = _resolve_cache[uri]
        if _cached then
            return unpack(_cached)
        end
    end

    local parts = uri_tools.parse(uri)
    if not parts then
        return nil, nil, 'parse error'
    end

    local hosts = socket.getaddrinfo(parts.host, parts.service, {family='AF_INET', type='SOCK_DGRAM'})
    if hosts == nil or #hosts == 0 then
        return nil, nil, 'getaddrinfo failed'
    end

    local _cached = {hosts[1].host, hosts[1].port}
    _resolve_cache[uri] = _cached
    return unpack(_cached)
end
local function nslookup(host, port)
    checks('string', 'number')

    for uri, cache in pairs(_resolve_cache) do
        local cached_host, cached_port = unpack(cache)
        if (cached_host == host) and (cached_port == port) then
            return uri
        end
    end

    return nil
end

local function random_permutation(tbl)
    local cnt = #tbl
    for src = 1, cnt-1 do
        local dst = math.random(src, cnt)
        local x = tbl[dst]
        tbl[dst] = tbl[src]
        tbl[src] = x
    end
    return tbl
end

--
-- SEND FUNCTIONS
--

local function send_message(uri, msg_type, msg_data)
    checks('string', 'string', 'table')
    local host, port = resolve(uri)
    if not host then
        return false
    end

    local events_to_send = {}
    local msg_raw = {opts.advertise_uri, msg_type, msg_data, events_to_send}
    local msg_size = #msgpack.encode(msg_raw)

    if members.get(uri) then
        local extra_event = events.get(uri)
        if extra_event == nil then
            local member = members.get(uri)
            extra_event = {
                uri = uri,
                status = member.status,
                incarnation = member.incarnation,
                ttl = 1,
            }
        end

        -- Save some packet space:
        -- Don't send to a member his own payload
        extra_event.payload = nil

        table.insert(events_to_send, events.pack(extra_event))
        msg_size = msg_size + events.estimate_msgpacked_size(extra_event)
        events_to_send[uri] = true
    end

    local extra_event = events.get(opts.advertise_uri)
    if extra_event == nil and not events_to_send[opts.advertise_uri] then
        local myself = members.myself()
        extra_event = {
            uri = opts.advertise_uri,
            status = opts.ALIVE,
            incarnation = myself.incarnation,
            payload = myself.payload,
            ttl = 1,
        }
    end
    if extra_event ~= nil then
        table.insert(events_to_send, events.pack(extra_event))
        msg_size = msg_size + events.estimate_msgpacked_size(extra_event)
        events_to_send[opts.advertise_uri] = true
    end

    for _, event in events.pairs() do
        if not events_to_send[uri] then
            local evt_size = events.estimate_msgpacked_size(event)
            if #events_to_send+1 == 16 then
                evt_size = evt_size + 2
            end
            local enc_size = opts.encrypted_size(msg_size + evt_size)
            if enc_size > opts.MAX_PACKET_SIZE then
                break
            else
                table.insert(events_to_send, events.pack(event))
                events_to_send[event.uri] = true
                msg_size = msg_size + evt_size
            end
        end
    end

    local random_members = random_permutation(members.filter_excluding(nil))
    for _, member_uri in ipairs(random_members) do
        if not events_to_send[member_uri] then
            local member = members.get(member_uri)
            local event = {
                uri = member_uri,
                status = member.status,
                incarnation = member.incarnation,
                payload = member.payload,
                ttl = 1,
            }

            local evt_size = events.estimate_msgpacked_size(event)
            if #events_to_send+1 == 16 then
                evt_size = evt_size + 2
            end
            local enc_size = opts.encrypted_size(msg_size + evt_size)
            if enc_size > opts.MAX_PACKET_SIZE then
                break
            else
                table.insert(events_to_send, events.pack(event))
                events_to_send[event.uri] = true
                msg_size = msg_size + evt_size
            end
        end
    end

    for k, _ in pairs(events_to_send) do
        if type(k) == 'string' then
            events_to_send[k] = nil
        end
    end

    events.gc()

    local msg_msgpacked = msgpack.encode(msg_raw)
    local msg_encrypted = opts.encrypt(msg_msgpacked)
    local ret = _sock:sendto(host, port, msg_encrypted)
    return ret and ret > 0
end

local function send_anti_entropy(uri, msg_type, remote_tbl)
    -- send to `uri` all local members that are not in `remote_tbl`
    -- well, not all actualy, but all that fits into UDP packet
    checks('string', 'string', 'table')
    local host, port = resolve(uri)
    if not host then
        return false
    end

    local members_to_send = {}
    local msg_raw = {opts.advertise_uri, msg_type, members_to_send, {}}
    local msg_size = #msgpack.encode(msg_raw)

    local random_members = random_permutation(members.filter_excluding(nil))
    for _, member_uri in ipairs(random_members) do
        local member = members.get(member_uri)

        if events.should_overwrite(member, remote_tbl[member_uri]) then
            local member_size = members.estimate_msgpacked_size(member_uri, member)
            if #members_to_send+1 == 16 then
                -- msgpack:
                -- `fixarray` stores an array whose length is upto 15 elements
                -- `array 16` stores an array whose length is upto (2^16)-1 elements
                -- it's 2 bytes larger
                member_size = member_size + 2
            end
            local enc_size = opts.encrypted_size(msg_size + member_size)
            if enc_size > opts.MAX_PACKET_SIZE then
                break
            else
                table.insert(members_to_send, members.pack(member_uri, member))
                msg_size = msg_size + member_size
            end
        end
    end

    local msg_msgpacked = msgpack.encode(msg_raw)
    local msg_encrypted = opts.encrypt(msg_msgpacked)
    local ret = _sock:sendto(host, port, msg_encrypted)
    return ret and ret > 0
end

--
-- RECEIVE FUNCTIONS
--

local function handle_message(msg)
    local ok, decrypted = pcall(opts.decrypt, msg)
    if not ok then
        return false
    end

    local ok, decoded = pcall(msgpack.decode, decrypted)
    if not ok
    or type(decoded) ~= 'table'
    or #decoded ~= 4 then
        -- sometimes misencrypted messages
        -- are successfully decodes
        -- as a valid msgpack with useless data
        return false
    end

    local sender_uri, msg_type, msg_data, new_events = unpack(decoded)

    for _, event in ipairs(new_events or {}) do
        local event = events.unpack(event)

        if event.uri == opts.advertise_uri then
            -- this is a rumor about ourselves
            local myself = members.myself()

            if event.status ~= opts.ALIVE and event.incarnation >= myself.incarnation then
                -- someone thinks that we are dead
                log.info('Refuting the rumor that we are %s', opts.STATUS_NAMES[event.status])
                event.incarnation = event.incarnation + 1
                event.status = opts.ALIVE
                event.payload = myself.payload
                event.ttl = members.count()
            elseif event.incarnation > myself.incarnation then
                -- this branch can be called after quick restart
                -- when the member who PINGs us does not know we were dead
                -- so we increment incarnation and start spreading
                -- the rumor with our current payload

                event.ttl = members.count()
                event.incarnation = event.incarnation + 1
                event.payload = myself.payload
            end
        end

        events.handle(event)
    end

    if msg_type == 'PING' then
        if msg_data.dst == opts.advertise_uri then
            send_message(sender_uri, 'ACK', msg_data)
        elseif sender_uri == opts.advertise_uri then
            -- seems to be a local loop
            -- drop it
        elseif msg_data.dst ~= nil then
            -- forward
            send_message(msg_data.dst, 'PING', msg_data)
        else
            log.error('Message PING without destination uri')
        end
    elseif msg_type == 'ACK' then
        if msg_data.src == opts.advertise_uri then
            table.insert(_ack_cache, msg_data)
            _ack_trigger:broadcast()
        elseif msg_data.src ~= nil then
            -- forward
            send_message(msg_data.src, 'ACK', msg_data)
        else
            log.error('Message ACK without source uri')
        end
    elseif msg_type == 'SYNC_REQ' or msg_type == 'SYNC_ACK' then
        local remote_tbl = {}
        for _, member in ipairs(msg_data) do
            local member_uri, member = members.unpack(member)
            remote_tbl[member_uri] = member

            if events.should_overwrite(member, members.get(member_uri)) then
                events.generate(uri, member.status, member.incarnation, member.payload)
            end
        end

        if msg_type == 'SYNC_REQ' then
            send_anti_entropy(sender_uri, 'SYNC_ACK', remote_tbl)
        else
            _sync_trigger:broadcast()
        end
    elseif msg_type == 'LEAVE' then
        -- just handle the event
        -- do nothing more
    else
        error('Unknown message ' .. tostring(msg_type))
    end

    return true
end

local function handle_message_step()
    local sock = _sock
    local ok = _sock:readable(opts.PROTOCOL_PERIOD_SECONDS)
    -- check that socket was not closed by leave() call yet
    if not ok or sock ~= _sock then
        return
    end

    local msg, from = _sock:recvfrom(opts.MAX_PACKET_SIZE)
    local ok = handle_message(msg)

    if not ok and type(from) == 'table' then
        local uri = nslookup(from.host, from.port)
        local member = nil
        if uri ~= nil then
            member = members.get(uri)
        end
        if member and member.status == opts.DEAD then
            log.info('Broken UDP packet from %s - %s',
                uri, opts.STATUS_NAMES[opts.NONDECRYPTABLE]
            )
            events.generate(uri, opts.NONDECRYPTABLE)
        end
    end
end

local function handle_message_loop()
    local sock = _sock
    while sock == _sock do
        local ok, res = xpcall(handle_message_step, debug.traceback)

        if not ok then
            log.error(res)
        end
    end
end

--
-- PROTOCOL LOOP
--

local function wait_ack(uri, ts, timeout)
    local now
    local deadline = ts + timeout
    repeat
        now = fiber.time64()

        for _, ack in ipairs(_ack_cache) do
            if ack.dst == uri and ack.ts == ts then
                return true
            end
        end
    until (now >= deadline) or not _ack_trigger:wait(tonumber(deadline - now) / 1.0e6)

    return false
end

local _protocol_round_list = {}
local _protocol_round_iter = 1
local function protocol_step()
    local loop_now = fiber.time64()

    -- expire suspected members
    local expiry = loop_now - opts.SUSPECT_TIMEOUT_SECONDS * 1.0e6
    for uri, member in members.pairs() do
        if member.status == opts.SUSPECT and member.timestamp < expiry then
            log.info('Node timed out: %s - %s', uri, opts.STATUS_NAMES[opts.DEAD])
            events.generate(uri, opts.DEAD)
        end
    end

    -- cleanup ack cache
    _ack_cache = {}

    -- prepare to send ping
    _protocol_round_iter = _protocol_round_iter + 1

    if _protocol_round_list[_protocol_round_iter] == nil then
        _protocol_round_iter = 1
        _protocol_round_list = members.filter_excluding('left')
        random_permutation(_protocol_round_list)
    end

    local uri = _protocol_round_list[_protocol_round_iter]
    if uri == nil then
        return
    end

    local msg_data = {
        ts = loop_now,
        src = opts.advertise_uri,
        dst = uri,
    }

    -- try direct ping
    local ok = send_message(uri, 'PING', msg_data)
    if ok and wait_ack(uri, loop_now, opts.ACK_TIMEOUT_SECONDS * 1.0e6) then
        local member = members.get(uri)
        members.set(uri, member.status, member.incarnation) -- update timstamp
        return
    end
    if members.get(uri).status >= opts.DEAD then
        -- still dead, do nothing
        return
    end

    local sent_indirect = 0
    local through_uri_list = random_permutation(
        members.filter_excluding('alive', opts.advertise_uri, uri)
    )
    for _, through_uri in ipairs(through_uri_list) do
        if send_message(through_uri, 'PING', msg_data) then
            sent_indirect = sent_indirect + 1
        end

        if sent_indirect >= opts.NUM_FAILURE_DETECTION_SUBGROUPS then
            break
        end
    end

    if sent_indirect > 0 and wait_ack(uri, loop_now, opts.PROTOCOL_PERIOD_SECONDS * 1.0e6) then
        local member = members.get(uri)
        members.set(uri, member.status, member.incarnation)
        return
    elseif members.get(uri).status == opts.ALIVE then
        log.info('Could not reach node: %s - %s', uri, opts.STATUS_NAMES[opts.SUSPECT])
        events.generate(uri, opts.SUSPECT)
        return
    end
end

local function protocol_loop()
    local sock = _sock
    while sock == _sock do
        local t1 = fiber.time()
        local ok, res = xpcall(protocol_step, debug.traceback)

        if not ok then
            log.error(res)
        end

        local t2 = fiber.time()
        fiber.sleep(t1 + opts.PROTOCOL_PERIOD_SECONDS - t2)
    end
end

--
-- ANTI ENTROPY SYNC
--

local function wait_sync(uri, timeout)
    local now
    local deadline = ts + timeout
    repeat
        now = fiber.time64()

        for _, ack in ipairs(_ack_cache) do
            if ack.dst == uri and ack.ts == ts then
                return true
            end
        end
    until (now >= deadline) or not _ack_trigger:wait(tonumber(deadline - now) / 1.0e6)

    return false
end

local function anti_entropy_step()
    local alive_members = members.filter_excluding('unhealthy', opts.advertise_uri)
    local alive_cnt = #alive_members
    if alive_cnt == 0 then
        return false
    end

    local uri = alive_members[math.random(alive_cnt)]
    send_anti_entropy(uri, 'SYNC_REQ', {})
    return _sync_trigger:wait(opts.PROTOCOL_PERIOD_SECONDS)
end

local function anti_entropy_loop()
    local sock = _sock
    while sock == _sock do
        local ok, res = xpcall(anti_entropy_step, debug.traceback)

        if not ok then
            log.error(res)
            fiber.sleep(opts.PROTOCOL_PERIOD_SECONDS)
        elseif not res then
            fiber.sleep(opts.PROTOCOL_PERIOD_SECONDS)
        else
            fiber.sleep(opts.ANTI_ENTROPY_PERIOD_SECONDS)
        end
    end
end

--
-- BASIC FUNCTIONS
--

local function init(advertise_host, port)
    checks('string', 'number')

    _sock = socket('AF_INET', 'SOCK_DGRAM', 'udp')
    local ok = _sock:bind('0.0.0.0', port)
    if not ok then
        local err = string.format('Socket bind error: %s', _sock:error())
        log.error('%s', err)
        error(err)
    end
    _sock:nonblock(true)
    _sock:setsockopt('SOL_SOCKET', 'SO_BROADCAST', 1)

    local advertise_uri = uri_tools.format({host = advertise_host, service = tostring(port)})
    opts.set_advertise_uri(advertise_uri)
    events.generate(advertise_uri, opts.ALIVE, 1, {})

    fiber.create(protocol_loop)
    fiber.create(handle_message_loop)
    fiber.create(anti_entropy_loop)
    return true
end

local function broadcast(port)
    checks('number')

    local msg_data = {
        ts = fiber.time64(),
        src = opts.advertise_uri,
        dst = opts.advertise_uri,
    }

    local ok, netlist = pcall(network.getifaddrs)
    if not ok then
        log.warn('Membership BROADCAST impossible: %s', netlist)
        return false
    end

    local bcast_sent = false

    for ifa, addr in pairs(netlist) do
        local uri = addr.bcast or addr.inet4
        if uri then
            local uri = string.format('%s:%s', uri, port)
            send_message(uri, 'PING', msg_data)
            log.info('Membership BROADCAST sent to %s', uri)
            bcast_sent = true
        end
    end

    if not bcast_sent then
        log.warn('Membership BROADCAST not sent: No suitable ifaddrs found')
        return false
    end
    return true
end

local function leave()
    -- First, we need to stop all fibers
    local sock = _sock
    _sock = nil

    -- Perform artificial events.generate() and instantly send it
    local event = events.pack({
        uri = opts.advertise_uri,
        status = opts.LEFT,
        incarnation = members.myself().incarnation,
        ttl = members.count(),
    })
    local msg = msgpack.encode({opts.advertise_uri, 'LEAVE', msgpack.NULL, {event}})
    for _, uri in ipairs(members.filter_excluding('unhealthy', opts.advertise_uri)) do
        local host, port = resolve(uri)
        sock:sendto(host, port, msg)
    end

    sock:close()
    members.clear()
    events.clear()
    table.clear(_protocol_round_list)
    return true
end

function _member_pack(uri, member)
    checks('string', '?table')
    if not member then
        return nil
    end
    return {
        uri = uri,
        status = opts.STATUS_NAMES[member.status] or tostring(member.status),
        payload = member.payload or {},
        incarnation = member.incarnation,
        timestamp = member.timestamp,
    }
end

function get_members()
    local ret = {}
    for uri, member in members.pairs() do
        ret[uri] = _member_pack(uri, member)
    end
    return ret
end

local function get_member(uri)
    local member = members.get(uri)
    return _member_pack(uri, member)
end

local function get_myself()
    local myself = members.myself()
    return _member_pack(opts.advertise_uri, myself)
end

local function add_member(uri)
    checks('string')
    local parts = uri_tools.parse(uri)
    if not parts then
        return nil, 'parse error'
    end

    local uri = uri_tools.format({host = parts.host, service = parts.service})
    local member = members.get(uri)
    local incarnation = nil
    if member and member.status == opts.LEFT then
        incarnation = member.incarnation + 1
    end

    events.generate(uri, opts.ALIVE, incarnation)

    return true
end

local function probe_uri(uri)
    checks('string')
    local parts = uri_tools.parse(uri)
    if not parts then
        return nil, 'parse error'
    end

    local uri = uri_tools.format({host = parts.host, service = parts.service})

    local loop_now = fiber.time64()
    local msg_data = {
        ts = loop_now,
        src = opts.advertise_uri,
        dst = uri,
    }

    local ok = send_message(uri, 'PING', msg_data)
    if not ok then
        return nil, 'ping was not sent'
    end

    local ack = wait_ack(uri, loop_now, opts.ACK_TIMEOUT_SECONDS * 1.0e6)
    if not ack then
        return nil, 'no responce'
    end

    return true
end

local function set_payload(key, value)
    checks('string', '?')
    local myself = members.myself()
    local payload = myself.payload
    if payload[key] == value then
        return true
    end

    payload[key] = value
    events.generate(
        opts.advertise_uri,
        myself.status,
        myself.incarnation + 1,
        payload
    )
    return true
end

return {
    init = init,
    leave = leave,
    members = get_members,
    broadcast = broadcast,
    pairs = function() return pairs(get_members()) end,
    myself = get_myself,
    probe_uri = probe_uri,
    add_member = add_member,
    get_member = get_member,
    set_payload = set_payload,
    get_encryption_key = opts.get_encryption_key,
    set_encryption_key = opts.set_encryption_key,
    subscribe = events.subscribe,
    unsubscribe = events.unsubscribe,
}
