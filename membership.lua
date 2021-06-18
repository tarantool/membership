--- Membership library for Tarantool based on a gossip protocol.
-- This library builds a mesh from multiple tarantool instances. The
-- mesh monitors itself, helps members discover everyone else and get
-- notified about their status changes with low latency.
--
-- It is built upon the ideas from consul, or, more precisely,
-- the [SWIM](swim-paper.pdf) algorithm.
--
-- Membership module works over UDP protocol and can operate
-- even before tarantool [`box.cfg`](https://tarantool.io/en/doc/latest/book/box/box_cfg/) was initialized.
-- @module membership

local log = require('log')
local uri_tools = require('uri')
local fiber = require('fiber')
local checks = require('checks')
local socket = require('socket')
local msgpack = require('msgpack')

for _, m in ipairs({
    'membership.stash',
    'membership.events',
    'membership.options',
    'membership.members',
    'membership.network',
}) do
    package.loaded[m] = nil
end

local opts = require('membership.options')
local stash = require('membership.stash')
local events = require('membership.events')
local members = require('membership.members')
local network = require('membership.network')

local _sync_trigger = stash.get('_sync_trigger') or fiber.cond()
local _ack_trigger = stash.get('_ack_trigger') or fiber.cond()
local _ack_cache = stash.get('_ack_cache') or {}
local _resolve_cache = stash.get('_resolve_cache') or {}

local function after_reload()
    stash.set('_ack_cache', _ack_cache)
    stash.set('_ack_trigger', _ack_trigger)
    stash.set('_sync_trigger', _sync_trigger)
    stash.set('_resolve_cache', _resolve_cache)
end

local _sock = stash.get('_sock')
local advertise_uri = stash.get('advertise_uri')

local function resolve(uri)
    checks('string')

    if _resolve_cache[uri] then
        local member = members.get(uri)
        if member and member.status == opts.ALIVE then
            return _resolve_cache[uri]
        else
            _resolve_cache[uri] = nil
        end
    end

    local parts = uri_tools.parse(uri)
    if not parts then
        if _resolve_cache[uri] == nil then
            _resolve_cache[uri] = false
            log.warn("parse error (%s)", uri)
        end
        return nil
    end

    local addrinfo, err = socket.getaddrinfo(
        parts.host, parts.service,
        {family='AF_INET', type='SOCK_DGRAM'}
    )
    if addrinfo == nil then
        if _resolve_cache[uri] == nil then
            _resolve_cache[uri] = false
            log.warn("%s (%s)", err or 'getaddrinfo: Unknown error', uri)
        end
        return nil
    end

    _resolve_cache[uri] = addrinfo[1]
    return addrinfo[1]
end

local function nslookup(host, port)
    checks('string', 'number')

    for uri, cache in pairs(_resolve_cache) do
        if cache
        and cache.host == host
        and cache.port == port
        then
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
-- MESSAGE SENDING
--

local function send_message(uri, msg_type, msg_data)
    checks('string', 'string', 'table')
    local addr = resolve(uri)
    if not addr then
        return false
    end

    local events_to_send = {}
    local msg_raw = {advertise_uri, msg_type, msg_data, events_to_send}
    local msg_size = #msgpack.encode(msg_raw)

    -- Always tell the recipient what current instance thinks about it.
    -- It's necessary to refute rumors faster.
    local member = members.get(uri)
    if member then
        local extra_event = events.get(uri) or {
            uri = uri,
            status = member.status,
            incarnation = member.incarnation,
            ttl = 1,
        }
        table.insert(events_to_send, events.pack(extra_event))
        msg_size = msg_size + events.estimate_msgpacked_size(extra_event)
        events_to_send[uri] = true
    end

    -- And always tell about myself to speed up payload dissemination.
    if not events_to_send[advertise_uri] then
        local myself = members.get(advertise_uri)
        local extra_event = events.get(advertise_uri) or {
            uri = advertise_uri,
            status = myself.status,
            incarnation = myself.incarnation,
            payload = myself.payload,
            ttl = 1,
        }
        table.insert(events_to_send, events.pack(extra_event))
        msg_size = msg_size + events.estimate_msgpacked_size(extra_event)
        events_to_send[advertise_uri] = true
    end

    for uri, event in events.pairs() do
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
                events_to_send[uri] = true
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
                events_to_send[member_uri] = true
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
    local ret = _sock:sendto(addr.host, addr.port, msg_encrypted)
    return ret and ret > 0
end

local function send_anti_entropy(uri, msg_type, remote_tbl)
    -- send to `uri` all local members that are not in `remote_tbl`
    -- well, not all actualy, but all that fits into UDP packet
    checks('string', 'string', 'table')
    local addr = resolve(uri)
    if not addr then
        return false
    end

    local members_to_send = {}
    local msg_raw = {advertise_uri, msg_type, members_to_send, {}}
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
    local ret = _sock:sendto(addr.host, addr.port, msg_encrypted)
    return ret and ret > 0
end

--
-- MESSAGE RECEIVING
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

    local sender_uri = decoded[1]
    local msg_type = decoded[2]
    local msg_data = decoded[3]
    local new_events = decoded[4]

    for _, event in ipairs(new_events or {}) do
        local event = events.unpack(event)

        if event.uri == advertise_uri then
            -- this is a rumor about ourselves
            local myself = members.get(advertise_uri)

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

    -- luacheck:ignore 542
    if msg_type == 'PING' then
        if msg_data.dst == advertise_uri then
            -- set ack timestamp
            msg_data.ats = fiber.time64()
            send_message(sender_uri, 'ACK', msg_data)
        elseif sender_uri == advertise_uri then
            -- seems to be a local loop
            -- drop it
        elseif msg_data.dst ~= nil then
            -- forward
            send_message(msg_data.dst, 'PING', msg_data)
        else
            log.error('Message PING without destination uri')
        end
    elseif msg_type == 'ACK' then
        if msg_data.src == advertise_uri then
            -- set receive timestamp
            msg_data.rts = fiber.time64()
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
                events.generate(member_uri, member.status, member.incarnation, member.payload)
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

local function _handle_message_step()
    local ok = _sock:readable(opts.PROTOCOL_PERIOD_SECONDS)
    if not ok then
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

local function handle_message_step()
    local ok, res = xpcall(_handle_message_step, debug.traceback)
    fiber.testcancel()

    if not ok then
        log.error(res)
    end
end

--
-- PROTOCOL LOOP
--

local function wait_ack(uri, ts, timeout)
    local now
    local deadline = ts + timeout
    repeat
        fiber.testcancel()
        now = fiber.time64()

        for _, ack in ipairs(_ack_cache) do
            if ack.dst == uri and ack.ts == ts then
                return ack
            end
        end
    until (now >= deadline) or not _ack_trigger:wait(tonumber(deadline - now) / 1.0e6)

    return nil
end

local function _get_clock_delta(ack_data)
    checks('table')
    local ack_ts = tonumber(ack_data.ats)
    local recv_ts = tonumber(ack_data.rts)
    local start_ts = tonumber(ack_data.ts)

    if ack_ts == nil or recv_ts == nil or start_ts == nil then
        return nil
    end

    return ack_ts - (recv_ts + start_ts) / 2
end

local _protocol_round_list = {}
local _protocol_round_iter = 1
local function _protocol_step()
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
    table.clear(_ack_cache)

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
        src = advertise_uri,
        dst = uri,
    }

    -- try direct ping
    if send_message(uri, 'PING', msg_data) then
        local ack_data = wait_ack(uri, loop_now, opts.ACK_TIMEOUT_SECONDS * 1.0e6)
        if ack_data ~= nil then
            local member = members.get(uri)
            -- calculate time difference between local time and member time
            local delta = _get_clock_delta(ack_data)
            members.set(uri, member.status, member.incarnation, { clock_delta = delta }) -- update timstamp
            return
        end
    end
    if members.get(uri).status >= opts.DEAD then
        -- still dead, do nothing
        return
    end

    local sent_indirect = 0
    local through_uri_list = random_permutation(
        members.filter_excluding('unhealthy', advertise_uri, uri)
    )
    for _, through_uri in ipairs(through_uri_list) do
        if sent_indirect >= opts.NUM_FAILURE_DETECTION_SUBGROUPS then
            break
        end

        if send_message(through_uri, 'PING', msg_data) then
            sent_indirect = sent_indirect + 1
        end
    end

    local ack_data
    if sent_indirect > 0 then
        ack_data = wait_ack(uri, loop_now, opts.PROTOCOL_PERIOD_SECONDS * 1.0e6)
    end
    if sent_indirect > 0 and ack_data ~= nil then
        local member = members.get(uri)
        -- calculate time difference between local time and member time
        local delta = _get_clock_delta(ack_data)
        members.set(uri, member.status, member.incarnation, { clock_delta = delta })
        return
    elseif members.get(uri).status == opts.ALIVE then
        if opts.SUSPICIOUSNESS == false then
            log.debug('Could not reach node: %s (ignored)', uri)
        else
            log.info('Could not reach node: %s - %s', uri,
                opts.STATUS_NAMES[opts.SUSPECT]
            )
            events.generate(uri, opts.SUSPECT)
        end
        return
    end
