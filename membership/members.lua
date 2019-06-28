local fiber = require('fiber')
local checks = require('checks')

local opts = require('membership.options')

local members = {}
local _all_members = {
    -- [uri] = {
    --     status = number,
    --     incarnation = number,
    --     timestamp = time64,
    --     payload = ?table,
    -- }

    -- uri is a string in format '<host>:<port>'
}

function members.clear()
    table.clear(_all_members)
end

function members.pairs()
    return pairs(_all_members)
end

function members.myself()
    return _all_members[opts.advertise_uri]
end

function members.get(uri)
    return _all_members[uri]
end

function members.filter_excluding(state, uri1, uri2)
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

function members.set(uri, status, incarnation, payload)
    checks('string', 'number', 'number', '?table')

    local member = _all_members[uri]
    if member and incarnation < member.incarnation then
        error('Can not downgrade incarnation')
    end

    _all_members[uri] = {
        status = status,
        incarnation = incarnation,
        payload = payload or (member or {}).payload,
        timestamp = fiber.time64(),
    }
end

function members.count()
    local count = 0
    for _ in pairs(_all_members) do
        count = count + 1
    end
    return count
end

return members
