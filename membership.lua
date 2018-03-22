#!/usr/bin/env tarantool

local log = require('log')
local json = require('json')
local pool = require('pool')
local fiber = require('fiber')
local checks = require('checks')

local PROTOCOL_PERIOD_SECONDS = 1.000 -- denoted as `T'` in SWIM paper
local ACK_TIMEOUT_SECONDS = 0.200 -- ack timeout
local ANTI_ENTROPY_PERIOD_SECONDS = 10
local ACK_EXPIRE_SECONDS = 10

local SUSPECT_TIMEOUT_SECONDS = 3
local NUM_FAILURE_DETECTION_SUBGROUPS = 3 -- denoted as `k` in SWIM paper

local EVENT_PIGGYBACK_LIMIT = 10

local function _table_turn_out(tbl)
    local ret = {}
    for i, v in ipairs(tbl) do
        ret[v] = i
    end
    return ret
end
-- STATUS_NAMES are ordered according to override priority
local STATUS_NAMES = {'alive', 'suspect', 'dead'}
local MESSAGE_NAMES = {'ping', 'ack', 'indirect_ping'}
local STATUS = _table_turn_out(STATUS_NAMES)
local MESSAGE = _table_turn_out(MESSAGE_NAMES)

local STATUS_ALIVE = STATUS.alive
local STATUS_SUSPECT = STATUS.suspect
local STATUS_DEAD = STATUS.dead

local EVENT_ALIVE = STATUS.alive
local EVENT_SUSPECT = STATUS.suspect
local EVENT_DEAD = STATUS.dead

local MESSAGE_PING = MESSAGE.ping
local MESSAGE_INDIRECT_PING = MESSAGE.indirect_ping
local MESSAGE_ACK = MESSAGE.ack

