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
                function(zone, power, mute, volume, input, input_list)
                    log.info("test", zone, "power",     power)
                    log.info("test", zone, "mute",      mute)
                    log.info("test", zone, "volume",    volume)
                    log.info("test", zone, "input",     input)
                    log.info("test", zone, "list",      table.concat(input_list, "\t"))
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

    local _, avr = next(avr_set)
    while true do
        avr:refresh("Zone2")
        cosock.socket.sleep(0.1)
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
