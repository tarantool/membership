#!/usr/bin/env tarantool

local debug = require('debug')
local log = require('log')

local function trim(str)
    return str:match('^%s*(.*%S)') or ''
end

local function new_class(class_name, options)
    options = options or {}

    local capture_stack = true
    local log_on_creation = false

    if options.capture_stack ~= nil then
        capture_stack = options.capture_stack
    end

    if options.log_on_creation ~= nil then
        log_on_creation = options.log_on_creation
    end

    local class = {name=class_name,
                   capture_stack=capture_stack,
                   log_on_creation=log_on_creation}

    local function err_to_string(self)
        return self.str
    end

    local function new(self, fmt, ...)
        if type(self) ~= "table" then
            return nil
        end

        local err = string.format(tostring(fmt), ...)

        local frame = debug.getinfo(2, "Sl")
        local line = 0
        local file = 'eval'

        if type(frame) == 'table' then
            line = frame.currentline or 0
            file = frame.short_src or frame.src or 'eval'
        end

        local str = nil
        local stack = nil

        if not self.capture_stack then
            str = string.format("%s: %s", self.name, err)

            if self.log_on_creation then
                log.error(str)
            end
        else
            stack = trim(debug.traceback("", 2))
            str = string.format("%s: %s\n%s", self.name, err, stack)

            if self.log_on_creation then
                log.error(str)
            end
        end

        local o = {line=line, file=file, err=err, str=str, stack=stack}
        setmetatable(o, self)
        self.__index = self

        return o
    end

    class.new = new
    class.__tostring = err_to_string

    return class
end


return {new_class=new_class}
