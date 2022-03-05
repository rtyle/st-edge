local cosock    = require "cosock"
local log       = require "log"

local classify  = require "classify"
local Emitter   = require "emitter"
local UPnP      = require "upnp"

local M = {
    Discover = classify.single({

        -- events emitted
        EVENT_DISCOVERED = "discovered",

        -- default arguments
        DISCOVER_BACKOFF_CAP    = 8,

        _init = function(class, self, upnp)
            classify.super(class):_init(self)
            self.upnp = upnp
            local urn = table.concat({UPnP.USN.SCHEMAS_UPNP_ORG, UPnP.USN.DEVICE, "MediaRenderer", 1}, ":")
            self.usn = UPnP.USN{[UPnP.USN.URN] = urn}
            self.discovery = function(address, port, header, description)
                if "Denon" == description.root.device.manufacturer then
                    log.debug(description.root.device.friendlyName, address, port, header.location, tostring(header.usn))
                    self:emit(self.EVENT_DISCOVERED, address, port, header, description)
                end
            end
            upnp:discovery_subscribe(self.usn, self.discovery)
        end,

        poll = function(self, backoff_cap, read_timeout)
            backoff_cap = backoff_cap or self.DISCOVER_BACKOFF_CAP
            if self._discover_sender then
                self._discover_sender:send(0)
            else
                local sender, receiver = cosock.channel.new()
                self._discover_sender = sender
                cosock.spawn(function()
                    local backoff = 0
                    while true do
                        self.upnp:discovery_search_multicast(self.usn)
                        -- rediscover after capped exponential backoff
                        -- or our receiver hears from our sender.
                        while cosock.socket.select({receiver}, {}, 8 << math.min(backoff, backoff_cap)) do
                            log.debug("rediscover")
                            backoff = receiver:receive()
                        end
                        backoff = backoff + 1
                    end
                end, "denon.Inventory.discover")
            end
        end,

    }, Emitter)
}

discover = M.Discover(UPnP("192.168.1.20"))

discover:on(discover.EVENT_DISCOVERED, function(address, port, header, description)
    -- log.debug()
end)

discover:poll(1)

cosock.run()