local cosock    = require "cosock"
local log       = require "log"

local classify  = require "classify"
local UPnP      = require "upnp"

local denon     = require "denon"

local upnp = UPnP()
upnp:start()

local Break = classify.error({})

local avr_set = {}

cosock.spawn(function()
    local function find(address, port, header, device)
        local uuid = header.usn.uuid
        log.debug("test\tfind", uuid, address, port, header.location, device.friendlyName)
        local avr = avr_set[uuid]
        if not avr then
            avr = denon.AVR(uuid, upnp)
            avr_set[uuid] = avr
        end
    end

    local discover = denon.Discover(upnp, find)
    for _ = 1, 2 do
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

    cosock.socket.sleep(600)
    upnp:stop()
    upnp:start()
    cosock.socket.sleep(600)

end, "test\tfind" .. tostring(denon.ST))

cosock.run()
