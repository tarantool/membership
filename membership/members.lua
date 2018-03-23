local fiber = require('fiber')
local checks = require('checks')

local opts = require('membership.options')

local members = {}
local _all_members = {
    -- [uri] = {
    --     status = number,
    --     incarnation = number,
    --     timestamp = time64,
    -- }
}

local _shuffled_uri_list = {}
local _shuffled_idx = 1

function members.all()
    local ret = {}
    for uri, member in pairs(_all_members) do
        ret[uri] = {
            uri = uri,
            status = member.status,
            status_name = opts.STATUS_NAMES[member.status] or tostring(member.status),
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

function members.random_alive_uri_list(n)
    checks()
    local ret = {}

    for uri, member in pairs(_all_members) do
        if member.status == opts.ALIVE then
            table.insert(ret, uri)
        end
    end

    while #ret > n do
        table.remove(ret, math.random(#ret))
    end

    return ret
end

local function shuffle(tbl)
    local ret = {}
    for uri, _ in pairs(tbl) do
        if uri ~= opts.advertise_uri then
            table.insert(ret, math.random(#ret+1), uri)
        end
    end
    return ret
end 

function members.next_shuffled_uri()
    checks()
    if _shuffled_idx > #_shuffled_uri_list then
        _shuffled_uri_list = shuffle(_all_members)
        _shuffled_idx = 1
    end

    _shuffled_idx = _shuffled_idx + 1
    return _shuffled_uri_list[_shuffled_idx-1]
end

function members.set(uri, status, incarnation)
    do
        checks("string", "number", "number")
        local member = _all_members[uri]
        if member and incarnation < member.incarnation then
            error('Can not downgrade incarnation')
        end
    end

    _all_members[uri] = {
        status = status,
        incarnation = incarnation,
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
