local cosock    = require "cosock"
local log       = require "log"

local xml       = require "xml"

local classify  = require "classify"
local UPnP      = require "upnp"

-- at the time of this writing, the latest firmware for
-- Denon AVR-X4100W UPnP service eventing are all worthless for our purposes
-- except RenderingControl, which will sendEvents only on its LastChange state variable.
-- this may have Mute and/or Volume state but only for the Master channel.
-- we are kept in sync with the device's Mute state.
-- we are not kept in sync with the device's Volume state and its value may be wrong.
local RENDERING_CONTROL
    = table.concat({UPnP.USN.UPNP_ORG, UPnP.USN.SERVICE_ID, "RenderingControl"}, ":")

local denon

local Break = classify.error({})

denon = {
    ST = UPnP.USN{[UPnP.USN.URN] = table.concat({UPnP.USN.SCHEMAS_UPNP_ORG, UPnP.USN.DEVICE, "MediaRenderer", 1}, ":")},

    AVR = classify.single({
        _init = function(_, self, uuid, upnp)
            log.debug("AVR", uuid)
            self.upnp = upnp
            self.uuid = uuid

            -- self.eventing capture is garbage collected with self
            self.eventing = function(_, encoded)
                pcall(function()
                    local event = xml.decode(encoded).root.Event.InstanceID
                    for _, name in ipairs{"Mute", "Volume"} do
                        local value = event[name]
                        if value then
                            self["eventing_" .. name:lower()](value._attr.channel, value._attr.val)
                        end
                    end
                end)
            end

            -- search until location and device for uuid is found
            local st = UPnP.USN{[UPnP.USN.UUID] = uuid}
            cosock.spawn(function()
                local function found(address, port, header, device)
                    local found_uuid = header.usn.uuid
                    if found_uuid ~= self.uuid then
                        log.error("found", found_uuid, "not", self.uuid)
                        return
                    end
                    log.debug("found", uuid, address, port, header.location, device.friendlyName)
                    self.location = header.location
                    self.device = device
                    for _, service in ipairs(device.serviceList.service) do
                        local urn = UPnP.USN(service.serviceId).urn
                        if urn == RENDERING_CONTROL then
                            upnp:eventing_subscribe(
                                header.location, service.eventSubURL, header.usn.uuid, urn, nil, self.eventing)
                            -- unsubscribe is implicit on garbage collection of self
                            break
                        end
                        Break()
                    end
                end

                local discover = denon.Discover(upnp, found, st)
                while true do
                    local _, break_error = pcall(function()
                        discover:search()
                        cosock.socket.sleep(60)
                    end)
                    if break_error then
                        local class_break_error = classify.class(break_error)
                        if Break ~= class_break_error then
                            error(break_error)
                        end
                    end
                end
            end, "find" .. tostring(st))
        end,

        eventing_mute = function(channel, value)
            log.error("AVR", "event", "drop", "mute", channel, value)
        end,

        eventing_volume = function(channel, value)
            log.error("AVR", "event", "drop", "volume", channel, value)
        end,
    }),

    Discover = classify.single({
        _init = function(_, self, upnp, found, st)
            st = st or denon.ST
            self.upnp = upnp
            self.found = found
            self.st = st

            -- self.discovery capture is garbage collected with self
            self.discovery = function(address, port, header, description)
                local device = description.root.device
                if "Denon" == device.manufacturer then
                    self.found(address, port, header, device)
                end
            end

            upnp:discovery_subscribe(st, self.discovery)
            -- unsubscribe is implicit on garbage collection of self
        end,

        search = function(self)
            self.upnp:discovery_search_multicast(self.st)
        end,
    }),
}

return denon