end

local function protocol_step()
    local t1 = fiber.clock()
    local ok, res = xpcall(_protocol_step, debug.traceback)
    fiber.testcancel()

    if not ok then
        log.error(res)
    end

    local t2 = fiber.clock()
    fiber.sleep(t1 + opts.PROTOCOL_PERIOD_SECONDS - t2)
end

--
-- ANTI ENTROPY SYNC
--

local function _anti_entropy_step()
    local alive_members = members.filter_excluding('unhealthy', opts.advertise_uri)
    local alive_cnt = #alive_members
    if alive_cnt == 0 then
        return false
    end

    local uri = alive_members[math.random(alive_cnt)]
    send_anti_entropy(uri, 'SYNC_REQ', {})
    return _sync_trigger:wait(opts.PROTOCOL_PERIOD_SECONDS)
end

local function anti_entropy_step()
    local ok, res = xpcall(_anti_entropy_step, debug.traceback)
    fiber.testcancel()

    if not ok then
        log.error(res)
        fiber.sleep(opts.PROTOCOL_PERIOD_SECONDS)
    elseif not res then
        fiber.sleep(opts.PROTOCOL_PERIOD_SECONDS)
    else
        fiber.sleep(opts.ANTI_ENTROPY_PERIOD_SECONDS)
    end
