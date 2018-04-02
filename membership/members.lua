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

local _shuffled_uri_list = {}
local _shuffled_idx = 1

function members.clear()
    _all_members = {}
    _shuffled_uri_list = {}
    _shuffled_idx = 1
end

function members.all()
    local ret = {}
    for uri, member in pairs(_all_members) do
        ret[uri] = {
            uri = uri,
            status = member.status,
            status_name = opts.STATUS_NAMES[member.status] or tostring(member.status),
            payload = member.payload,
            incarnation = member.incarnation,
            timestamp = member.timestamp,
        }
    end
    return ret
end

function members.pairs()
    return pairs(members.all())
end

function members.myself()
    return _all_members[opts.advertise_uri]
end

function members.get(uri)
    checks("string")
    return _all_members[uri]
end

function members.random_alive_uri_list(n, excluding)
    checks()
    local ret = {}

    for uri, member in pairs(_all_members) do
        if member.status ~= opts.ALIVE then
            -- skip
        elseif uri == opts.advertise_uri then
            -- skip
        elseif uri == excluding then
            --skip
        else
            table.insert(ret, uri)
        end
    end

    while #ret > n do
        table.remove(ret, math.random(#ret))
    end

    return ret
end

function members.next_shuffled_uri()
    checks()
    if _shuffled_idx > #_shuffled_uri_list then
        _shuffled_uri_list = {}
        _shuffled_idx = 1
        for uri, member in pairs(_all_members) do
            if member.status == opts.QUIT then
                -- skip
            elseif uri == opts.advertise_uri then
                -- skip
            else
                table.insert(_shuffled_uri_list, math.random(#_shuffled_uri_list+1), uri)
            end
        end
    end

    _shuffled_idx = _shuffled_idx + 1
    return _shuffled_uri_list[_shuffled_idx-1]
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
    checks()
    local count = 0
    for _ in pairs(_all_members) do
        count = count + 1
    end
    return count
end

return members
