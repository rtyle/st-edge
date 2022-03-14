-- https://openconnectivity.org/upnp-specs/UPnP-arch-DeviceArchitecture-v2.0-20200417.pdf

local cosock    = require "cosock"
local log       = require "log"

local date      = require "date"

local classify  = require "classify"
local http      = require "http"
local Reader    = require "reader"
local split     = require "split"
local xml       = require "xml"

local function epoch_time()
    return date.diff(date(true), date.epoch()):spanseconds()
end

local function address_for(peer)
    local socket = cosock.socket.udp()
    socket:setpeername(peer, 0)
    local address = socket:getsockname()
    socket:close()
    return address
end

local USN = classify.single({
    -- URI schemes
    UUID        = "uuid",
    UPNP        = "upnp",
    URN         = "urn",

    -- URI paths and path parts (concatente parts with colon)
    ROOTDEVICE          = "rootdevice",
    SCHEMAS_UPNP_ORG    = "schemas-upnp-org",
    DEVICE              = "device",
    SERVICE             = "service",
    UPNP_ORG            = "upnp-org",
    SERVICE_ID          = "serviceId",

    _init = function(_, self, uri)
        if "string" == type(uri) then
            uri = self._fromstring(uri)
        end
        self[self.UUID] = uri[self.UUID]
        self[self.UPNP] = uri[self.UPNP]
        self[self.URN ] = uri[self.URN ]
    end,

    _fromstring = function(encoded)
        local uri = {}
        for _, pair in ipairs(split(encoded, "::", 0)) do
            local kv = split(pair, ":", 2)
            uri[kv[1]] = kv[2]
        end
        return uri
    end,

    __tostring = function(self)
        local encoded = {}
        for _, scheme in ipairs{self.UUID, self.UPNP, self.URN} do
            if self[scheme] then
                table.insert(encoded, table.concat({scheme, self[scheme]}, ":"))
            end
        end
        return table.concat(encoded, "::")
    end,
})

local function list_from(set)
    local result = {}
    for element in pairs(set) do
        table.insert(result, element)
    end
    return result
end

-- use for subscription tables
-- unsubscription is implicit after garbage collection of subscribed method
local WeakKeys = classify.single({
    __mode = "k",
    _init = function() end
})

