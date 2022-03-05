local cosock    = require "cosock"
local log       = require "log"

local Reader    = require "reader"
local split     = require "split"

return {
    -- expected HTTP protocol version
    PROTOCOL  = "HTTP/1.1",

    -- expected HTTP response status codes
    OK        = "200",

    -- expected HTTP end of line terminators
    EOL       = "\r\n",

    -- read HTTP response line and header field lines
    -- result maps each (unique, lower cased) named header field to its last value
    header = function(self, reader)
        local status_code = reader:read_line():gmatch(self.PROTOCOL .. "%s+(%d+)")()
        if self.OK == status_code then
            local map = {}
            while true do
                local line = reader:read_line()
                if 0 == #line then break end
                local nv = split(line, "%s*:%s*", 2)
                if 1 < #nv then
                    map[nv[1]:lower()] = nv[2]
                end
            end
            return map
        end
    end,

    receive = function(self, reader)
        return pcall(function()
            local header = self:header(reader)
            if header then
                local message = {header = header}
                local encoding = header["transfer-encoding"]
                if encoding then
                    if "chunked" == encoding then
                        local chunk = {}
                        while true do
                            local length = tonumber(reader:read_line(), 16)
                            if not length then
                                break
                            end
                            if 0 < length then
                                table.insert(chunk, reader:read_exactly(length))
                            end
                            reader:read_exactly(#self.EOL)
                            if 0 == length then
                                break
                            end
                        end
                        message.body = table.concat(chunk)
                    end
                else
                    local length = header["content-length"]
                    if length then
                        message.body = reader:read_exactly(tonumber(length))
                    end
                end
                return message
            end
        end)
    end,

    get = function(self, url, timeout)
        local address, port, path = url:gmatch("http://([%a%d-%.]+):(%d+)(/.*)")()
        if not (address and port and path) then
            log.warn("malformed", url)
            return nil, url
        end

        local socket, connect_error = cosock.socket.connect(address, port)
        if connect_error then
            log.warn("connect", connect_error, address, port)
            return nil, connect_error
        end

        local request = table.concat({
            'GET ' .. path .. ' ' .. self.PROTOCOL,
            'HOST: ' .. address .. ":" .. port,
            'CONNECTION: close',
            self.EOL,
        }, self.EOL)
        local _, send_error = socket:send(request)
        if send_error then
            log.warn("send", send_error, request)
            socket:close()
            return nil, send_error
        end

        socket:settimeout(0)    -- when anything ready, receive something
        local reader = Reader(function()
            local _, _, receive_error = cosock.socket.select({socket}, {}, timeout)
            if receive_error then
                error(receive_error, 0)     -- expect "timeout", below
            end
            return socket:receive(2048)
        end)

        local ok, response = self:receive(reader)

        socket:close()

        if ok and response then
            return response
        end

        log.warn("session", response)
        return nil, response
    end,

    get_xml_parsed_body = function(self, url, timeout)
        local response = self:get(url, timeout)
        if response then
            local body = response.body
            if body then
            end
        end
    end,
}