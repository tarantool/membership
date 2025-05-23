local fiber = require('fiber')
local checks = require('checks')
local msgpack = require('msgpack')

local opts = require('membership.options')
local stash = require('membership.stash')

local members = {}
local _all_members = table.copy(stash.get('members._all_members')) or {
    -- [uri] = {
    --     status = number,
    --     incarnation = number,
    --     timestamp = time64,
    --     payload = ?table,
    --     clock_delta = ?number
    -- }

    -- uri is a string in format '<host>:<port>'
}

local _allowed_uri_set = stash.get('_allowed_uri_set')

function members.after_reload()
    stash.set('members._all_members', _all_members)
end

function members.clear()
    table.clear(_all_members)
end

function members.pairs()
    return pairs(_all_members)
end

function members.get(uri)
    return _all_members[uri]
end

function members.estimate_msgpacked_size(uri, member)
    local sum = 0
    sum = sum + #msgpack.encode(uri)
    sum = sum + #msgpack.encode(member.status)
    sum = sum + #msgpack.encode(member.incarnation)
    sum = sum + #msgpack.encode(member.payload or msgpack.NULL)
    return sum + 1
end

function members.pack(uri, member)
    checks('string', 'table')
    return {
        uri,
        member.status,
        member.incarnation,
        member.payload or msgpack.NULL,
    }
end

function members.unpack(member)
    checks('table')
    local payload = member[4]
    if payload == msgpack.NULL
    or type(payload) ~= 'table'
    then
        payload = nil
    end
    return member[1], {
        status = tonumber(member[2]),
        incarnation = tonumber(member[3]),
        payload = payload,
    }
end

function members.filter_excluding(state, uri1, uri2)
    assert(state == nil or state == 'left' or state == 'unhealthy')
    local ret = {}
    for uri, member in pairs(_all_members) do
        if (uri ~= uri1) and (uri ~= uri2)
        and (
            (state == nil)
            or (state == 'unhealthy' and member.status == opts.ALIVE)
            or (state == 'left' and member.status ~= opts.LEFT)
        ) then
            table.insert(ret, uri)
        end
    end
    return ret
end

function members.set(uri, status, incarnation, params)
    checks('string', 'number', 'number', { payload = '?table', clock_delta = '?number' })

    local member = _all_members[uri]

    if next(_allowed_uri_set) and not _allowed_uri_set[uri]
    and (status == opts.SUSPECT or status == opts.LEFT or status == opts.DEAD) then
        opts.log_debug('Ignoring member %s with status %s', uri, opts.STATUS_NAMES[status])
        -- removes instance if it is not in the allowed list and dead
        members.remove(uri)
        return
    end

    if member and incarnation < member.incarnation then
        error('Can not downgrade incarnation')
    end

    local payload
    if params ~= nil and params.payload ~= nil then
        payload = params.payload
    elseif member ~= nil then
        payload = member.payload
    end

    local clock_delta
    if params ~= nil and params.clock_delta ~= nil then
        clock_delta = params.clock_delta
    elseif member ~= nil then
        clock_delta = member.clock_delta
    end

    _all_members[uri] = {
        status = status,
        incarnation = incarnation,
        payload = payload,
        timestamp = fiber.time64(),
        clock_delta = clock_delta
    }
end

function members.count()
    local count = 0
    for _ in pairs(_all_members) do
        count = count + 1
    end
    return count
end

function members.remove(uri)
    checks('string')

    _all_members[uri] = nil
    local stash = rawget(_G, '__membership_stash')
    stash['members._all_members'][uri] = nil
    stash['_resolve_cache'][uri] = nil
end

return members
