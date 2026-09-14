local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster')

local SERVER_LIST = { 13501, 13502, 13503 }
local OWNER_URI = 'localhost:13501'
local WITNESS_URI = 'localhost:13502'
local UUID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

-- leave() announces `left` with the owner's incarnation and no payload. A
-- neighbour that has no record builds one out of it and gets an empty payload at
-- that incarnation. add_member() then bumps it by one to get past `left`, still
-- empty, while the returning owner computes the same incarnation + 1 from the
-- same base, with a payload. Equal incarnation is never overwritten.
--
--   owner (A)                witness (W)           restarted (R)
--   ---------                -----------           -------------
--   payload {uuid}           A: alive/N/{uuid}     A: alive/N/{uuid}
--                            silenced
--                                                  stop: the member table is
--                                                  kept in memory only, so R
--                                                  comes back knowing nobody
--   leave()  ------------->  A: left/N/{uuid}
--                            (kept its own payload)
--                                                  start, add_member(W)
--                            -- left/N, no payload ->
--                                                  A: left/N/{}
--                                                  add_member(A)
--                                                  A: alive/N+1/{}
--   init, set_payload
--   add_member(W)
--   <---------- left/N ----
--   A: alive/N+1/{uuid}
--
-- Same roles in cartridge: R is restarted by a rolling update, W stays up, A is
-- the one whose uuid goes missing from the neighbours' payload. cartridge calls
-- add_member() for every topology server on each boot and publishes the uuid
-- into the payload once, at bootstrap.

g.before_all(function()
    cluster.start('localhost', SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

-- Cancels the fibers that would otherwise deliver the payload ahead of time and
-- hide the bug. Without that the test is a race.
local function silence(server, ...)
    server:exec(function(names)
        for _, name in ipairs(names) do
            require('membership.stash').fiber_cancel(name)
        end
    end, { { ... } })
end

-- Brings them back once the situation is set up, to see whether the cluster
-- converges on its own.
local function revive(server, ...)
    server:exec(function(names)
        local stash = require('membership.stash')
        for _, name in ipairs(names) do
            stash.fiber_cancel(name)
            stash.fiber_new(name)
        end
    end, { { ... } })
end

local function payload_of(server, uri)
    return (server:get_member(uri) or {}).payload
end

g.test_payload_survives_leave = function()
    local owner = cluster.servers[1]
    local witness = cluster.servers[2]
    local restarted = cluster.servers[3]

    owner:exec(function(uuid) membership.set_payload('uuid', uuid) end, { UUID })
    t.assert(witness:add_member(OWNER_URI))
    t.assert(restarted:add_member(OWNER_URI))

    for _, server in ipairs({ witness, restarted }) do
        t.helpers.retrying({ timeout = 10 }, function()
            t.assert_equals(payload_of(server, OWNER_URI), { uuid = UUID })
        end)
    end

    -- The witness sends nothing from here on, so the `left` announcement is never
    -- packed into an outgoing message, never loses ttl, and is still in the queue
    -- when the restarted instance asks for it.
    silence(witness, 'protocol_step', 'anti_entropy_step')

    local incarnation = owner:myself().incarnation

    restarted:stop()
    t.assert(owner:exec(function() return membership.leave() end))

    t.helpers.retrying({ timeout = 10 }, function()
        t.assert_equals(witness:get_member(OWNER_URI).status, 'left')
    end)

    restarted:start()
    -- Anti-entropy would hand over the whole record, payload included.
    silence(restarted, 'anti_entropy_step')
    t.assert(restarted:add_member(WITNESS_URI))

    t.helpers.retrying({ timeout = 10 }, function()
        t.assert_equals(restarted:get_member(OWNER_URI).status, 'left')
    end)

    t.assert_equals(payload_of(witness, OWNER_URI), { uuid = UUID })
    t.assert_equals(payload_of(restarted, OWNER_URI), { uuid = UUID },
        'the leave announcement must carry the payload')

    -- Leaves the witness as the only one the owner can hear.
    silence(restarted, 'protocol_step')

    owner:exec(function(uri, uuid)
        local host, port = uri:match('^(.*):(%d+)$')
        membership.init(host, tonumber(port))
        membership.set_payload('uuid', uuid)
    end, { OWNER_URI, UUID })
    t.assert(owner:add_member(WITNESS_URI))

    -- The owner refutes the `left` rumor and lands on incarnation + 1.
    t.helpers.retrying({ timeout = 10 }, function()
        t.assert_equals(owner:myself().incarnation, incarnation + 1)
    end)

    -- Same incarnation + 1 from the same base, with nothing to carry.
    t.assert(restarted:add_member(OWNER_URI))
    t.assert_equals(restarted:get_member(OWNER_URI).incarnation, incarnation + 1)
    t.assert_equals(restarted:get_member(OWNER_URI).status, 'alive')

    revive(witness, 'protocol_step', 'anti_entropy_step')
    revive(restarted, 'protocol_step', 'anti_entropy_step')

    t.helpers.retrying({ timeout = 10 }, function()
        for _, server in ipairs({ owner, witness, restarted }) do
            local member = server:get_member(OWNER_URI)
            t.assert_equals(
                { member.status, member.incarnation, member.payload },
                { 'alive', incarnation + 1, { uuid = UUID } },
                'the cluster must converge on the owner with its payload'
            )
        end
    end)
end
