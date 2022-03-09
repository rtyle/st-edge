local cosock    = require "cosock"
local log       = require "log"

local classify  = require "classify"
local UPnP      = require "upnp"

local denon     = require "denon"

local upnp = UPnP("192.168.1.20")

local Break = classify.error({})

local avr_set = {}

cosock.spawn(function()
    local function found(address, port, header, device)
        local uuid = header.usn.uuid
        log.debug("found", uuid, address, port, header.location, device.friendlyName)
        local avr = avr_set[uuid]
        if not avr then
            avr = denon.AVR(uuid, upnp)
            avr_set[uuid] = avr
        end
    end

    local discover = denon.Discover(upnp, found)
    for _ = 1, 8 do
        local _, break_error = pcall(function()
            discover:search()
            cosock.socket.sleep(8)
        end)
        if break_error then
            local class_break_error = classify.class(break_error)
            if Break ~= class_break_error then
                error(break_error)
            end
        end
    end
end, "find" .. tostring(denon.ST))

cosock.run()