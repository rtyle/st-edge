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
        for _, pair in ipairs(split(encoded, "%s*::%s*", 0)) do
            local kv = split(pair, "%s*:%s*", 2)
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

local WeakValues = classify.single({
    __mode = "v",
    _init = function() end
})

-- construct (with log arguments) to affect UPnP thread loop processing
local Break = classify.error({})    -- break out
local Close = classify.error({})    -- close (what was ready is no longer willing or able)

return classify.single({
    -- http
    PROTOCOL    = http.PROTOCOL,
    EOL         = http.EOL,

    -- ssdp
    SSDP_MULTICAST_ADDRESS    = "239.255.255.250",
    SSDP_MULTICAST_PORT       = 1900,

    -- classes
    USN             = USN,

    _init = function(_, self, address, read_timeout, name)
        self.address = address
        read_timeout = read_timeout or 1
        name = name or "UPnP"
        self.name = name
        log.debug(name, "address", address)

        local willing_set = {}

        -- support UPnP:stop
        local stop_sender, stop_receiver = cosock.channel.new()
        self.stop_sender = stop_sender
        willing_set[stop_receiver] = function()
            stop_receiver:receive()
            Break()
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
                return {response, header, xml.decode(http:get(header.location, read_timeout)[3]).root}
            end)
            if not ok then
                log.warn(name, "discovery", peer_address, peer_port, message)
            else
                local _, header, description = table.unpack(message)
                header.usn = USN(header.usn)
                for scheme, path in pairs(header.usn) do
                    local scheme_set = self.discovery_subscription[scheme]
                    if scheme_set then
                        local path_list = scheme_set[path]
                        if path_list then
                            for _, discovery in ipairs(path_list) do
                                discovery(peer_address, peer_port, header, description)
                            end
                        end
                    end
                end
            end
        end

        -- support UPnP Eventing
        -- with a tcp listen socket and those accepted from it
        local listen_socket = cosock.socket.bind('*', 0)
        local _, port = listen_socket:getsockname()
        log.debug(name, "listen", port)
        self.port = port
        willing_set[listen_socket] = function()
            local accept_socket, accept_error = listen_socket:accept()
            if accept_error then
                Close(port)
            end
            local peer_address, peer_port = accept_socket:getpeername()
            log.debug(name, "accept", peer_address, peer_port)
            local reader = http:reader(accept_socket, self.read_timeout)
            willing_set[accept_socket] = function()
                local ok, message = http:message(reader)
                if not ok then
                    Close(peer_address, peer_port)
                end
                pcall(function()
                    local _, propertyset = next(xml.decode(message[3]).root)
                    for _, property in pairs(propertyset) do
                        for key, value in pairs(property) do
                            local x = 0
                        end
                    end
                end)
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
                    log.error(name, select_error)
                    break
                end
                while 0 < #ready_list do
                    local ready = table.remove(ready_list, 1)
                    local ok, able_error = pcall(function() willing_set[ready]() end)
                    if not ok then
                        local class_able_error = classify.class(able_error)
                        if Break == class_able_error then
                            log.debug(name, "break", table.unpack(able_error))
                            stop_receiver = nil -- break out of outer loop
                        else
                            if Close == class_able_error then
                                log.debug(name, "close", table.unpack(able_error))
                            else
                                log.debug(name, "close", able_error)
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
        end, name)
    end,

    stop = function(self)
        self.stop_sender:send(0)
    end,

    discovery_subscribe = function(self, usn, discovery)
        for scheme, path in pairs(usn) do
            local scheme_set = self.discovery_subscription[scheme]
            if not scheme_set then
                scheme_set = {}
                self.discovery_subscription[scheme] = scheme_set
            end
            local path_list = scheme_set[path]
            if not path_list then
                path_list = WeakValues()
                scheme_set[path] = path_list
            end
            table.insert(path_list, discovery)
        end
    end,

    _discovery_search = function(self, address, port, st, mx, name)
        local header = {
            table.concat({"HOST", table.concat({address, port}, ":")}, ": "),
            table.concat({"MAN" , '"ssdp:discover"'}, ": "),
            table.concat({"ST"  , tostring(st)}, ": "),
        }
        if mx then
            table.insert(header, table.concat({"MX", mx}, ": "))
        end
        if name then
            table.insert(header, table.concat({"CPFN.UPNP.ORG", name}, ": "))
        end
        header = table.concat(header, self.EOL)
        self.discovery_socket:sendto(table.concat({
            table.concat({"M-SEARCH", "*", self.PROTOCOL}, " "),
            header,
            self.EOL,
        }, self.EOL), address, port)
    end,

    discovery_search_multicast = function(self, st, mx)
        self:_discovery_search(self.SSDP_MULTICAST_ADDRESS, self.SSDP_MULTICAST_PORT, st, mx or 1, self.name)
    end,

    discovery_search_unicast = function(self, st, address, port)
        self:_discovery_search(address, port, st)
    end,

    eventing_subscribe = function(self, location, url, device, service, statevar)
        if "/" == url:sub(1, 1) then
            url = location:match("(http://[%a%d-%.:]+)/.*") .. url
        end
        local header = {
            "CALLBACK: <http://"
                .. self.address
                .. ":"
                .. self.port
                .. "/"
                .. device
                .. "/"
                .. service
                .. ">",
            "NT: upnp:event",
        }
        if 0 < #statevar then
            table.insert(header, "STATEVAR: " .. table.concat(statevar, ","))
        end
        local ok, response = pcall(function()
            return http:transact('SUBSCRIBE', url, self.read_timeout, header)
        end)
        if ok then
            log.debug(self.name, "eventing", url)
        else
            log.error(self.name, "eventing", url)
        end
    end,
})