return classify.single({    -- UPnP
    -- http
    PROTOCOL    = http.PROTOCOL,
    EOL         = http.EOL,

    -- ssdp
    SSDP_MULTICAST_ADDRESS    = "239.255.255.250",
    SSDP_MULTICAST_PORT       = 1900,

    -- classes
    USN   = USN,
    Break = classify.error({}), -- construct to break out of UPnP thread loop
    Close = classify.error({}), -- construct to close (what was ready is no longer willing or able)

    _init = function(_, self, read_timeout, _name)
        self.read_timeout = read_timeout or 1
        self.name = _name or "UPnP"
        log.debug(self.name)

        -- set of willing receivers
        local willing = {}

        -- support UPnP Discovery
        -- with a udp socket
        -- and UPnP:discovery* methods
        self.discovery_notification = WeakKeys()
        self.discovery_socket = cosock.socket.udp()
        willing[self.discovery_socket] = function()
            -- receive and process one HTTPU datagram to fulfill matching discovery_notification
            local peer_address, peer_port
            local reader = Reader(coroutine.wrap(function()
                local datagram
                datagram, peer_address, peer_port = self.discovery_socket:receivefrom(2048)
                coroutine.yield(datagram)
                return nil, "closed"
            end))
            local discovery_response_ok, discovery_response = pcall(http.message, http, reader)
            if not discovery_response_ok then
                log.error(self.name, "discovery", "receive", discovery_response)
                return
            end
            local discovery_status, discovery_header = table.unpack(discovery_response)
            local _, discovery_code, discovery_reason = table.unpack(discovery_status)
            if http.OK ~= discovery_code then
                log.error(self.name, "discovery", "receive", discovery_reason or discovery_code)
                return
            end
            local usn = USN(discovery_header.usn)
            if not (next(self.discovery_notification) and (function()
                for scheme, value in pairs(usn) do
                    if self.discovery_notification[table.concat({scheme, value}, ":")] then
                        return true
                    end
                end
            end)()) then
                -- log.warn(self.name, "discovery", "receive", "drop", discovery_header.usn)
                return
            end
            local location_response_ok, location_response
                = pcall(http.get, http, discovery_header.location, self.read_timeout)
            if not location_response_ok then
                log.error(self.name, "discovery", "receive", "location", location_response)
                return
            end
            local location_status, _, location_body = table.unpack(location_response)
            local _, location_code, location_reason = table.unpack(location_status)
            if http.OK ~= location_code then
                log.error(self.name, "discovery", "receive", "location", location_reason or location_code)
                return
            end
            local description_ok, description = pcall(function()
                return xml.decode(location_body).root
            end)
            if not description_ok then
                log.error(self.name, "discovery", "receive", "description", description, location_body)
                return
            end
            discovery_header.usn = usn
            for scheme, value in pairs(usn) do
                local set = self.discovery_notification[table.concat({scheme, value}, ":")]
                if set then
                    for notify in pairs(set) do
                        notify(peer_address, peer_port, discovery_header, description)
                    end
                end
            end
        end

        -- support UPnP Eventing
        -- with a tcp listen socket and those accepted from it
        -- and UPnP:eventing* methods
        self.eventing_address = {}
        self.eventing_subscription = {}
        self.eventing_notification = {}
        -- SmartThings implementation of cosock.socket.bind convenience function
        -- will fail on skt:setoption("reuseaddr", true)
        -- As commented, even they are not sure why they are doing this step
        -- It is not needed so we perform only the tcp socket create, bind and listen steps.
        local listen_socket = cosock.socket.tcp()
        listen_socket:bind("*", 0)
        listen_socket:listen(8)
        local _, port = listen_socket:getsockname()
        self.port = port
        log.debug(self.name, "event", "socat - TCP:" .. address_for("1.1.1.1") .. ":" .. self.port .. ",crnl")
        willing[listen_socket] = function()
            local accept_socket, accept_error = listen_socket:accept()
            if accept_error then
                self.Close(port)
            end
            local peer_address, peer_port = accept_socket:getpeername()
            log.debug(self.name, "receive", "accept", peer_address, peer_port)
            local reader = http:reader(accept_socket, self.read_timeout)
            willing[accept_socket] = function()
                local response_ok, response = pcall(http.message, http, reader)
                if not response_ok then
                    self.Close(peer_address, peer_port)
                end
                local _, eventing_error = pcall(function()
                    local action, _, body = table.unpack(response)
                    local _, path = table.unpack(action)
                    local part = split(path:sub(2), "/", 3)
                    local prefix = table.concat({part[1], part[2]}, "/")
                    local prefix_set = self.eventing_notification[prefix]
                    if not prefix_set then
                        log.warn(self.name, "event", "drop", path)
                    else
                        local function visit(node, name)
                            local node_type = type(node)
                            if "table" == node_type then
                                for child_name, child_node in pairs(node) do
                                    if "_attr" ~= child_name then
                                        visit(child_node, child_name)
                                    end
                                end
                            elseif "string" == node_type then
                                local statevar_set = prefix_set[name] or prefix_set[""]
                                if not statevar_set then
                                    log.warn(self.name, "event", "drop", path, name)
                                else
                                    for notify in pairs(statevar_set) do
                                        notify(name, node)
                                    end
                                end
                            else
                                log.error(self.name, "event", "drop", path, name, node_type)
                            end
                        end
                        visit(xml.decode(body).root)
                    end
                end)
                if (eventing_error) then
                    log.error(self.name, "event", eventing_error)
                end
            end
        end

        -- receive thread
        local receive_receiver
        self.receive_sender, receive_receiver = cosock.channel.new()
        willing[receive_receiver] = function()
            receive_receiver:receive()
            self.Break()
        end
        cosock.spawn(function()
            while receive_receiver do
                -- wait for anything that we are willing to receive from
                local ready, select_error = cosock.socket.select(list_from(willing))
                if select_error then
                    -- stop on unexpected error
                    log.error(self.name, "receive", "select", select_error)
                    break
                end
                while 0 < #ready do
                    local receiver = table.remove(ready, 1)
                    local ok, able_error = pcall(willing[receiver])
                    if not ok then
                        local class_able_error = classify.class(able_error)
                        if self.Break == class_able_error then
                            log.debug(self.name, "receive", "break", table.unpack(able_error))
                            receive_receiver = nil -- break out of outer loop
                        else
                            if self.Close == class_able_error then
                                log.debug(self.name, "receive", "close", table.unpack(able_error))
                            else
                                log.error(self.name, "receive", "close", able_error)
                            end
                            receiver:close()
                            willing[receiver] = nil
                        end
                    end
                end
            end
            for receiver in pairs(willing) do
                receiver:close()
            end
            willing = {}
        end, table.concat({self.name, "receive"}, "\t"))

        -- subscribe thread
        local subscribe_receiver
        self.subscribe_sender, subscribe_receiver = cosock.channel.new()
        cosock.spawn(function()
            while true do
                local timeout_min = nil -- forever
                local before = epoch_time()
                for _, subscription in pairs(self.eventing_subscription) do
                    local timeout = subscription.expiration - before
                    if not timeout_min then
                        timeout_min = timeout
                    else
                        timeout_min = math.max(0, math.min(timeout_min, timeout))
                    end
                end
                local ready, select_error = cosock.socket.select({subscribe_receiver}, {}, timeout_min)
                if select_error then
                    -- stop on unexpected error
                    log.error(self.name, "subscribe", "select", select_error)
                    break
                end
                if ready then
                    if 0 == subscribe_receiver:receive() then
                        break
                    end
                else    -- timeout
                    local after = epoch_time()
                    for path, subscription in pairs(self.eventing_subscription) do
                        if (after >= subscription.expiration) then
                            self:eventing_subscription_renew(path, subscription)
                        end
                    end
                end
            end
        end, table.concat({self.name, "subscribe"}, "\t"))
    end,

    stop = function(self)
        self.receive_sender:send(0)
        self.subscribe_sender:send(0)
    end,

    discovery_notify = function(self, usn, notify)
        for scheme, value in pairs(usn) do
            local uri = table.concat({scheme, value}, ":")
            local set = self.discovery_notification[uri]
            if not set then
                set = WeakKeys()
                self.discovery_notification[uri] = set
            end
            set[notify] = true
        end
    end,

    discovery_search = function(self, address, port, st, mx)
        log.debug(self.name, "discovery", "search", address, port, st, mx)
        local request = {
            table.concat({"M-SEARCH", "*", self.PROTOCOL}, " "),
            table.concat({"HOST", table.concat({address, port}, ":")}, ": "),
            table.concat({"MAN" , '"ssdp:discover"'}, ": "),
            table.concat({"ST"  , tostring(st)}, ": "),
        }
        if mx then
            table.insert(request, table.concat({"MX", mx}, ": "))
            table.insert(request, table.concat({"CPFN.UPNP.ORG", self.name}, ": "))
        end
        table.insert(request, self.EOL)
        self.discovery_socket:sendto(table.concat(request, self.EOL), address, port)
    end,

    discovery_search_multicast = function(self, st, mx)
        self:discovery_search(self.SSDP_MULTICAST_ADDRESS, self.SSDP_MULTICAST_PORT, st, mx or 1)
    end,

    discovery_search_unicast = function(self, st, address, port)
        self:discovery_search(address, port, st)
    end,

    eventing_address_for = function(self, peer)
        local address = address_for(peer)
        local eventing_address = self.eventing_address[peer]
        if eventing_address and address ~= eventing_address then
            -- address that peer should use has changed
            -- invalidate each self.eventing_subscription with peer
            for _, subscription in pairs(self.eventing_subscription) do
                if peer == subscription.peer then
                    subscription.sid = nil
                    subscription.expiration = 0    -- renew immediately
                end
            end
        end
        self.eventing_address[peer] = address
        return address
    end,

    eventing_address_change = function(self)
        local peer_set = {}
        for _, subscription in pairs(self.eventing_subscription) do
            peer_set[subscription.peer] = true
        end
        for peer in pairs(peer_set) do
            self:eventing_address_for(peer)
        end
    end,

    eventing_subscription_new = function(self, url, path)
        local peer = table.unpack(http:url_parse(url))
        local address = self:eventing_address_for(peer)
        local callback = "http://" .. address .. ":" .. self.port .. "/" .. path
        local request_header = {
            "CALLBACK: <" .. callback .. ">",
            "NT: upnp:event",
        }
        local statevar = split(path, "/", 3)[3]
        if 0 < #statevar then
            table.insert(request_header, table.concat({"STATEVAR", statevar}, ": "))
        end
        local now = epoch_time()
        local subscription = {
            url = url,
            expiration = now + 300, -- (re)new later unless success (below)
            peer = peer,
        }
        self.eventing_subscription[path] = subscription
        local response, response_error = http:transact(url, "SUBSCRIBE", self.read_timeout, request_header)
        if response_error then
            log.error(self.name, "event", "new", url, path, callback, response_error)
        else
            local status, header = table.unpack(response)
            local _, code, reason = table.unpack(status)
            if http.OK ~= code then
                log.error(self.name, "event", "new", url, path, callback, reason or code)
                return
            end
            local sid, timeout = header.sid, header.timeout
            log.debug(self.name, "event", "new", url, path, callback, sid, timeout)
            local duration = math.max(60, tonumber(timeout:match("Second%-(%d+)")))
            -- success. renew before expiration
            subscription.sid = sid
            subscription.expiration = now + duration - 8
        end
    end,

    eventing_subscription_renew = function(self, path, subscription)
        local url, sid = subscription.url, subscription.sid
        if sid then
            local request_header = {
                "SID: " .. sid,
            }
            local response, response_error = http:transact(url, "SUBSCRIBE", self.read_timeout, request_header)
            if response_error then
                log.error(self.name, "event", "renew", url, path, sid, response_error)
            else
                local status, header = table.unpack(response)
                local _, code, reason = table.unpack(status)
                if http.OK ~= code then
                    log.error(self.name, "event", "renew", url, path, sid, reason or code)
                else
                    local timeout = header.timeout
                    log.debug(self.name, "event", "renew", url, path, sid, timeout)
                    local duration = math.max(60, tonumber(timeout:match("Second%-(%d+)")))
                    subscription.expiration = epoch_time() + duration - 8
                    return
                end
            end
        end
        self:eventing_subscription_new(url, path)
    end,

    eventing_notify = function(self, prefix, statevar_list, notify)
        local prefix_set = self.eventing_notification[prefix]
        if not prefix_set then
            prefix_set = {}
            self.eventing_notification[prefix] = prefix_set
        end
        for _, name in ipairs(statevar_list) do
            local statevar_set = prefix_set[name]
            if not statevar_set then
                statevar_set = WeakKeys()
                prefix_set[name] = statevar_set
            end
            statevar_set[notify] = true
        end
    end,

    eventing_subscribe = function(self, location, url, device, service, statevar_list, notify)
        if "/" == url:sub(1, 1) then
            -- qualify relative url with location prefix
            url = location:match("(http://[%a%d-%.:]+)/.*") .. url
        end
        local prefix = table.concat({device, service}, "/")
        statevar_list = statevar_list or {""}
        self:eventing_notify(prefix, statevar_list, notify)
        local path = table.concat({prefix, table.concat(statevar_list, ",")}, "/")
        self:eventing_subscription_new(url, path)
        self.subscribe_sender:send(1)
    end,
})
