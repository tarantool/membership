#!/usr/bin/env tarantool

local pool = require 'pool'
local log = require 'log'
local fiber = require 'fiber'
local clock = require 'clock'
local json = require 'json'

local PROTOCOL_PERIOD_SECONDS = 1
local ANTI_ENTROPY_PERIOD_SECONDS = 10
local ACK_EXPIRE_SECONDS = 10

local SUSPECT_TIMEOUT_SECONDS = 3
local NUM_FAILURE_DETECTION_SUBGROUPS = 3

local EVENT_PIGGYBACK_LIMIT = 10

local STATUS_ALIVE = 1
local STATUS_SUSPECT = 2
local STATUS_DEAD = 3

local EVENT_ALIVE = 1
local EVENT_SUSPECT = 2
local EVENT_DEAD = 3

local MESSAGE_PING = 1
local MESSAGE_INDIRECT_PING = 2
local MESSAGE_ACK = 3

-- uri, status, incarnation
local members = {}

local shuffled_members = {}
local shuffled_member = 1

local events = {}

local suspects = {}

local indirect_ping_requests = {}

local message_channel = fiber.channel(1000)

local advertise_uri = nil

local ack_cond = fiber.cond()

local ack_messages = {}

local function status_to_string(status)
    if status == STATUS_ALIVE then
        return "alive"
    elseif status == STATUS_SUSPECT then
        return "suspect"
    elseif status == STATUS_DEAD then
        return "dead"
    end
end

local function member_pairs()
    local res = {}

    for uri, member in pairs(members) do
        res[uri] = {uri = uri,
                    status = status_to_string(member.status),
                    incarnation = member.incarnation}
    end

    return pairs(res)
end

