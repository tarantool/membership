#!/usr/bin/env tarantool

local log = require('log')
local json = require('json')
local pool = require('pool')
local fiber = require('fiber')
local clock = require('clock')
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
    --     event_type = number,
    --     uri = string,
    --     ttl = number,
    --     incarnation = number,
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

local function add_member(uri, incarnation)
    log.info("Adding new member: %s", uri)

    vars.members[uri] = {
        status = STATUS_ALIVE,
        incarnation = incarnation or 0,
    }
    -- TODO callback
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

local function set_timestamp(uri, timestamp)
    vars.members[uri].timestamp = timestamp
end

local function get_timestamp(uri)
    return vars.members[uri].timestamp
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
        event_type = event[1],
        uri = event[2],
        ttl = event[3],
        incarnation = event[4],
    }
end

local function pack_event(event)
    return {
        event.event_type,
        event.uri,
        event.ttl,
        event.incarnation,
    }
end

local function send_message(uri, msg_type, msg_data, extra_event)
    checks("string", "number", "?", "?")
    local conn, err = pool.connect(uri)
    if err then
        return false, err
    end

    local events_to_send = {}
    local expired = {}

    if extra_event then
        table.insert(events_to_send, pack_event(extra_event))
    end

    for _, event in pairs(vars.events) do
        if #events_to_send > EVENT_PIGGYBACK_LIMIT then
            break
        end

        if extra_event and extra_event.uri == event.uri then
            -- it has already been sent 10 SLoCs before
            -- continue
        else
            event.ttl = event.ttl - 1
            if event.ttl <= 0 then
                table.insert(expired, event.uri)
            else
                table.insert(events_to_send, pack_event(event))
            end
        end
    end

    for _, uri in ipairs(expired) do
        log.info("expiring event for %s", uri)
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

    if vars.advertise_uri == uri then
        if event.event_type == EVENT_SUSPECT or event.event_type == EVENT_DEAD then
            log.info("refuting the rumor that we are dead")
            local incarnation = math.max(event.incarnation, get_incarnation(vars.advertise_uri)) + 1
            set_incarnation(vars.advertise_uri, incarnation)

            vars.events[uri] = {
                event_type = EVENT_ALIVE,
                uri = vars.advertise_uri,
                ttl = _table_count(vars.members),
                incarnation = incarnation,
            }
        end

        return
    end

    if vars.events[uri] == nil then
        vars.events[uri] = event
    else
        local old_event = vars.events[uri]

        if event.event_type == EVENT_ALIVE then
            if old_event.event_type == EVENT_ALIVE and event.incarnation > old_event.incarnation then
                vars.events[uri] = event
            elseif old_event.event_type == EVENT_SUSPECT and event.incarnation > old_event.incarnation then
                vars.events[uri] = event
            end
        elseif event.event_type == EVENT_SUSPECT then
            if old_event.event_type == EVENT_ALIVE and event.incarnation >= old_event.incarnation then
                vars.events[uri] = event
            elseif old_event.event_type == EVENT_SUSPECT and event.incarnation > old_event.incarnation then
                vars.events[uri] = event
            end
        elseif event.event_type == EVENT_DEAD then
            if old_event.event_type == EVENT_ALIVE then
                vars.events[uri] = event
            elseif old_event.event_type == EVENT_SUSPECT then
                vars.events[uri] = event
            end
        end
    end

    if vars.events[uri] ~= event then
        return
    end

    local status = get_status(uri)

    if event.event_type == EVENT_ALIVE and event.incarnation > get_incarnation(uri) then
        set_status(uri, STATUS_ALIVE)
        set_incarnation(uri, event.incarnation)
        set_timestamp(uri, clock.time64())
        log.info("rumor: node is alive: '%s'", uri)
    elseif event.event_type == EVENT_SUSPECT then
        if (status == STATUS_ALIVE and event.incarnation >= get_incarnation(uri)) or
            event.incarnation > get_incarnation(uri) then
            set_status(uri, STATUS_SUSPECT)
            set_incarnation(uri, event.incarnation)
            set_timestamp(uri, clock.time64())
            log.info("rumor: node is suspected: '%s'", uri)
        end
    elseif event.event_type == EVENT_DEAD then
        set_status(uri, STATUS_DEAD)
        set_incarnation(uri, math.max(event.incarnation, get_incarnation(uri)))
        set_timestamp(uri, clock.time64())
        log.info("rumor: node is dead: '%s'", uri)
    end
end

