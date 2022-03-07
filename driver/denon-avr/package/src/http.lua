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

    -- read HTTP message response, header and body
    -- header field keys are lowercased and assumed to be unique (last wins)
    message = function(self, reader)
        return pcall(function()
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

    -- send an HTTP request to url for method with header
    -- return HTTP response if successful; otherwise, nil and the error
    transact = function(self, url, method, read_timeout, header)
        -- parse url
        local address, port, path = url:gmatch("http://([%a%d-%.]+):?(%d*)(/.*)")()
        if not (address and port and path) then
            log.error("http", method, "malformed", url)
            return nil, url
        end
        if 0 == #port then
            port = "80"
        end

        -- compose action
        local action = table.concat({method, path, self.PROTOCOL}, " ")

        -- managing a persistent connection lifecycle is not worth the effort
        -- instead, we always close the connection after receiving the response.

        -- connect
        local socket, connect_error = cosock.socket.connect(address, port)
        if connect_error then
            log.error("http", action, connect_error)
            return nil, connect_error
        end

        -- compose request
        local request = {
            action,
            table.concat({"HOST", table.concat({address, port}, ":")}, ": "),
            "CONNECTION: close",
        }
        if header then
            for _, field in ipairs(header) do
                table.insert(request, field)
            end
        end
        table.insert(request, self.EOL)

        -- send request
        local _, send_error = socket:send(table.concat(request, self.EOL))
        if send_error then
            log.error("http", action, send_error)
            socket:close()
            return nil, send_error
        end

        -- read response
        local ok, response = self:message(self:reader(socket, read_timeout))

        socket:close()

        if ok and response then
            return response
        end

        log.error("http", action, response)
        return nil, response
    end,

    get = function(self, url, read_timeout)
        return self:transact(url, "GET", read_timeout)
    end,
}
