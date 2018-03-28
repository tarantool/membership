local options = {}

options.STATUS_NAMES = {'alive', 'suspect', 'dead'}
options.ALIVE = 1
options.SUSPECT = 2
options.DEAD = 3

options.PROTOCOL_PERIOD_SECONDS = 1.0 -- denoted as T' in SWIM paper
options.ACK_TIMEOUT_SECONDS = 0.200 -- ack timeout 
options.ANTI_ENTROPY_PERIOD_SECONDS = 10.0

options.SUSPECT_TIMEOUT_SECONDS = 3
options.NUM_FAILURE_DETECTION_SUBGROUPS = 3 -- denoted as k in SWIM paper

options.EVENT_PIGGYBACK_LIMIT = 10

function options.set_advertise_uri(uri)
    rawset(options, 'advertise_uri', uri)
end

setmetatable(options, {
    __newindex = function(tbl, idx, val)
        print(idx, val)
        error("options table is readonly")
    end
})

return options
