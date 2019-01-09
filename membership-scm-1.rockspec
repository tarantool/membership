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

external_dependencies = {
    TARANTOOL = {
        header = 'tarantool/module.h',
    },
}

build = {
    type = 'cmake',
    variables = {
        version = 'scm-1',
        BUILD_DOC = '$(BUILD_DOC)',
        TARANTOOL_DIR = '$(TARANTOOL_DIR)',
        TARANTOOL_INSTALL_LIBDIR = '$(LIBDIR)',
        TARANTOOL_INSTALL_LUADIR = '$(LUADIR)',
    },
    install = {
        lua = {
            ['membership'] = 'membership.lua',
            ['membership.events'] = 'membership/events.lua',
            ['membership.members'] = 'membership/members.lua',
            ['membership.options'] = 'membership/options.lua',
            ['membership.network'] = 'membership/network.lua',
        }
    },
    copy_directories = {"doc"},
}