local function _table_count(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

local vars = {}
vars.members = {
    -- [uri] = {
    --     status = number,
    --     incarnation = number,
    --     timestamp = time64,
    -- }
}
vars.events = {
    -- [uri] = {
    --     uri = string,
    --     status = number,
    --     incarnation = number,
    --     ttl = number,
    -- }
}

vars.shuffled_members = {}
vars.shuffled_member = 1

local suspects = {}

local indirect_ping_requests = {}

vars.advertise_uri = nil
vars.message_channel = fiber.channel(1000)
vars.ack_condition = fiber.cond()
vars.ack_messages = {}

local function member_pairs()
    local res = {}

    for uri, member in pairs(vars.members) do
        res[uri] = {
            uri = uri,
            status = STATUS_NAMES[member.status],
            incarnation = member.incarnation,
        }
    end

    return pairs(res)
end

local function get_incarnation(uri)
    return vars.members[uri].incarnation
end

local function set_incarnation(uri, value)
    vars.members[uri].incarnation = value
end

local function set_status(uri, status)
    local old_status = vars.members[uri].status
    vars.members[uri].status = status

    -- TODO callback
end

local function get_status(uri)
    return vars.members[uri].status
end


local function select_next_member()
    if vars.shuffled_member > #vars.shuffled_members then
        local shuffled = {}
        for uri, _ in pairs(vars.members) do
            if uri ~= vars.advertise_uri then
                table.insert(shuffled, math.random(#shuffled+1), uri)
            end
        end
        vars.shuffled_members = shuffled
        vars.shuffled_member = 1

        if #shuffled == 0 then
            return nil
        end
    end

    local res = vars.shuffled_members[vars.shuffled_member]
    vars.shuffled_member = vars.shuffled_member + 1
    return res
end

local function select_random_live_member()
    local live = {}

    for _, k in ipairs(vars.shuffled_members) do
        if get_status(k) == STATUS_ALIVE then
            table.insert(live, k)
        end
    end

    if #live == 0 then
        return nil
    end

    return live[math.random(#live)]
end

local function unpack_event(event)
    return {
        uri = event[1],
        status = event[2],
        incarnation = event[3],
        ttl = event[4],
    }
end

local function pack_event(event)
    return {
        event.uri,
        event.status,
        event.incarnation,
        event.ttl,
    }
end

local function send_message(uri, msg_type, msg_data)
    checks("string", "number", "?")
    local conn, err = pool.connect(uri)
    if err then
        return false, err
    end

    local events_to_send = {}
    local expired = {}
    local extra_event

    extra_event = vars.events[uri] or {
        uri = uri,
        status = vars.members[uri].status,
        incarnation = vars.members[uri].incarnation,
        ttl = 0,
    }
    table.insert(events_to_send, pack_event(extra_event))

    extra_event = vars.events[vars.advertise_uri] or {
        uri = vars.advertise_uri,
        status = STATUS.alive,
        incarnation = vars.members[vars.advertise_uri].incarnation,
        ttl = 0,
    }
    table.insert(events_to_send, pack_event(extra_event))

    for _, event in pairs(vars.events) do
        if #events_to_send > EVENT_PIGGYBACK_LIMIT then
            break
        end

        event.ttl = event.ttl - 1
        if event.ttl <= 0 then
            table.insert(expired, event.uri)
        end
        if event.uri ~= uri then
            table.insert(events_to_send, pack_event(event))
        end
    end

    for _, uri in ipairs(expired) do
        -- log.info("expiring event for %s", uri)
        vars.events[uri] = nil
    end

    local ok, err = pcall(
        conn.call,
        conn,
        'membership_recv_message',
        {vars.advertise_uri, msg_type, msg_data, events_to_send},
        {timeout=PROTOCOL_PERIOD_SECONDS}
    )

    return ok, err
end

local function handle_event(event)
    local uri = event.uri

    if event.uri == vars.advertise_uri then
        -- this is a rumor about ourselves
        local myself = vars.members[vars.advertise_uri]

        if event.status ~= STATUS.alive then
            if not myself or event.incarnation >= myself.incarnation then
                -- someone thinks that we are dead
                log.info("Refuting the rumor that we are dead")
                event.incarnation = event.incarnation + 1
                event.status = STATUS.alive
                event.ttl = _table_count(vars.members)
            end
        elseif not myself or event.incarnation > myself.incarnation then
            event.ttl = _table_count(vars.members)
        end
    end

    -- drop outdated events
    local member = vars.members[uri]

    if not member or event.incarnation > member.incarnation then
        vars.events[uri] = event
    elseif event.incarnation == member.incarnation then
        if event.status > member.status then
            vars.events[uri] = event
        end
    end

    if vars.events[uri] ~= event then
        -- event is outdated, drop it
        return
    end

    -- update members list
    if not member then
        member = {}
        log.info("Adding: %s (inc. %d) is %s", uri, event.incarnation, STATUS_NAMES[event.status])
    elseif member.status ~= event.status or member.incarnation ~= event.incarnation then
        log.info('Rumor: %s (inc. %d) is %s', uri, event.incarnation, STATUS_NAMES[event.status])
    end
    member.status = event.status
    member.incarnation = event.incarnation
    member.timestamp = fiber.time64()
    vars.members[uri] = member
end

local function gen_event(uri, status, incarnation)
    checks("string", "?number", "?number")
    handle_event({
        uri = uri,
        status = status or STATUS.alive,
        incarnation = incarnation or 1,
        ttl = _table_count(vars.members),
    })    
end

local function handle_message(sender_uri, msg_type, msg_data, new_events)

    for _, event in ipairs(new_events) do
        handle_event(unpack_event(event))
    end

    if msg_type == MESSAGE_PING then
        send_message(sender_uri, MESSAGE_ACK, msg_data)
    elseif msg_type == MESSAGE_INDIRECT_PING then

    elseif msg_type == MESSAGE_ACK then
        table.insert(vars.ack_messages, {sender_uri, msg_data})
        vars.ack_condition:broadcast()
    end
end

local function handle_message_loop()
    while true do
        local message = vars.message_channel:get()
        -- handle_message(unpack(message))
        local ok, res = xpcall(handle_message, debug.traceback, unpack(message))

        if not ok then
            log.error(res)
        end
    end
end

function membership_recv_message(sender_uri, typ, data, new_events)
    vars.message_channel:put({sender_uri, typ, data, new_events})
end


local function timeout_ping_requests()
    local now = fiber.time64()
    local timeout = PROTOCOL_PERIOD_SECONDS * 1.0e6
    while true do
        for i=#indirect_ping_requests,1,-1 do
            local req = indirect_ping_requests[i]
            if now - req.timestamp > timeout then
                table.remove(indirect_ping_requests, i)
            end
        end

        fiber.sleep(1)
    end
end


local function wait_ack(uri, timestamp)
    local now
    local timeout = ACK_TIMEOUT_SECONDS * 1.0e6
    local deadline = timestamp + timeout
    repeat
        now = fiber.time64()

        for _, msg in ipairs(vars.ack_messages) do
            local ack_uri, ack_timestamp = unpack(msg)
            if ack_uri == uri and ack_timestamp >= timestamp then
                return true
            end
        end
    until (now >= deadline) or not vars.ack_condition:wait(tonumber(deadline - now) / 1.0e6)

    return false
end

local function mark_dead(uri)

end

local function protocol_step()
    local uri = select_next_member()

    if uri == nil then
        return
    end

    local ts = fiber.time64()
    local ok, _ = send_message(uri, MESSAGE_PING, ts)

    if ok and wait_ack(uri, ts) then
        -- ok
        return
    elseif vars.members[uri].status == STATUS.dead then
        -- still dead, do nothing
        return
    end

    local ts = fiber.time64()
    for _ = 1, NUM_FAILURE_DETECTION_SUBGROUPS do
        local through_uri = select_random_live_member(uri)

        if through_uri == nil then
            -- log.error("No live members for indirect ping")
            break
        else
            --log.info("through: " .. through_uri)
            send_message(through_uri, MESSAGE_INDIRECT_PING, uri)
        end
    end

    if wait_ack(uri, ts) then
        -- ok
        return
    elseif vars.members[uri].status == STATUS.alive then
        log.info("Couldn't reach node: %s", uri)
        handle_event({
            uri = uri,
            status = STATUS.suspect,
            incarnation = vars.members[uri].incarnation,
            ttl = _table_count(vars.members),
        })
        return
    end
end

local function expire()
    local now = fiber.time64()
    local timeout = SUSPECT_TIMEOUT_SECONDS * 1.0e6
    for uri, member in pairs(vars.members) do
        local deadline = member.timestamp + timeout

        if member.status == STATUS.suspect and now > deadline then
            log.info("Suspected node is unreachable.")
            handle_event({
                uri = uri,
                status = STATUS.dead,
                incarnation = member.incarnation,
                ttl = _table_count(vars.members),
            })
        end
    end

    for i=#vars.ack_messages,1,-1 do
        local uri = vars.ack_messages[i][1]
        local ts = vars.ack_messages[i][2]

        if now - ts > ACK_EXPIRE_SECONDS * 1.0e6 then
            table.remove(vars.ack_messages, i)
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
        fiber.sleep(t1 + PROTOCOL_PERIOD_SECONDS - t2)
    end
end

function membership_recv_anti_entropy(remote_tbl)
    for uri, val in pairs(remote_tbl) do
        if not vars.members[uri] then
            gen_event(uri, STATUS.alive, val.incarnation)
            set_status(uri, val.status)
        elseif get_incarnation(uri) < remote_tbl[uri].incarnation then
            set_incarnation(uri, val.incarnation)
            set_status(uri, val.status)
        end
    end

    local ret = {}

    local local_tbl = vars.members
    for uri, val in pairs(local_tbl) do
        if remote_tbl[uri] == nil then
            ret[uri] = val
        elseif remote_tbl[uri].incarnation < local_tbl[uri].incarnation then
            ret[uri] = val
        end
    end

    return ret
end

local function anti_entropy_step()
    local uri = select_random_live_member()

    if uri == nil then
        return false
    end

    --log.info("anti entropy sync with: " .. tostring(uri))

    local conn, err = pool.connect(uri)

    if err ~= nil then
        log.error("Failed to do anti-entropy sync: %s", err)
        return false, err
    end

    local ok, remote_tbl = pcall(
        conn.call,
        conn,
        'membership_recv_anti_entropy',
        {vars.members},
        {timeout=PROTOCOL_PERIOD_SECONDS}
    )

    if not ok then
        local err = remote_tbl
        log.error("Failed to do anti-entropy sync: %s", err)
        return false, err
    end

    for uri, val in pairs(remote_tbl) do
        if not vars.members[uri] then
            gen_event(uri, STATUS.alive, val.incarnation)
            set_status(uri, val.status)
        elseif get_incarnation(uri) < val.incarnation then
            set_incarnation(uri, val.incarnation)
            set_status(uri, val.status)
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
            fiber.sleep(PROTOCOL_PERIOD_SECONDS)
        else
            fiber.sleep(ANTI_ENTROPY_PERIOD_SECONDS)
        end
    end
end

local function init(advertise_uri)
    checks("string")
    vars.advertise_uri = advertise_uri

    gen_event(advertise_uri)

    fiber.create(anti_entropy_loop)
    fiber.create(protocol_loop)
    fiber.create(handle_message_loop)
    fiber.create(timeout_ping_requests)
end

local function get_advertise_uri()
    return vars.advertise_uri
end

return {
    init = init,
    pairs = member_pairs,
    members = vars.members,
    add_member = gen_event,
    get_advertise_uri = get_advertise_uri
}
