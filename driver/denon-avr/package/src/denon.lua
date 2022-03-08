local cosock    = require "cosock"
local log       = require "log"

local classify  = require "classify"
local UPnP      = require "upnp"

local M = {
    Discover = classify.single({

        -- default arguments
        DISCOVER_BACKOFF_CAP    = 8,

        _init = function(class, self, upnp)
            self.upnp = upnp
            local urn = table.concat({UPnP.USN.SCHEMAS_UPNP_ORG, UPnP.USN.DEVICE, "MediaRenderer", 1}, ":")
            self.usn = UPnP.USN{[UPnP.USN.URN] = urn}
            self.discovery = function(address, port, header, description)
                local device = description.root.device
                if "Denon" == device.manufacturer then
                    log.debug(device.friendlyName, address, port, header.location, tostring(header.usn))
                    for _, service in ipairs(device.serviceList.service) do
                        upnp:eventing_subscribe(header.location, service.eventSubURL, header.usn.uuid, UPnP.USN(service.serviceId).urn, nil,
                            function(name, event)
                                log.debug("Denon", name)
                            end)
                    end
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

    })
}

local discover = M.Discover(UPnP("192.168.1.20"))

discover:poll(1)

cosock.run()