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
    response_header = function(self, reader)
        local response = split(reader:read_line(), "%s+", 3)
        local header = {}
        while true do
            local line = reader:read_line()
            if 0 == #line then break end
            local nv = split(line, "%s*:%s*", 2)
            if 1 < #nv then
                header[nv[1]:lower()] = nv[2]
            end
        end
        return response, header
    end,

    -- read HTTP message response line, header and body
    message = function(self, reader)
        return pcall(function()
            local response, header = self:response_header(reader)
            if not header then
                return {response}
            end
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
                    return {response, header, table.concat(chunk)}
                end
            else
                local length = header["content-length"]
                if length then
                    length = tonumber(length)
                    if 0 < length then
                        return {response, header, reader:read_exactly(tonumber(length))}
                    end
                end
            end
            return {response, header}
        end)
    end,

    reader = function(_, socket, read_timeout)
        socket:settimeout(0)    -- when anything ready, receive something
        return Reader(function()
            local _, _, receive_error = cosock.socket.select({socket}, {}, read_timeout)
            if receive_error then
                error(receive_error, 0)     -- expect "timeout", below
            end
            return socket:receive(2048)
        end)
    end,

    transact = function(self, method, url, read_timeout, header)
        header = header or {}

        local address, port, path = url:gmatch("http://([%a%d-%.]+):(%d+)(/.*)")()
        if not (address and port and path) then
            log.warn("http", method, "malformed", url)
            return nil, url
        end

        local socket, connect_error = cosock.socket.connect(address, port)
        if connect_error then
            log.warn("http", method, "connect", connect_error, address, port)
            return nil, connect_error
        end

        local request = table.concat({
            table.concat({method, path, self.PROTOCOL}, " "),
            "HOST: " .. address .. ":" .. port,
            "CONNECTION: close",
            table.concat(header, self.EOL),
            self.EOL,
        }, self.EOL)
        local _, send_error = socket:send(request)
        if send_error then
            log.warn("http", method, "send", send_error, request)
            socket:close()
            return nil, send_error
        end

        local ok, message = self:message(self:reader(socket, read_timeout))

        socket:close()

        if ok and message then
            return message
        end

        log.warn("http", method, message)
        return nil, message
    end,

    get = function(self, url, read_timeout)
        return self:transact('GET', url, read_timeout)
    end,
}