end

--
-- PUBLIC API
--

--- Initialize the membership module.
-- Bind a UDP socket to `0.0.0.0:<port>`,
-- set the `advertise_uri` parameter to `<advertise_host>:<port>`,
-- and `incarnation` to `1`.
--
-- The `init()` function can be called several times,
-- the old socket will be closed and a new one opened.
--
-- If the `advertise_uri` changes during the next `init()`,
-- the old URI is considered `DEAD`.
-- In order to leave the group gracefully use the @{leave} function.
--
-- @function init
-- @tparam string advertise_host
--   either hostname or IP address being advertised to other members
-- @tparam number port
--   UDP port to bind and advertise
-- @treturn boolean `true`
-- @raise Socket bind error
local function init(advertise_host, port)
    checks('string', 'number')

    if _sock == nil or _sock:name().port ~= port then
        local sock = socket('AF_INET', 'SOCK_DGRAM', 'udp')
        local ok = sock:bind('0.0.0.0', port)
        if not ok then
            local err = string.format(
                'Socket bind error (%s/udp): %s',
                port, sock:error()
            )
            log.error(err)
            error(err, 2)
        end
        sock:nonblock(true)
        sock:setsockopt('SOL_SOCKET', 'SO_BROADCAST', 1)

        if _sock then
            _sock:close()
        end

        _sock = sock
    end

    advertise_uri = uri_tools.format({
        host = advertise_host,
        service = tostring(port)
    })
    events.generate(advertise_uri, opts.ALIVE, 1, {})

    stash.fiber_cancel('protocol_step')
    stash.fiber_cancel('anti_entropy_step')
    stash.fiber_cancel('handle_message_step')
    stash.fiber_new('protocol_step'):name('membership.main')
    stash.fiber_new('anti_entropy_step'):name('membership.entropy')
    stash.fiber_new('handle_message_step'):name('membership.handle')
    stash.set('advertise_uri', advertise_uri)
    stash.set('_sock', _sock)

    return true
end


--- Discover members in local network.
-- Send UDP broadcast to all networks
-- discovered by `getifaddrs()` C call
-- @function broadcast
-- @return[1] `true` if broadcast was sent
-- @return[2] `false` if `getifaddrs()` fails.
local function broadcast(port)
    checks('number')

    local msg_data = {
        ts = fiber.time64(),
        src = advertise_uri,
        dst = advertise_uri,
    }

    local ok, netlist = pcall(network.getifaddrs)
    if not ok then
        log.warn('Membership BROADCAST impossible: %s', netlist)
        return false
    end

    local bcast_sent = false

    for _, addr in pairs(netlist) do
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

