local cosock    = require "cosock"
local log       = require "log"

local UPnP      = require "upnp"

local denon     = require "denon"

local upnp = UPnP()

local avr_set = {}

cosock.spawn(function()
    local function find(address, port, header, device)
        local uuid = header.usn.uuid
        log.debug("test\tfind", uuid, address, port, header.location, device.friendlyName)
        local avr = avr_set[uuid]
        if not avr then
            avr = denon.AVR(uuid, upnp,
                function(value)
                    log.info("test", "online", value)
                end,
                function(zone, power, mute, volume, input)
                    log.info("test", zone, "power",     power)
                    log.info("test", zone, "mute",      mute)
                    log.info("test", zone, "volume",    volume)
                    log.info("test", zone, "input",     input)
                end
            )
            avr_set[uuid] = avr
        end
    end

    local discover = denon.Discover(upnp, find)
    for _ = 1, 2 do
        pcall(discover.search, discover)
        cosock.socket.sleep(8)
    end

    for _, avr in pairs(avr_set) do
        for _, zone in ipairs(avr.ZONE) do
            avr:command_on(zone, true)
            avr:command_on(zone, false)
        end
    end

    cosock.socket.sleep(1200)

    for _, avr in pairs(avr_set) do
        avr:stop()
    end
    avr_set = {}
    collectgarbage()

    upnp:stop()
    upnp:start()

end, "test\tfind" .. tostring(denon.ST))

cosock.run()
