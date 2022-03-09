local cosock    = require "cosock"
local log       = require "log"

local xml       = require "xml"

local classify  = require "classify"
local UPnP      = require "upnp"

local M = {
    Discover = classify.single({

        -- default arguments
        DISCOVER_BACKOFF_CAP    = 8,

        _init = function(_, self, upnp)
            self.upnp = upnp
            self.media_renderer = UPnP.USN{[UPnP.USN.URN] = table.concat({UPnP.USN.SCHEMAS_UPNP_ORG, UPnP.USN.DEVICE, "MediaRenderer", 1}, ":")}
            self.rendering_control = table.concat({UPnP.USN.UPNP_ORG, UPnP.USN.SERVICE_ID, "RenderingControl"}, ":")
            self.eventing = function(_, encoded)
                pcall(function()
                    local event = xml.decode(encoded).root.Event.InstanceID
                    for _, name in ipairs{"Mute", "Volume"} do
                        local value = event[name]
                        if value then
                            log.debug("Denon", name, value._attr.channel, value._attr.val)
                        end
                    end
                end)
            end
            self.discovery = function(address, port, header, description)
                local device = description.root.device
                if "Denon" == device.manufacturer then
                    log.debug(device.friendlyName, address, port, header.location, tostring(header.usn))
                    for _, service in ipairs(device.serviceList.service) do
                        local urn = UPnP.USN(service.serviceId).urn
                        if urn == self.rendering_control then
                            upnp:eventing_subscribe(header.location, service.eventSubURL, header.usn.uuid, urn, nil, self.eventing)
                            break
                        end
                    end
                end
            end
            upnp:discovery_subscribe(self.media_renderer, self.discovery)
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
                        self.upnp:discovery_search_multicast(self.media_renderer)
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