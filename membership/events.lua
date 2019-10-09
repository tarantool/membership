local log = require('log')
local fiber = require('fiber')
local checks = require('checks')
local msgpack = require('msgpack')

local opts = require('membership.options')
local members = require('membership.members')

local events = {}
local _all_events = {
    -- [uri] = {
    --     uri = string,
    --     status = number,
    --     incarnation = number,
    --     ttl = number,
    -- }

    -- uri is a string in format '<host>:<port>'
}
local _expired = {
    -- [uri] = true
}
local _subscribers = {
    -- [fiber.cond] = true
}

function events.clear()
    _all_events = {}
    _expired = {}
end

function events.get(uri)
    checks('string')
    return _all_events[uri]
end

function events.all()
    return _all_events
end

function events.pairs()
    return pairs(_all_events)
end

function events.estimate_msgpacked_size(event)
    local sum = 0
    sum = sum + #msgpack.encode(event.uri)
    sum = sum + #msgpack.encode(event.status)
    sum = sum + #msgpack.encode(event.incarnation)
    sum = sum + #msgpack.encode(event.payload or msgpack.NULL)
    sum = sum + #msgpack.encode(event.ttl)
    return sum + 1
end

function events.pack(event)
    checks('table')
    event.ttl = event.ttl - 1
    if event.ttl <= 0 then
        _expired[event.uri] = true
    end

    return {
        event.uri,
        event.status,
        event.incarnation,
        event.payload or msgpack.NULL,
        event.ttl,
    }
end

function events.gc()
    for uri, _ in pairs(_expired) do
        _all_events[uri] = nil
        _expired[uri] = nil
    end
end

function events.unpack(event)
    checks('table')
    return {
        uri = event[1],
        status = event[2],
        incarnation = event[3],
        payload = (event[4] ~= msgpack.NULL) and event[4] or nil,
        ttl = event[5],
    }
end

function events.should_overwrite(first, second)
    checks('table', '?table')
    if not second or first.incarnation > second.incarnation then
        return true
    elseif first.incarnation == second.incarnation then
        if first.status > second.status then
            return true
        end
    end
    return false
end

function events.generate(uri, status, incarnation, payload)
    checks('string', 'number', '?number', '?table')
    events.handle({
        uri = uri,
        status = status or opts.ALIVE,
        incarnation = incarnation
            or (members.get(uri) or {}).incarnation
            or 1,
        payload = payload,
        ttl = math.floor(math.log(members.count(), 2)) + 2,
    })
end

function events.handle(event)
    -- drop outdated events
    local member = members.get(event.uri)

    if events.should_overwrite(event, member) then
        _all_events[event.uri] = event
    else
        return
    end

    -- update members list
    if not member then
        log.debug('Adding: %s (inc. %d) is %s', event.uri, event.incarnation, opts.STATUS_NAMES[event.status])
    elseif member.status ~= event.status or member.incarnation ~= event.incarnation then
        log.debug('Rumor: %s (inc. %d) is %s', event.uri, event.incarnation, opts.STATUS_NAMES[event.status])
    end
    members.set(event.uri, event.status, event.incarnation, { payload = event.payload })

    for cond, _ in pairs(_subscribers) do
        cond:broadcast()
    end
end

function events.subscribe()
    local cond = fiber.cond()
    _subscribers[cond] = true
    return cond
end

function events.unsubscribe(cond)
    _subscribers[cond] = nil
    return nil
end

return events
