local options = {}

options.STATUS_NAMES = {'alive', 'suspect', 'dead', 'left'}
options.ALIVE = 1
options.SUSPECT = 2
options.DEAD = 3
options.LEFT = 4

options.PROTOCOL_PERIOD_SECONDS = 1.0 -- denoted as T' in SWIM paper
options.ACK_TIMEOUT_SECONDS = 0.200 -- ack timeout
options.ANTI_ENTROPY_PERIOD_SECONDS = 10.0

options.SUSPECT_TIMEOUT_SECONDS = 3
options.NUM_FAILURE_DETECTION_SUBGROUPS = 3 -- denoted as k in SWIM paper

options.EVENT_PIGGYBACK_LIMIT = 10

options.ENCRYPTION_INIT = 'init-key-16-byte' -- !!KEEP string len SYNCED with cryptoapi

function options.set_advertise_uri(uri)
    rawset(options, 'advertise_uri', uri)
end

function options.set_encryption_key(key)
    if key == nil then
        rawset(options, 'encryption_key', nil)
    else
        if key:len() < 32 then
            rawset(options, 'encryption_key', key:rjust(32))
        elseif key:len() > 32 then
            rawset(options, 'encryption_key', key:sub(1, 32))
        end
    end
end

setmetatable(options, {
    __newindex = function(tbl, idx, val)
        print(idx, val)
        error("options table is readonly")
    end
})

return options
