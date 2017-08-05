#!/usr/bin/env tarantool

local function hook(cfg_override)
    local orig_cfg = box.cfg

    local function new_cfg(cfg)
        for k, v in pairs(cfg_override) do
            cfg[k] = v
        end

        orig_cfg(cfg)

        box.once('tarantool-entrypoint', function ()

             box.schema.user.grant("guest", 'read,write,execute',
                                   'universe', nil, {if_not_exists = true})
             box.schema.user.grant("guest", 'replication',
                                   nil, nil, {if_not_exists = true})
        end)
    end

    box.cfg = new_cfg
end

return {hook = hook,
        script_path = script_path}
