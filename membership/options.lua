local options = {}
local log = require('log')
local cbc = require('crypto').cipher.aes256.cbc

options.STATUS_NAMES = {'alive', 'suspect', 'dead', 'non-decryptable', 'left'}
options.ALIVE = 1
options.SUSPECT = 2
options.DEAD = 3
options.NONDECRYPTABLE = 4
options.LEFT = 5

options.PROTOCOL_PERIOD_SECONDS = 1.0 -- denoted as T' in SWIM paper
options.ACK_TIMEOUT_SECONDS = 0.200 -- ack timeout
options.ANTI_ENTROPY_PERIOD_SECONDS = 10.0

options.SUSPECT_TIMEOUT_SECONDS = 3
options.NUM_FAILURE_DETECTION_SUBGROUPS = 3 -- denoted as k in SWIM paper

options.EVENT_PIGGYBACK_LIMIT = 10

-- 1472 = Default-MTU (1500) - IP-Header (20) - UDP-Header (8)
options.MAX_PACKET_SIZE = 1472

options.ENCRYPTION_INIT = 'init-key-16-byte' -- !!KEEP string len SYNCED with cryptoapi

function options.set_advertise_uri(uri)
    rawset(options, 'advertise_uri', uri)
end

function options.get_encryption_key()
    return options.encryption_key
end

function options.set_encryption_key(key)
    if key == nil then
        rawset(options, 'encryption_key', nil)
        log.info('Membership encryption disabled')
    else
        if key:len() < 32 then
            rawset(options, 'encryption_key', key:rjust(32))
        else
            rawset(options, 'encryption_key', key:sub(1, 32))
        end
        log.info('Membership encryption enabled')
    end
end

function options.encrypted_size(len)
    if not options.encryption_key then
        return len
    else
        return math.ceil((len+1)/16)*16
    end
end

function options.encrypt(msg)
    if not options.encryption_key then
        return msg, nil
    else
        return cbc.encrypt(
            msg,
            options.encryption_key,
            options.ENCRYPTION_INIT
        )
    end
end

function options.decrypt(msg)
    if not options.encryption_key then
        return msg, nil
    else
        return cbc.decrypt(
            msg,
            options.encryption_key,
            options.ENCRYPTION_INIT
        )
    end
end

setmetatable(options, {
    __newindex = function(tbl, idx, val)
        print(idx, val)
        error("options table is readonly")
    end
})

return options
