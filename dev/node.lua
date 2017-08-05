#!/usr/bin/env tarantool

local membership = require 'membership'
local fiber = require 'fiber'
local log = require 'log'

box.cfg{}

local advertise_uri = os.getenv("ADVERTISE_URI")
local bootstrap_uri = os.getenv("BOOTSTRAP")

membership.init(advertise_uri, bootstrap_uri)


local function print_members()
    while true do
        for _, member in membership.pairs() do
            log.info("[%s] %s", member.status, member.uri)
        end
        fiber.sleep(2)
    end
end


fiber.create(print_members)
