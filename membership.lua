#!/usr/bin/env tarantool

local log = require('log')
local json = require('json')
local pool = require('pool')
local fiber = require('fiber')
local checks = require('checks')

local opts = require('membership.options')
local events = require('membership.events')
local members = require('membership.members')

local MESSAGE_PING = 1
local MESSAGE_ACK = 2

local _msg_channel = fiber.channel(1000)
local _ack_trigger = fiber.cond()
local _ack_cache = {}
-- local _ping_cache = {}

local function send_message(uri, msg_type, msg_data)
    checks("string", "number", "?")
    local conn, err = pool.connect(uri)
    if err then
        return false, err
    end

    local events_to_send = {}
    local expired = {}

    local extra_event = events.get(uri) or {
        uri = uri,
        status = members.get(uri).status,
        incarnation = members.get(uri).incarnation,
        ttl = 1,
    }
    table.insert(events_to_send, events.pack(extra_event))

    local extra_event = events.get(opts.advertise_uri) or {
        uri = opts.advertise_uri,
        status = opts.ALIVE,
        incarnation = members.myself().incarnation,
        ttl = 1,
    }
    table.insert(events_to_send, events.pack(extra_event))

    for _, event in events.pairs() do
        if #events_to_send > opts.EVENT_PIGGYBACK_LIMIT then
            break
        end

        if event.uri == uri or event.uri == opts.advertise_uri then
            -- already packed
        else
            table.insert(events_to_send, events.pack(event))
        end
    end

    events.gc()

    local ok, err = pcall(
        conn.call,
        conn,
        'membership_recv_message',
        {opts.advertise_uri, msg_type, msg_data, events_to_send},
        {timeout = opts.ACK_TIMEOUT_SECONDS}
    )

    return ok, err
end


local function handle_message(sender_uri, msg_type, msg_data, new_events)

    for _, event in ipairs(new_events) do
        events.handle(events.unpack(event))
    end

    if msg_type == MESSAGE_PING then
        send_message(sender_uri, MESSAGE_ACK, msg_data)
    -- elseif msg_type == MESSAGE_INDIRECT_PING then

    elseif msg_type == MESSAGE_ACK then
        table.insert(_ack_cache, {uri = sender_uri, timestamp = msg_data})
        _ack_trigger:broadcast()
    end
end

local function handle_message_loop()
    while true do
        local message = _msg_channel:get()
        -- handle_message(unpack(message))
        local ok, err = xpcall(handle_message, debug.traceback, unpack(message))

        if not ok then
            log.error(err)
        end
    end
end

function membership_recv_message(sender_uri, typ, data, new_events)
    _msg_channel:put({sender_uri, typ, data, new_events})
end


-- local function timeout_ping_requests()
--     local now = fiber.time64()
--     local timeout = opts.PROTOCOL_PERIOD_SECONDS * 1.0e6
--     while true do
--         for i = #_ping_cache, 1, -1 do
--             local ping = _ping_cache[i]
--             if now > ping.timestamp + timeout then
--                 table.remove(_ping_cache, i)
--             end
--         end

--         fiber.sleep(1)
--     end
-- end

local function wait_ack(uri, timestamp)
    local now
    local timeout = opts.ACK_TIMEOUT_SECONDS * 1.0e6
    local deadline = timestamp + timeout
    repeat
        now = fiber.time64()

        for _, ack in ipairs(_ack_cache) do
            if ack.uri == uri and ack.timestamp >= timestamp then
                return true
            end
        end
    until (now >= deadline) or not _ack_trigger:wait(tonumber(deadline - now) / 1.0e6)

    return false
end

local function protocol_step()
    local uri = members.next_shuffled_uri()

    if uri == nil then
        return
    end

    local ts = fiber.time64()
    local ok, _ = send_message(uri, MESSAGE_PING, ts)

    if ok and wait_ack(uri, ts) then
        -- ok
        return
    elseif members.get(uri).status == opts.DEAD then
        -- still dead, do nothing
        return
    end

    local ts = fiber.time64()
    local through_uri_list = members.random_alive_uri_list(opts.NUM_FAILURE_DETECTION_SUBGROUPS)

    for _, through_uri in ipairs(through_uri_list) do
        -- todo indirect ping
        -- send_message(through_uri, MESSAGE_INDIRECT_PING, uri)
    end

    if wait_ack(uri, ts) then
        -- ok
        return
    elseif members.get(uri).status == opts.ALIVE then
        log.info("Couldn't reach node: %s", uri)
        events.generate(uri, opts.SUSPECT)
        return
    end
