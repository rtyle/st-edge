-- https://openconnectivity.org/upnp-specs/UPnP-arch-DeviceArchitecture-v2.0-20200417.pdf

local cosock    = require "cosock"
local log       = require "log"

local classify  = require "classify"
local http      = require "http"
local Reader    = require "reader"
local split     = require "split"
local xml       = require "xml"

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

-- use for subscription tables
-- unsubscription is implicit after garbage collection
local WeakValues = classify.single({
    __mode = "v",
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

    _init = function(_, self, address, read_timeout, _name)
        self.address = address
        self.read_timeout = read_timeout or 1
        self.name = _name or "UPnP"
        log.debug(self.name, "address", address)

        local willing_set = {}

        -- support UPnP:stop
        local stop_sender, stop_receiver = cosock.channel.new()
        self.stop_sender = stop_sender
        willing_set[stop_receiver] = function()
            stop_receiver:receive()
            self.Break()
        end

        -- support UPnP Discovery
        -- with a udp socket
        -- and UPnP:discovery_subscribe and UPnP:discovery_search*
        self.discovery_subscription = {}
        self.discovery_socket = cosock.socket.udp()
        willing_set[self.discovery_socket] = function()
            -- receive and process one HTTPU datagram to fulfill matching discovery_subscription
            local peer_address, peer_port
            local reader = Reader(coroutine.wrap(function()
                local datagram
                datagram, peer_address, peer_port = self.discovery_socket:receivefrom(2048)
                coroutine.yield(datagram)
                return nil, "closed"
            end))
            local ok, message = pcall(function()
                local _, message = http:message(reader)
                local response, header = table.unpack(message)
                return {response, header, xml.decode(http:get(header.location, self.read_timeout)[3]).root}
            end)
            if not ok then
                log.error(self.name, "discovery", peer_address, peer_port, message)
            else
                local _, header, description = table.unpack(message)
                header.usn = USN(header.usn)
                for scheme, value in pairs(header.usn) do
                    local list = self.discovery_subscription[table.concat({scheme, value}, ":")]
                    if list then
                        for _, discovery in ipairs(list) do
                            discovery(peer_address, peer_port, header, description)
                        end
                    end
                end
            end
        end

        -- support UPnP Eventing
        -- with a tcp listen socket and those accepted from it
        -- and UPnP:eventing_subscribe
        self.eventing_subscription = {}
        local listen_socket = cosock.socket.bind('*', 0)
        local _, port = listen_socket:getsockname()
        log.debug(self.name, "event", port)
        self.port = port
        willing_set[listen_socket] = function()
            local accept_socket, accept_error = listen_socket:accept()
            if accept_error then
                self.Close(port)
            end
            local peer_address, peer_port = accept_socket:getpeername()
            log.debug(self.name, "event", "accept", peer_address, peer_port)
            local reader = http:reader(accept_socket, self.read_timeout)
            willing_set[accept_socket] = function()
                local message_ok, message = http:message(reader)
                if not message_ok then
                    self.Close(peer_address, peer_port)
                end
                local _, eventing_error = pcall(function()
                    local action, _, body = table.unpack(message)
                    local _, path, _ = table.unpack(action)
                    local part = split(path:sub(2), "/", 3)
                    local prefix = table.concat({part[1], part[2]}, "/")
                    local set = self.eventing_subscription[prefix]
                    if not set then
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
                                local list = set[name] or set[""]
                                if not list then
                                    log.warn(self.name, "event", "drop", path, name)
                                else
                                    local event = xml.decode(node).root
                                    for _, eventing in ipairs(list) do
                                        eventing(event)
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

        -- support thread
        cosock.spawn(function()
            while stop_receiver do
                -- wait for anything that we are willing to receive from
                local willing_list = {}
                for willing, _ in pairs(willing_set) do
                    table.insert(willing_list, willing)
                end
                local ready_list, select_error = cosock.socket.select(willing_list)
                if select_error then
                    -- stop on unexpected error
                    log.error(self.name, "thread", "select", select_error)
                    break
                end
                while 0 < #ready_list do
                    local ready = table.remove(ready_list, 1)
                    local ok, able_error = pcall(function()
                        willing_set[ready]()
                    end)
                    if not ok then
                        local class_able_error = classify.class(able_error)
                        if self.Break == class_able_error then
                            log.debug(self.name, "thread", "break", table.unpack(able_error))
                            stop_receiver = nil -- break out of outer loop
                        else
                            if self.Close == class_able_error then
                                log.debug(self.name, "thread", "close", table.unpack(able_error))
                            else
                                log.debug(self.name, "thread", "close", able_error)
                            end
                            ready:close()
                            willing_set[ready] = nil
                        end
                    end
                end
            end
            for willing, _ in pairs(willing_set) do
                willing:close()
            end
            willing_set = {}
        end, self.name)
    end,

    stop = function(self)
        self.stop_sender:send(0)
    end,

    discovery_subscribe = function(self, usn, discovery)
        for scheme, value in pairs(usn) do
            local uri = table.concat({scheme, value}, ":")
            local list = self.discovery_subscription[uri]
            if not list then
                list = WeakValues()
                self.discovery_subscription[uri] = list
            end
            table.insert(list, discovery)
        end
    end,

    discovery_search = function(self, address, port, st, mx)
        local message = {
            table.concat({"M-SEARCH", "*", self.PROTOCOL}, " "),
            table.concat({"HOST", table.concat({address, port}, ":")}, ": "),
            table.concat({"MAN" , '"ssdp:discover"'}, ": "),
            table.concat({"ST"  , tostring(st)}, ": "),
        }
        if mx then
            table.insert(message, table.concat({"MX", mx}, ": "))
            table.insert(message, table.concat({"CPFN.UPNP.ORG", self.name}, ": "))
        end
        table.insert(message, self.EOL)
        self.discovery_socket:sendto(table.concat(message, self.EOL), address, port)
    end,

    discovery_search_multicast = function(self, st, mx)
        self:discovery_search(self.SSDP_MULTICAST_ADDRESS, self.SSDP_MULTICAST_PORT, st, mx or 1)
    end,

    discovery_search_unicast = function(self, st, address, port)
        self:discovery_search(address, port, st)
    end,

    eventing_subscribe = function(self, location, url, device, service, statevar_list, eventing)
        statevar_list = statevar_list or {""}
        local statevar = table.concat(statevar_list, ",")
        if "/" == url:sub(1, 1) then
            -- qualify relative url with location prefix
            url = location:match("(http://[%a%d-%.:]+)/.*") .. url
        end
        local prefix = table.concat({device, service}, "/")
        local callback = "http://" .. self.address .. ":" .. self.port .. "/" .. table.concat({prefix, statevar}, "/")
        local request_header = {
            "CALLBACK: <" .. callback .. ">",
            "NT: upnp:event",
        }
        if 0 < #statevar then
            table.insert(request_header, table.concat({"STATEVAR", statevar}, ": "))
        end
        local response, response_error = http:transact(url, "SUBSCRIBE", self.read_timeout, request_header)
        if response then
            local action, header = table.unpack(response)
            if http.OK ~= action[2] then
                log.error(self.name, "event", "catch", url, callback, action[3])
            else
                local set = self.eventing_subscription[prefix]
                if not set then
                    set = {}
                    self.eventing_subscription[prefix] = set
                end
                for _, name in ipairs(statevar_list) do
                    local list = set[name]
                    if not list then
                        list = {}
                        set[name] = list
                    end
                    table.insert(list, eventing)
                end
            end
        else
            log.error(self.name, "event", "catch", url, callback)
        end
    end,
})