--- Gracefully leave the membership group.
-- The node will be marked with the status `left`
-- and no other members will ever try to reconnect it.
-- @function leave
-- @treturn boolean
--  `true` if call succeeds,
--  `false` if member has already left.
local function leave()
    if _sock == nil then
        return false
    end

    -- First, we need to stop all fibers
    stash.fiber_cancel('protocol_step')
    stash.fiber_cancel('anti_entropy_step')
    stash.fiber_cancel('handle_message_step')

    -- Perform artificial events.generate() and instantly send it
    local myself = members.get(advertise_uri)
    local event = events.pack({
        uri = advertise_uri,
        status = opts.LEFT,
        incarnation = myself.incarnation,
        ttl = members.count(),
    })
    local msg_msgpacked = msgpack.encode({advertise_uri, 'LEAVE', msgpack.NULL, {event}})
    local msg_encrypted = opts.encrypt(msg_msgpacked)
    for _, uri in ipairs(members.filter_excluding('unhealthy', advertise_uri)) do
        local addr = resolve(uri)
        if addr then
            _sock:sendto(addr.host, addr.port, msg_encrypted)
        end
    end

    _sock:close()
    _sock = nil
    stash.set('_sock', nil)

    advertise_uri = nil
    stash.set('advertise_uri', nil)

    members.clear()
    events.clear()
    table.clear(_protocol_round_list)
    return true
end

--- Member data structure.
-- A member is represented by the table with the following fields:
--
-- @table MemberInfo
-- @tfield string uri `<advertise_uri>` of a member
--
-- @tfield string status a string that takes one of the values below
--
-- * `alive`: a member that replies to ping-messages is alive and well.
-- * `suspect`: if any member in the group cannot get a reply from any other member, the first member asks
-- three other alive members to send a ping-message to the member in question. If there is no response,
-- the latter becomes a suspect.
-- * `dead`: a `suspect` becomes `dead` after a timeout.
-- * `left`: a member gets the `left` status after executing the @{leave} function.
--
-- @tfield number incarnation a value incremented every time
-- the instance status changes, or its payload is updated
--
-- @tfield table payload an auxiliary data that can be used by various modules
--
-- @tfield number timestamp a value of fiber.time64()
-- which corresponds to the last update of status or incarnation;
-- it is always local and does not depend on other members’ clock setting.
--
-- @tfield number clock_delta difference of clocks (fiber.time64) between self and peer
-- calculated during ping/ack protocol step or while probe_uri call
--
-- @usage tarantool> membership.myself()
-- ---
-- uri: "localhost:33001"
-- status: "alive"
-- incarnation: 1
-- payload:
--     uuid: "2d00c500-2570-4019-bfcc-ab25e5096b73"
-- timestamp: 1522427330993752
-- clock_delta: 700
-- ...
local function _member_pack(uri, member)
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
        clock_delta = member.clock_delta,
    }
end

--- Obtain all members known to the current instance.
--
-- Editing this table has no effect.
-- @function members
-- @treturn table a table with URIs as keys and corresponding @{MemberInfo} as values.
local function get_members()
    local ret = {}
    for uri, member in members.pairs() do
        ret[uri] = _member_pack(uri, member)
    end
    return ret
end

--- Iterate over members.
-- A shorthand for `pairs(membership.members())`.
-- @function pairs
-- @return Lua iterator
-- @usage for uri, member in membership.pairs() do end

--- Get info about member with the given URI.
-- @function get_member
-- @tparam string uri `<advertise_uri>` of member of interest
-- @treturn MemberInfo the member data structure of the instance with the given URI.
local function get_member(uri)
    local member = members.get(uri)
    return _member_pack(uri, member)
end

--- Get info about the current instance.
-- @function myself
-- @treturn MemberInfo the member data structure of the current instance.
local function get_myself()
    return _member_pack(
        advertise_uri,
        members.get(advertise_uri)
    )
end

