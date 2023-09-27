local S = rawget(_G, '__membership_stash') or {}

local log = require('log')

local function f_body(fn_name, ...)
    local fiber = require('fiber')
    while true do
        S[fn_name](...)
        fiber.testcancel()
    end
end

assert(
    debug.getinfo(f_body, 'u').nups == 1,
    'Exceess closure upvalue'
)

local function fiber_new(fn_name, ...)
    if not S[fn_name] then
        error(('function %s not implemented'):format(fn_name), 2)
    end

    local k = 'fiber.' .. fn_name
    S[k] = require('fiber').new(f_body, fn_name, ...)
    return S[k]
end

local function fiber_cancel(fn_name)
    local k = 'fiber.' .. fn_name
    if S[k] ~= nil and S[k]:status() ~= 'dead' then
        local ok, err = pcall(S[k].cancel, S[k])
        if not ok then
            log.error('Fiber %s cancel error: %s', fn_name, err)
        end
        S[k] = nil
    end
end

rawset(_G, '__membership_stash', S)

return {
    get = function(k) return S[k] end,
    set = function(k, v) S[k] = v end,
    fiber_new = fiber_new,
    fiber_cancel = fiber_cancel,
}
