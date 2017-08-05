#!/usr/bin/env tarantool

function script_path()
   local str = debug.getinfo(2, "S").source:sub(2)
   return str:match("(.*/)") or '.'
end

package.path = package.path .. ';'..script_path()..'/?.lua'
local hook = require('cfg_hook')

hook.hook({listen = 3301,
           work_dir = script_path() .. "/data/node1"
})

os.setenv('ADVERTISE_URI', 'localhost:3301')
os.setenv('BOOTSTRAP', 'localhost:3301')

dofile(script_path() .. "/node.lua")