--- Add a member to the group.
-- Also propagate this event to other members.
-- Adding a member to a single instance is enough
-- as everybody else in the group will receive the update with time.
-- It does not matter who adds whom.
--
-- **Warning:** The gossip protocol guarantees
-- that every member in the group becomes aware
-- of any status change in two communication cycles.
--
-- @function add_member
-- @tparam string uri `<advertise_uri>` of member to add
-- @treturn true|nil
-- @treturn ?string Possible errors:
--
-- * `"parse error"` - if the URI can not be parsed
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

--- Send a ping to a member.
-- Send a ping-message to a member to make sure it is in the group.
--
-- If the member responds but not in the group, it is added.
--
-- If it already is in the group, nothing happens.
--
-- **Warning:** When destination IP can be resolved in several diffent
-- ways (by different hostnames) it is possible that `probe_uri()` function returns
-- `"no response"` error, but the member is added to the group with another URI,
-- corresponding to its `<advertise_uri>`.
--
-- @function probe_uri
-- @tparam string uri `<advertise_uri>` of member to ping
-- @treturn true|nil
-- @treturn ?string Possible errors:
--
-- * `"parse error"` - if the URI can not be parsed
-- * `"ping was not sent"` - if hostname could not be reloved
-- * `"no reponce"` - if member does not responf within 0.2 seconds
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
        src = advertise_uri,
        dst = uri,
    }

    local ok = send_message(uri, 'PING', msg_data)
    if not ok then
        return nil, 'ping was not sent'
    end

    local ack_data = wait_ack(uri, loop_now, opts.ACK_TIMEOUT_SECONDS * 1.0e6)
    if ack_data == nil then
        return nil, 'no response'
    end

    local member = members.get(uri)
    if member ~= nil then
        local delta = _get_clock_delta(ack_data)
        members.set(uri, member.status, member.incarnation, { clock_delta = delta }) -- update timstamp
    end

    return true
end

--- Update payload and disseminate it along with the member status.
-- Also increments `incarnation`.
-- @function set_payload
-- @tparam string key a key to set in payload table
-- @param value auxiliary data
local function set_payload(key, value)
    checks('string', '?')
    local myself = members.get(advertise_uri)
    local payload = myself.payload
    if payload[key] == value then
        return true
    end

    payload[key] = value
    events.generate(
        advertise_uri,
        myself.status,
        myself.incarnation + 1,
        payload
    )
    return true
end

do -- finish module loading
    opts.after_reload()
    events.after_reload()
    members.after_reload()
    after_reload()
    stash.set('protocol_step', protocol_step)
    stash.set('anti_entropy_step', anti_entropy_step)
    stash.set('handle_message_step', handle_message_step)
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

--- Encryption Functions.
-- The encryption is handled by the
-- [`crypto.cipher.aes256.cbc`](https://tarantool.io/en/doc/latest/reference/reference_lua/crypto/)
-- Tarantool module.
--
-- For proper communication, all members must be configured
-- to use the same encryption key. Otherwise, members report
-- either `dead` or `non-decryptable` in their status.
-- @section encryption

    --- Retrieve the encryption key that is currently in use.
    -- @function get_encryption_key
    -- @treturn string encryption key
    get_encryption_key = assert(opts.get_encryption_key),

    --- Set the key used for low-level message encryption.
    -- The key is either trimmed or padded automatically to be exactly 32 bytes.
    -- If the `key` value is `nil`, the encryption is disabled.
    --
    -- @function set_encryption_key
    -- @tparam string key encryption key
    -- @treturn nil
    set_encryption_key = assert(opts.set_encryption_key),

--- Subscription Functions.
-- A subscription is implemented with Tarantool built-in
-- [`fiber.cond`](https://tarantool.io/en/doc/latest/reference/reference_lua/fiber/#fiber-cond)
-- objects.
-- @section subsrcription

    --- Subscribe for updates in the members table.
    -- @function subscribe
    -- @return `fiber.cond` object which is
    -- broadcasted whenever the members table changes
    subscribe = assert(events.subscribe),

    --- Unsubscribe from membership updates.
    -- Remove subscription on `cond` object.
    --
    -- If parameter passed is already unsubscribed o invaled nothing happens.
    -- @function unsubscribe
    -- @param cond `fiber.cond` object obtained from `subscribe` function
    -- @treturn nil
    unsubscribe = assert(events.unsubscribe),
}
