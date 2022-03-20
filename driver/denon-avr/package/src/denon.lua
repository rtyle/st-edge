-- vim: ts=4:sw=4:expandtab

local cosock    = require "cosock"
local log       = require "log"

local http      = require "http"
local xml       = require "xml"

local classify  = require "classify"
local UPnP      = require "upnp"

-- as of this writing, the latest Denon AVR-X4100W firmware,
-- UPnP service eventing are all worthless for our purposes
-- except RenderingControl, which will sendEvents only on its LastChange state variable.
-- this may have Mute and/or Volume state but only for the Master channel (MainZone).
-- for the MainZone only,
-- we are kept in sync with the Mute state but only
-- we are not kept in sync with the device's Volume state and its value may be wrong.
-- reacting to the failure to renew a subscription allows us to rediscover the device.
-- the device may simply be offline or it may have relocated (IP address changed).
local RENDERING_CONTROL
    = table.concat({UPnP.USN.UPNP_ORG, UPnP.USN.SERVICE_ID, "RenderingControl"}, ":")
local MEDIA_RENDERER
    = table.concat({UPnP.USN.SCHEMAS_UPNP_ORG, UPnP.USN.DEVICE, "MediaRenderer", 1}, ":")

local MAIN_ZONE = "MainZone"

local LOG = "AVR"
local denon
denon = {
    ST = UPnP.USN{[UPnP.USN.URN] = MEDIA_RENDERER},

    AVR = classify.single({
        ZONE = {
            MAIN_ZONE,
            "Zone2",
            "Zone3",
        },

        INPUT = {   -- default names by API id
            -- these may be renamed and have hardware inputs assigned to them
            CBLSAT  = 'CBL/SAT',
            DVD     = 'DVD',
            BD      = 'Blu-ray',
            GAME    = 'Game',
            MPLAY   = 'Media Player',
            TV      = 'TV Audio',
            AUX1    = 'AUX1',
            AUX2    = 'AUX2',
            CD      = 'CD',
            PHONO   = 'Phono',
            -- these sources cannot be renamed and require further configuration
            TUNER   = 'Tuner',
            BT      = 'Bluetooth',
            IPOD    = 'iPod/USB',
            NETHOME = 'Online Music',
            SERVER  = 'Media Server',
            IRP     = 'Internet Radio',
        },

        _init = function(_, self, uuid, upnp, notify_online, notify_refresh, read_timeout)
            self.upnp = upnp
            self.uuid = uuid
            self.notify_online = notify_online
            self.notify_refresh = notify_refresh
            self.read_timeout = read_timeout or 1
            self.online = false
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
                    self:thread_send(true)    -- online
                    log.debug(LOG, self.uuid, "find", address, port, header.location, device.friendlyName)
                    self.address = address
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
                                        self:thread_send(false)    -- offline
                                    end)
                            end
                            break
                        end
                    end
                end

                local discover = denon.Discover(self.upnp, find, UPnP.USN{[UPnP.USN.UUID] = self.uuid})
                while nil ~= self.online do
                    local timeout = nil
                    if not self.online then
                        pcall(discover.search, discover)
                        timeout = 60
                    end
                    local ready = cosock.socket.select({thread_receiver}, {}, timeout)
                    if ready then
                        local online = thread_receiver:receive() -- nil (stop), true or false
                        if self.online ~= online then
                            self.online = online
                            pcall(self.notify_online, online)
                            if online then
                                self:refresh()
                            end
                        end
                    end
                end
                thread_receiver:close()
                log.debug(LOG, self.uuid, "stop")
            end, table.concat({LOG, self.uuid}, "\t"))
        end,

        thread_send = function(self, value)
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
            self.eventing = nil
        end,

        eventing_mute = function(self, _, _)
            self:refresh(MAIN_ZONE)
        end,

        eventing_volume = function(self, channel, value)
            log.warn(LOG, self.uuid, "event", "drop", "volume", channel, value)
        end,

        command = function(self, zone, form)
            -- AVR expects urlencoded form to be in body (instead of appended to path)
            local url = "http://" .. self.address .. "/MainZone/index.put.asp"
            local body_form = "ZoneName=" .. zone .. "&cmd0=Put" .. form
            log.debug(LOG, self.uuid, "command", zone, form, "curl -d '" .. body_form .. "' -X POST " .. url)
            local request_header = {
                "CONTENT-TYPE: application/x-www-form-urlencoded",
            }
            local response, response_error
                = http:transact(url, "POST", self.read_timeout, request_header, body_form)
            if response_error then
                log.error(LOG, self.uuid, "command", zone, form, response_error)
                return
            end
            local status, _, body = table.unpack(response)
            local _, code, reason = table.unpack(status)
            if http.OK ~= code then
                log.error(LOG, self.uuid, "command", zone, form, reason or code)
                return
            end
            local result_ok, result = pcall(function()
                return xml.decode(body).root
            end)
            if not result_ok then
                log.error(LOG, self.uuid, "command", zone, form, body, result)
                return
            end
            return result
        end,

        refresh = function(self, zone)
            if not zone then
                for _, _zone in ipairs(self.ZONE) do
                    self:refresh(_zone)
                end
                return
            end
            local url = "http://" .. self.address .. "/goform/formMainZone_MainZoneXml.xml?ZoneName=" .. zone
            log.debug(LOG, self.uuid, "refresh", zone, "curl -X GET " .. url)
            local response, response_error = http:transact(url, "GET", self.read_timeout)
            if response_error then
                log.error(LOG, self.uuid, "refresh", zone, response_error)
                return
            end
            local status, _, body = table.unpack(response)
            local _, code, reason = table.unpack(status)
            if http.OK ~= code then
                log.error(LOG, self.uuid, "refresh", zone, reason or code)
                return
            end
            local result_ok, result = pcall(function()
                return xml.decode(body).root.item
            end)
            if not result_ok then
                log.error(LOG, self.uuid, "refresh", zone, body, result)
                return
            end
            pcall(self.notify_refresh, zone,
                "on" == result.ZonePower.value:lower(),
                "on" == result.Mute.value:lower(),
                -- convert API volume value to that shown on the front panel (and web UI)
                -- volume shown on monitor hooked up to AVR will be 2 more than this.
                80 + (tonumber(result.MasterVolume.value) or -80),
                (function(a, b)
                    if "Online Music" == a then
                        if "SERVER" == b then
                            return "Media Server"
                        elseif "IRADIO" == b then
                            return "Internet Radio"
                        else -- "NET"
                            return "Online Music"
                        end
                    end
                    return a
                end)(result.InputFuncSelect.value, result.NetFuncSelect.value)
            )
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
