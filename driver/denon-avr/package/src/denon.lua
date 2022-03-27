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
-- we are kept in sync with the Mute state
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
                    self.address = address
                    self:thread_send(true)    -- online
                    log.debug(LOG, self.uuid, "find", address, port, header.location, device.friendlyName)
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
                                self.input_map, self.input_list = nil, nil
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

        eventing_mute = function(self, channel, value)
            log.debug(LOG, self.uuid, "event", "drop", "mute", channel, value)
        end,

        eventing_volume = function(self, channel, value)
            log.debug(LOG, self.uuid, "event", "drop", "volume", channel, value)
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
                log.error(LOG, self.uuid, "command", zone, form, code, reason)
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

        command_power = function(self, zone, on)
            local value = "OFF"
            if on then
                value = "ON"
            end
            return self:command(zone, "Zone_OnOff%2f" .. value)
        end,

        command_mute = function(self, zone, on)
            local value = "OFF"
            if on then
                value = "ON"
            end
            return self:command(zone, "VolumeMute%2f" .. value)
        end,

        command_volume_step = function(self, zone, up)
            local value = "%3e" -- <
            if up then
                value = "%3e"   -- >
            end
            return self:command(zone, "MasterVolumeBtn%2f" .. value)
        end,

        command_volume = function(self, zone, volume)
            return self:command(zone, "MasterVolumeSet%2f" .. volume - 80)
        end,

        command_input = function(self, zone, input)
            return self:command(zone, "Zone_InputFunction%2f" .. input)
        end,

        -- return mapping of unhidden source input names
        -- from those we see when we get them (possibly renamed)
        -- to those we need when we set them.
        input = function(self)
            if self.input_map and self.input_list then
                return self.input_map, self.input_list
            end
            local url = "http://" .. self.address .. "/SETUP/INPUTS/SOURCERENAME/d_Rename.asp"
            log.debug(LOG, self.uuid, "input", "curl " .. url)
            local response, response_error = http:get(url, self.read_timeout)
            if response_error then
                log.error(LOG, self.uuid, "input", response_error)
                return
            end
            local status, _, body = table.unpack(response)
            local _, code, reason = table.unpack(status)
            if http.OK ~= code then
                log.error(LOG, self.uuid, "input", code, reason)
                return
            end
            -- static sources that cannot be renamed
            local map = {
                ["Tuner"]       = "TUNER",
                ["Bluetooth"]   = "BT",
                ["iPod/USB"]    = "USB%2fIPOD",
                ["NET"]         = "NETHOME",
                ["SERVER"]      = "SERVER",
                ["IRADIO"]      = "IRP",
            }
            -- add unhidden, potentially renamed, names
            -- body is bad XHTML. parse with regex
            for set, get in body:gmatch("name=['\"]textFuncRename(%w+)['\"]%s+value=['\"]([^'\"]*)['\"]") do
                if set == "SATCBL" then
                    set = "SAT%2fCBL"
                end
                map[get] = set
            end
            local list = {}
            for _, set in pairs(map) do
                table.insert(list, set)
            end
            self.input_list = list
            self.input_map = map
            return map, list
        end,

        refresh = function(self, zone)
            if not zone then
                for _, _zone in ipairs(self.ZONE) do
                    self:refresh(_zone)
                end
                return
            end
            local url = "http://" .. self.address .. "/goform/formMainZone_MainZoneXml.xml?ZoneName=" .. zone
            log.debug(LOG, self.uuid, "refresh", zone, "curl " .. url)
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
            self:input()
            pcall(self.notify_refresh, zone,
                "on" == result.ZonePower.value:lower(),
                "on" == result.Mute.value:lower(),
                -- convert API volume value to that shown on the front panel (and web UI)
                -- volume shown on monitor hooked up to AVR will be 2 more than this.
                80 + (tonumber(result.MasterVolume.value) or -80),
                self.input_map[(function(a, b)
                    if "Online Music" == a then
                        return b
                    end
                    return a
                end)(result.InputFuncSelect.value, result.NetFuncSelect.value)],
                self.input_list
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
