package = 'membership'
version = 'scm-1'
source  = {
    url = 'git+ssh://git@gitlab.com:tarantool/membership.git',
    branch = 'master',
}
dependencies = {
    'lua >= 5.1',
    'checks ~> 3',
}

build = {
    type = 'none',
    install = {
        lua = {
            ['membership'] = 'membership.lua',
            ['membership.events'] = 'membership/events.lua',
            ['membership.members'] = 'membership/members.lua',
            ['membership.options'] = 'membership/options.lua',
            ['membership.network'] = 'membership/network.lua',
        }
    }
}