local function shuffle(list)
    local indices = {}
    for i = 1, #list do
        indices[#indices+1] = i
    end

    local shuffled = {}
    for _ = 1, #list do
        local index = math.random(#indices)
        local value = list[indices[index]]

        table.remove(indices, index)
        shuffled[#shuffled+1] = value
    end

    return shuffled
end

local function member_exists(uri)
    return members[uri] ~= nil
end

local function add_member(uri, inc)
    log.info("Adding new member: %s", uri)
    if inc == nil then
        inc = 0
    end

    members[uri] = {status=STATUS_ALIVE, incarnation=inc}
end

local function member_count()
    local count = 0

    for _, v in pairs(members) do
        count = count + 1
    end

    return count
end

local function get_incarnation(uri)
    return members[uri].incarnation
end

local function set_incarnation(uri, value)
    members[uri].incarnation = value
end

local function set_status(uri, status)
    members[uri].status = status
end

local function get_status(uri)
    return members[uri].status
end

local function set_timestamp(uri, timestamp)
    members[uri].timestamp = timestamp
end

local function get_timestamp(uri)
    return members[uri].timestamp
end

local function get_membership_table()
    return members
end

local function status_to_str(status)
    if status == STATUS_ALIVE then
        return "alive"
    elseif status == STATUS_DEAD then
        return "dead"
    elseif status == STATUS_SUSPECT then
        return "suspect"
    else
        error(string.format("unknown status: %d", status))
    end
end

local function dump_membership_table()
    local res = ""
    for uri, val in pairs(members) do
        res = res .. string.format("%s\t%s\t%s\n",
                                   uri,
                                   status_to_str(val.status),
                                   val.incarnation)
    end
    return res
end

local function select_next_member()
    if shuffled_member > #shuffled_members then
        local tbl = get_membership_table()
        --log.info("membership: " .. json.encode(tbl))

        for k, _ in pairs(tbl) do
            if k ~= advertise_uri then
                table.insert(shuffled_members, k)
            end
        end
        shuffled_members = shuffle(shuffled_members)
        shuffled_member = 1

        if #shuffled_members == 0 then
            return nil
        end
    end

    local res = shuffled_members[shuffled_member]
    shuffled_member = shuffled_member + 1
    return res
end

local function select_random_live_member()
    local live = {}

    for _, k in ipairs(shuffled_members) do
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
    return {event_type = event[1],
            uri = event[2],
            ttl = event[3],
            incarnation = event[4]}
end

local function pack_event(event)
    return {event.event_type,
            event.uri,
            event.ttl,
            event.incarnation}
end

local function send_message(uri, msg, extra_event)
    local conn, err = pool.connect(uri)
    local rc
    local evts = {}
    local expired = {}

    local count = 0

    if extra_event then
        table.insert(evts, pack_event(extra_event))
        count = count + 1
    end

    for uri, event in pairs(events) do
        if count > EVENT_PIGGYBACK_LIMIT then
            break
        end

        if not extra_event or extra_event.uri ~= uri then
            event.ttl = event.ttl - 1
            if event.ttl <= 0 then
                table.insert(expired, uri)
            else
                table.insert(evts, pack_event(event))
            end

            count = count + 1
        end
    end

    for _, uri in ipairs(expired) do
        log.info("expiring event for %s", uri)
        events[uri] = nil
    end


    if err ~= nil then
        return nil, err
    end

    rc, err = pcall(conn.call,
                    conn,
                    'membership_recv_message',
                    {advertise_uri, evts, msg},
                    {timeout=PROTOCOL_PERIOD_SECONDS})

    if not rc then
        return nil, err
    end
end

local function handle_event(event)
    local uri = event.uri

    if advertise_uri == uri then
        if event.event_type == EVENT_SUSPECT or event.event_type == EVENT_DEAD then
            log.info("refuting the rumor that we are dead")
            local incarnation = math.max(event.incarnation, get_incarnation(advertise_uri)) + 1
            set_incarnation(advertise_uri, incarnation)

            local ttl = member_count()

            events[uri] = {event_type = EVENT_ALIVE,
                           uri = advertise_uri,
                           ttl = ttl,
                           incarnation = incarnation}
        end

        return
    end

    if events[uri] == nil then
        events[uri] = event
    else
        local old_event = events[uri]

        if event.event_type == EVENT_ALIVE then
            if old_event.event_type == EVENT_ALIVE and event.incarnation > old_event.incarnation then
                events[uri] = event
            elseif old_event.event_type == EVENT_SUSPECT and event.incarnation > old_event.incarnation then
                events[uri] = event
            end
        elseif event.event_type == EVENT_SUSPECT then
            if old_event.event_type == EVENT_ALIVE and event.incarnation >= old_event.incarnation then
                events[uri] = event
            elseif old_event.event_type == EVENT_SUSPECT and event.incarnation > old_event.incarnation then
                events[uri] = event
            end
        elseif event.event_type == EVENT_DEAD then
            if old_event.event_type == EVENT_ALIVE then
                events[uri] = event
            elseif old_event.event_type == EVENT_SUSPECT then
                events[uri] = event
            end
        end
    end

    if events[uri] ~= event then
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

local function send_ping(uri, ts)
    local extra_event = nil

    if get_status(uri) == STATUS_SUSPECT then
        extra_event = {event_type = EVENT_SUSPECT,
                       uri = uri,
                       ttl = member_count(),
                       incarnation = get_incarnation(uri)}
    elseif get_status(uri) == STATUS_DEAD then
        extra_event = {event_type = EVENT_DEAD,
                       uri = uri,
                       ttl = member_count(),
                       incarnation = get_incarnation(uri)}
    end


    return send_message(uri, {MESSAGE_PING, ts}, extra_event)
end

local function handle_message()
    while true do
        local arg = message_channel:get()
        local sender_uri = arg[1]
        local evts = arg[2]
        local msg = arg[3]

        local msg_type = msg[1]

        if not member_exists(sender_uri) then
            add_member(sender_uri)
        end

        for _, event in ipairs(evts) do
            handle_event(unpack_event(event))
        end

        if msg_type == MESSAGE_PING then
            local ts = msg[2]
            --log.info("ping from " .. sender_uri)
            send_message(sender_uri, {MESSAGE_ACK, ts})
        elseif msg_type == MESSAGE_INDIRECT_PING then

        elseif msg_type == MESSAGE_ACK then
            local ts = msg[2]
            --log.info("ack from " .. sender_uri)

            table.insert(ack_messages, {sender_uri, ts})
            ack_cond:broadcast()
        end

    end
end


function membership_recv_message(sender_uri, evts, msg)

    --if not is_known_host(sender_uri) then
        -- TODO: add "ALIVE" message
    --end

    message_channel:put({sender_uri, evts, msg})

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
    local now = clock.time64()
    local timediff = PROTOCOL_PERIOD_SECONDS * 10^9

    while (now - timestamp) < timediff do
        for _, v in ipairs(ack_messages) do
            if v[1] == uri and v[2] >= timestamp then
                return true
            end
        end

        ack_cond:wait(tonumber(timestamp + timediff - now) / 10^9)
        now = clock.time64()
    end

    return false
end

local function mark_alive(uri)
    if get_status(uri) ~= STATUS_ALIVE then
        if events[uri] == nil or events[uri].incarnation < get_incarnation(uri) then
            set_status(uri, STATUS_ALIVE)
            set_timestamp(uri, clock.time64())

            events[uri] = {event_type = EVENT_ALIVE,
                           uri = uri,
                           ttl = member_count(),
                           incarnation = get_incarnation(uri)}
        end
    end
end

local function mark_suspect(uri)
    if get_status(uri) == STATUS_ALIVE then
        if events[uri] == nil or events[uri].incarnation <= get_incarnation(uri) then
            set_status(uri, STATUS_SUSPECT)
            set_timestamp(uri, clock.time64())

            events[uri] = {event_type = EVENT_SUSPECT,
                           uri = uri,
                           ttl = member_count(),
                           incarnation = get_incarnation(uri)}
        end
    end
end

local function mark_dead(uri)

end

local function protocol_step()
    local uri = select_next_member()

    if uri == nil then
        return
    end

    local ts = clock.time64()
    local res, err = send_ping(uri, ts)

    if err == nil and wait_ack(uri, ts) then
        mark_alive(uri)
        return
    end

    if get_status(uri) == STATUS_DEAD then
        return
    end

    ts = clock.time64()
    for _=1,NUM_FAILURE_DETECTION_SUBGROUPS do
        local through_uri = select_random_live_member(uri)

        if through_uri == nil then
            log.error("No live members for indirect ping")
        else
            --log.info("through: " .. through_uri)
            send_message(through_uri, {MESSAGE_INDIRECT_PING, uri})
        end
    end

    if wait_ack(uri, ts) then
        mark_alive(uri)
        return
    end

    log.info("Couldn't reach node: %s", uri)

    mark_suspect(uri)
end

local function expire()
    for k,_ in pairs(members) do
        if get_status(k) == STATUS_SUSPECT and
           get_timestamp(k) - clock.time64() > SUSPECT_TIMEOUT_SECONDS * 10^9 then
               set_status(k, STATUS_DEAD)
               set_timestamp(k, clock.time64())
               events[k] = {event_type = EVENT_DEAD,
                            uri = k,
                            ttl = member_count(),
                            incarnation = get_incarnation(k)}
               log.info("Suspected node is unreachable. Marking as dead: '%s'", k)
        end
    end

    for i=#ack_messages,1,-1 do
        local uri = ack_messages[i][1]
        local ts = ack_messages[i][2]
        local now = clock.time64()

        if now - ts > ACK_EXPIRE_SECONDS * 10^9 then
            table.remove(ack_messages, i)
        end
    end
end

local function protocol_loop()
    while true do
        protocol_step()
        expire()

        fiber.sleep(PROTOCOL_PERIOD_SECONDS)
    end
end

function membership_recv_anti_entropy(remote_tbl)
    for uri, val in pairs(remote_tbl) do
        if not member_exists(uri) then
            add_member(uri, val.incarnation)
            set_status(uri, val.status)
        elseif get_incarnation(uri) < remote_tbl[uri].incarnation then
            set_incarnation(uri, val.incarnation)
            set_status(uri, val.status)
        end
    end

    local ret = {}

    local local_tbl = get_membership_table()
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
    local rc

    if err ~= nil then
        log.error("Failed to do anti-entropy sync: %s", err)
        return false, err
    end

    local local_tbl = get_membership_table()

    local res
    rc, res = pcall(conn.call,
                    conn,
                    'membership_recv_anti_entropy',
                    {local_tbl},
                    {timeout=PROTOCOL_PERIOD_SECONDS})

    if not rc then
        log.error("Failed to do anti-entropy sync: %s", res)
        return false, res
    end

    local remote_tbl = res

    for uri, val in pairs(remote_tbl) do
        if not member_exists(local_tbl) then
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

local function init(uri, bootstrap)
    if type(bootstrap) ~= "table" then
        bootstrap = {bootstrap}
    end

    advertise_uri = uri

    if not member_exists(uri) then
        add_member(uri)
    end

    for _, bootstrap_uri in ipairs(bootstrap) do
        if bootstrap_uri ~= uri and not member_exists(bootstrap_uri) then
            add_member(bootstrap_uri)
        end
    end

    log.info(dump_membership_table())

    fiber.create(anti_entropy_loop)
    fiber.create(protocol_loop)
    fiber.create(handle_message)
end

fiber.create(timeout_ping_requests)

return {init=init, pairs=member_pairs}
