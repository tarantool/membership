local t = require('luatest')
local g = t.group()
local cluster = require('test.helpers.cluster')

local SERVER_LIST = { 13301 }

g.before_all(function()
    cluster.start('localhost', SERVER_LIST)
end)

g.after_all(function()
    cluster.stop()
end)

g.test_probe_uri = function()
    t.assert(cluster.servers[1]:exec(function()
        rawset(_G, "warnings", {})
        require('log').warn = function(...)
            table.insert(warnings, string.format(...))
        end
        return true
    end))

    t.assert(cluster.servers[1]:probe_uri('localhost:13301'))
    t.assert_equals({ cluster.servers[1]:probe_uri('localhost:13302') }, { nil, 'no response' })
    t.assert_equals({ cluster.servers[1]:probe_uri('127.0.0.1:13301') }, { nil, 'no response' })
    t.assert_equals({ cluster.servers[1]:probe_uri(':::') }, { nil, 'parse error' })

    t.assert_equals({ cluster.servers[1]:probe_uri('unix/:/dev/null') }, { nil, 'ping was not sent' })
    t.assert_equals({ cluster.servers[1]:probe_uri('unknown-host:9') }, { nil, 'ping was not sent' })
    t.assert_equals({ cluster.servers[1]:probe_uri('-:/') }, { nil, 'ping was not sent' })

    -- https://github.com/tarantool/tarantool/commit/92fe50fa999d6153e8c4d5d43fb0c419ce05350e
    -- Tarantool didn't return error message up to 2.5
    local version = cluster.servers[1]:exec(function() return _TARANTOOL end)

    local version_parts = string.split(version, '.')
    local major = tonumber(version_parts[1])
    local minor = tonumber(version_parts[2])

    local is_linux = false
    local handle = io.popen("uname -s 2>/dev/null", "r")
    if handle then
        local os_name = handle:read("*a"):gsub("%s+", "")
        handle:close()
        is_linux = (os_name == 'Linux')
    end

    local expected_warnings
    if (major < 2) or (major == 2 and minor < 5) then
        expected_warnings = {
            'getaddrinfo: Unknown error (unix/:/dev/null)',
            'getaddrinfo: Unknown error (unknown-host:9)',
            'getaddrinfo: Unknown error (-)'
        }
    elseif major == 2 and minor == 10 then
        expected_warnings = {
            'getaddrinfo: Servname not supported for ai_socktype: Input/output error (unix/:/dev/null)',
            'getaddrinfo: Temporary failure in name resolution: Input/output error (unknown-host:9)',
            'getaddrinfo: Name or service not known: Input/output error (-)'
        }
    elseif is_linux then
        expected_warnings = {
            'getaddrinfo: Servname not supported for ai_socktype (unix/:/dev/null)',
            'getaddrinfo: Temporary failure in name resolution (unknown-host:9)',
            'getaddrinfo: Name or service not known (-)'
        }
    else
        expected_warnings = {
            'getaddrinfo: nodename nor servname provided, or not known (unix/:/dev/null)',
            'getaddrinfo: nodename nor servname provided, or not known (unknown-host:9)',
            'getaddrinfo: nodename nor servname provided, or not known (-)'
        }
    end

    t.assert_equals(
        cluster.servers[1]:exec(function() return warnings end),
        expected_warnings
    )
end
