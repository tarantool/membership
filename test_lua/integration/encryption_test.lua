local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster')

local SERVER_LIST = { 13301, 13302 }

g.before_all(function()
    cluster.start('localhost', SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

g.test_join = function()
    t.assert(cluster.servers[1]:add_member('localhost:13302'))
    t.assert_equals(cluster.servers[1]:exec(function()
        return membership.get_encryption_key()
    end), nil)

    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'alive'
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'alive'
    )
end

g.test_enable_encryption = function()
    cluster.servers[2]:exec(function()
        return membership.set_encryption_key("XXXXXX")
    end)
    t.assert_equals(
        cluster.servers[2]:exec(function()
            return membership.get_encryption_key()
        end),
        string.rjust("XXXXXX", 32)
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'non-decryptable'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'non-decryptable'
    )

    cluster.servers[1]:exec(function()
        return membership.set_encryption_key("XXXXXX")
    end)
    t.assert_equals(
        cluster.servers[1]:exec(function()
            return membership.get_encryption_key()
        end),
        string.rjust("XXXXXX", 32)
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'alive'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'alive'
    )

    cluster.servers[2]:exec(function()
        return membership.leave()
    end)
    cluster.servers[1]:check_status('localhost:13302', 'left')

    cluster.servers[2]:exec(function()
        assert(membership.init("localhost", 13302))
        assert(membership.probe_uri("localhost:13301"))
    end)
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'alive'
    )
end

g.test_change_encryption = function()
    cluster.servers[1]:exec(function()
        return membership.set_encryption_key("YY")
    end)
    t.assert_equals(
        cluster.servers[1]:exec(function()
            return membership.get_encryption_key()
        end),
        string.rjust("YY", 32)
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'non-decryptable'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'non-decryptable'
    )

    cluster.servers[2]:exec(function()
        return membership.set_encryption_key("YY")
    end)
    t.assert_equals(
        cluster.servers[2]:exec(function()
            return membership.get_encryption_key()
        end),
        string.rjust("YY", 32)
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'alive'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'alive'
    )
end

g.test_disable_encryption = function()
    cluster.servers[2]:exec(function()
        return membership.set_encryption_key(nil)
    end)
    t.assert_equals(cluster.servers[2]:exec(function()
        return membership.get_encryption_key()
    end), nil)
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'non-decryptable'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'non-decryptable'
    )

    cluster.servers[1]:exec(function()
        return membership.set_encryption_key(nil)
    end)
    t.assert_equals(cluster.servers[1]:exec(function()
        return membership.get_encryption_key()
    end), nil)
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'alive'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'alive'
    )
end

g.test_gh36 = function()
    -- There was a bug in nslookup function which prevented
    -- discovering non-decryptable members
    for i = 1, 10 do
        local uri = string.format("s%03d:oO", i)
        cluster.servers[2]:exec(function(u)
            membership.probe_uri(u)
        end, { uri })
    end

    cluster.servers[1]:exec(function()
        return membership.set_encryption_key("ZZ")
    end)
    t.assert_equals(
        cluster.servers[1]:exec(function()
            return membership.get_encryption_key()
        end),
        string.rjust("ZZ", 32)
    )
    t.helpers.retrying(
        {},
        cluster.servers[1].check_status,
        cluster.servers[1], 'localhost:13302', 'non-decryptable'
    )
    t.helpers.retrying(
        {},
        cluster.servers[2].check_status,
        cluster.servers[2], 'localhost:13301', 'non-decryptable'
    )
end