local function send_ping(uri, timestamp)
    local extra_event = nil
    local member = vars.members[uri]
    if member.status ~= STATUS_ALIVE then
        extra_event = {
            event_type = member.status,
            uri = uri,
            ttl = _table_count(vars.members), -- TODO this line is useless
            incarnation = member.incarnation,
        }
    end

    return send_message(uri, MESSAGE_PING, timestamp, extra_event)
end

local function handle_message(sender_uri, msg_type, msg_data, new_events)

    if not vars.members[sender_uri] then
        add_member(sender_uri)
    end

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
            log.error(debug.traceback())
        end
    end
end

function membership_recv_message(sender_uri, typ, data, new_events)
    vars.message_channel:put({sender_uri, typ, data, new_events})
end


local function timeout_ping_requests()
    while true do
        for i=#indirect_ping_requests,1,-1 do
            local req = indirect_ping_requests[i]
            if req.timestamp - clock.time64() > PROTOCOL_PERIOD_SECONDS * 10^9 then
                table.remove(indirect_ping_requests, i)
            end
        end

        fiber.sleep(1)
    end
end


local function wait_ack(uri, timestamp)
    local now
    local timeout = ACK_TIMEOUT_SECONDS * 10^9
    local deadline = timestamp + timeout
    repeat
        now = fiber.time64()

        for _, msg in ipairs(vars.ack_messages) do
            local ack_uri, ack_timestamp = unpack(msg)
            if ack_uri == uri and ack_timestamp >= timestamp then
                return true
            end
        end
    until (now >= deadline) or not vars.ack_condition:wait(tonumber(deadline - now) / 10^9)

    return false
end

local function mark_alive(uri)
    if get_status(uri) == STATUS_ALIVE then
        -- do nothing
        return
    end

    if vars.events[uri] == nil or vars.events[uri].incarnation < get_incarnation(uri) then
        set_status(uri, STATUS_ALIVE)
        set_timestamp(uri, clock.time64())

        vars.events[uri] = {
            event_type = EVENT_ALIVE,
            uri = uri,
            ttl = _table_count(vars.members),
            incarnation = get_incarnation(uri),
        }
    end
end

local function mark_suspect(uri)
    if get_status(uri) ~= STATUS_ALIVE then
        return
    end

    if vars.events[uri] == nil or vars.events[uri].incarnation <= get_incarnation(uri) then
        set_status(uri, STATUS_SUSPECT)
        set_timestamp(uri, clock.time64())

        vars.events[uri] = {
            event_type = EVENT_SUSPECT,
            uri = uri,
            ttl = _table_count(vars.members),
            incarnation = get_incarnation(uri),
        }
    end
end

local function mark_dead(uri)

end

local function protocol_step()
    local uri = select_next_member()

    if uri == nil then
        return
    end

    local ts = fiber.time64()
    local ok, _ = send_ping(uri, ts)

    if ok and wait_ack(uri, ts) then
        mark_alive(uri)
        return
    end

    if vars.members[uri].status == STATUS_DEAD then
        -- still dead, do nothing
        return
    end


    local ts = fiber.time64()
    for _ = 1, NUM_FAILURE_DETECTION_SUBGROUPS do
        local through_uri = select_random_live_member(uri)

        if through_uri == nil then
            log.error("No live members for indirect ping")
        else
            --log.info("through: " .. through_uri)
            send_message(through_uri, MESSAGE_INDIRECT_PING, uri)
        end
    end

    if wait_ack(uri, ts) then
        mark_alive(uri)
        return
    else
        log.info("Couldn't reach node: %s", uri)
        mark_suspect(uri)
        return
    end
end

local function expire()
    for k,_ in pairs(vars.members) do
        if get_status(k) == STATUS_SUSPECT and
           get_timestamp(k) - clock.time64() > SUSPECT_TIMEOUT_SECONDS * 10^9 then
                set_status(k, STATUS_DEAD)
                set_timestamp(k, clock.time64())
                vars.events[k] = {
                    event_type = EVENT_DEAD,
                    uri = k,
                    ttl = _table_count(vars.members),
                    incarnation = get_incarnation(k),
                }
                log.info("Suspected node is unreachable. Marking as dead: '%s'", k)
        end
    end

    for i=#vars.ack_messages,1,-1 do
        local uri = vars.ack_messages[i][1]
        local ts = vars.ack_messages[i][2]
        local now = clock.time64()

        if now - ts > ACK_EXPIRE_SECONDS * 10^9 then
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
            log.error(debug.traceback())

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
            add_member(uri, val.incarnation)
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
            add_member(uri, val.incarnation)
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

    if not vars.members[advertise_uri] then
        add_member(advertise_uri)
    end

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
    add_member = add_member,
    get_advertise_uri = get_advertise_uri
}