end

local function expire()
    local now = fiber.time64()
    local expiry = now - opts.SUSPECT_TIMEOUT_SECONDS * 1.0e6

    for uri, member in members.pairs() do
        if member.status == opts.SUSPECT and member.timestamp < expiry then
            log.info('Suspected node timeout.')
            events.generate(uri, opts.DEAD)
        end
    end

    local expiry = now - opts.ACK_EXPIRE_SECONDS * 1.0e6
    for i = #_ack_cache, 1, -1 do
        local ack = _ack_cache[i]

        if ack.timestamp < expiry then
            table.remove(_ack_cache, i)
        end
    end
end

local function protocol_loop()
    while true do
        local t1 = fiber.time()
        local ok, res = xpcall(protocol_step, debug.traceback)

        if not ok then
            log.error(res)
        end

        expire()
        local t2 = fiber.time()

        -- sleep till next period
        fiber.sleep(t1 + opts.PROTOCOL_PERIOD_SECONDS - t2)
    end
end

function membership_recv_anti_entropy(remote_tbl)
    for uri, member in pairs(remote_tbl) do
        if events.should_overwrite(member, members.get(uri)) then
            events.generate(uri, member.status, member.incarnation)
        end
    end

    local ret = {}
    for uri, member in members.pairs() do
        if events.should_overwrite(member, remote_tbl[uri]) then
            ret[uri] = {
                status = member.status,
                incarnation = member.incarnation,
            }
        end
    end
    return ret
end

local function anti_entropy_step()
    local uri = members.random_alive_uri_list(1)[1]
    if uri == nil then
        return false
    end

    --log.info("anti entropy sync with: " .. tostring(uri))

    local conn, err = pool.connect(uri)

    if err ~= nil then
        log.error("Failed to do anti-entropy sync: %s", err)
        return false, err
    end

    local local_tbl = {}
    for uri, member in members.pairs() do
        -- do not send excess information, only uri, status, incarnation
        local_tbl[uri] = {
            status = member.status,
            incarnation = member.incarnation,
        }
    end

    local ok, remote_tbl = pcall(
        conn.call,
        conn,
        'membership_recv_anti_entropy',
        {local_tbl},
        {timeout = opts.PROTOCOL_PERIOD_SECONDS}
    )

    if not ok then
        local err = remote_tbl
        log.error("Failed to do anti-entropy sync: %s", err)
        return false, err
    end

    for uri, member in pairs(remote_tbl) do
        if events.should_overwrite(member, members.get(uri)) then
            events.generate(uri, member.status, member.incarnation)
        end
    end
    
    return true
end

local function anti_entropy_loop()
    local initial_sync = true

    while true do
        local sync_performed, err = anti_entropy_step()

        if err ~= nil then
            log.info("Anti entropy sync failed: %s", err)
        elseif sync_performed and initial_sync then
            initial_sync = false
        end

        if initial_sync then
            fiber.sleep(opts.PROTOCOL_PERIOD_SECONDS)
        else
            fiber.sleep(opts.ANTI_ENTROPY_PERIOD_SECONDS)
        end
    end
end

local function init(advertise_uri)
    checks("string")
    opts.set_advertise_uri(advertise_uri)

    events.generate(advertise_uri, opts.ALIVE)

    fiber.create(anti_entropy_loop)
    fiber.create(protocol_loop)
    fiber.create(handle_message_loop)
    -- fiber.create(timeout_ping_requests)
end

local function get_advertise_uri()
    return opts.advertise_uri
end

local function add_member(uri)
    checks("string")
    events.generate(uri, opts.ALIVE)
end

return {
    init = init,
    pairs = members.pairs,
    members = members.all,
    add_member = add_member,
    get_advertise_uri = get_advertise_uri
}
