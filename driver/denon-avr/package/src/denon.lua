local cosock    = require "cosock"
local log       = require "log"

local xml       = require "xml"

local classify  = require "classify"
local UPnP      = require "upnp"

-- as of this writing, the latest Denon AVR-X4100W firmware,
-- UPnP service eventing are all worthless for our purposes
-- except RenderingControl, which will sendEvents only on its LastChange state variable.
-- this may have Mute and/or Volume state but only for the Master channel.
-- we are kept in sync with the device's Mute state.
-- we are not kept in sync with the device's Volume state and its value may be wrong.
-- reacting to the failure to renew a subscription allows us to rediscover the device.
-- the device may simply be offline or it may have relocated (IP address changed).
local RENDERING_CONTROL
    = table.concat({UPnP.USN.UPNP_ORG, UPnP.USN.SERVICE_ID, "RenderingControl"}, ":")
local MEDIA_RENDERER
    = table.concat({UPnP.USN.SCHEMAS_UPNP_ORG, UPnP.USN.DEVICE, "MediaRenderer", 1}, ":")

local LOG = "AVR"
local denon
denon = {
    ST = UPnP.USN{[UPnP.USN.URN] = MEDIA_RENDERER},

    AVR = classify.single({
        _init = function(_, self, uuid, upnp)
            self.upnp = upnp
            self.uuid = uuid
            log.debug(LOG, self.uuid)

            -- self.eventing capture is garbage collected with self
            self.eventing = function(_, encoded)
                pcall(function()
                    local event = xml.decode(encoded).root.Event.InstanceID
                    for _, name in ipairs{"Mute", "Volume"} do
                        local value = event[name]
                        if value then
                            self["eventing_" .. name:lower()](self, value._attr.channel, value._attr.val)
                        end
                    end
                end)
            end

            self:start()
        end,

        start = function(self)
            assert(not self.thread_sender, table.concat({LOG, self.uuid .. "started"}, "\t"))
            log.debug(LOG, self.uuid, "start")

            local thread_receiver
            self.thread_sender, thread_receiver = cosock.channel.new()
            cosock.spawn(function()

                local function find(address, port, header, device)
                    local uuid = header.usn.uuid
                    if uuid ~= self.uuid then
                        log.error(LOG, self.uuid, "find", "not", uuid)
                        return
                    end
                    self:send(0)    -- sleep
                    log.debug(LOG, self.uuid, "find", address, port, header.location, device.friendlyName)
                    self.location = header.location
                    self.device = device
                    for _, service in ipairs(device.serviceList.service) do
                        local urn = UPnP.USN(service.serviceId).urn
                        if urn == RENDERING_CONTROL then
                            local location, url = header.location, service.eventSubURL
                            if self.subscription then
                                self.subscription:locate(location, url)
                            else
                                self.subscription = self.upnp:eventing_subscribe(location, url,
                                    header.usn.uuid, urn, nil, self.eventing,
                                    function()
                                        self:send(1)    -- poll
                                    end)
                            end
                            break
                        end
                    end
                end

                local discover = denon.Discover(self.upnp, find, UPnP.USN{[UPnP.USN.UUID] = self.uuid})
                local poll = 60
                local timeout = poll
                while true do
                    if timeout then
                        pcall(discover.search, discover)    -- poll
                    end
                    local ready = cosock.socket.select({thread_receiver}, {}, timeout)
                    if ready then
                        local value = thread_receiver:receive()
                        if not value then
                            break   -- stop
                        else
                            if 0 == value then
                                timeout = nil   -- sleep
                            else
                                timeout = poll  -- poll
                            end
                        end
                    end
                end
                thread_receiver:close()
                log.debug(LOG, self.uuid, "stop")
            end, table.concat({LOG, self.uuid}, "\t"))
        end,

        send = function(self, value)
            if self.thread_sender then
                self.thread_sender:send(value)
            end
        end,

        stop = function(self)
            assert(self.thread_sender, table.concat({LOG, self.uuid .. "stopped"}, "\t"))
            self.thread_sender:close()  -- stop
            self.thread_sender = nil    -- stopped
            if self.subscription then
                self.subscription:unsubscribe()
                self.subscription = nil
            end
        end,

        eventing_mute = function(self, channel, value)
            log.warn(LOG, self.uuid, "event", "drop", "mute", channel, value)
        end,

        eventing_volume = function(self, channel, value)
            log.warn(LOG, self.uuid, "event", "drop", "volume", channel, value)
        end,
    }),

    Discover = classify.single({
        _init = function(_, self, upnp, find, st)
            st = st or denon.ST
            self.upnp = upnp
            self.find = find
            self.st = st

            -- self.discovery capture is garbage collected with self
            self.discovery = function(address, port, header, description)
                local device = description.root.device
                if "Denon" == device.manufacturer then
                    self.find(address, port, header, device)
                end
            end

            upnp:discovery_notify(st, self.discovery)
            -- undo is implicit on garbage collection of self
        end,

        search = function(self)
            self.upnp:discovery_search_multicast(self.st)
        end,
    }),
}

return denon
