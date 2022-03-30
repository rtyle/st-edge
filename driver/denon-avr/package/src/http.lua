local cosock    = require "cosock"
local log       = require "log"

local Reader    = require "reader"
local split     = require "split"

local LOG = "http"

return {
    -- expected HTTP protocol version
    PROTOCOL_1_0    = "HTTP/1.0",
    PROTOCOL_1_1    = "HTTP/1.1",
    PROTOCOL        = "HTTP/1.1",

    -- expected HTTP response status codes
    OK        = "200",

    -- expected HTTP end of line terminators
    EOL       = "\r\n",

    -- read HTTP message action, header and body
    -- header field keys are lowercased and assumed to be unique (last wins)
    message = function(self, reader)
        local action = split(reader:read_line(), "%s+", 3)

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
                return {action, header, table.concat(chunk)}
            end
        else
            local length = header["content-length"]
            if length then
                length = tonumber(length)
                if 0 < length then
                    return {action, header, reader:read_exactly(tonumber(length))}
                end
            elseif self.PROTOCOL_1_0 == action[1] then
                return {action, header, reader:read_all()}
            end
        end
        return {action, header}
    end,

    reader = function(_, socket, read_timeout)
        socket:settimeout(0)    -- when anything ready, receive something
        return Reader(function()
            local _, _, select_error = cosock.socket.select({socket}, {}, read_timeout)
            if select_error then
                error(select_error, 0)     -- expect "timeout", below
            end
            return socket:receive(2048)
        end)
    end,

    url_parse = function(_, url)
        local address, port, path = url:gmatch("http://([%a%d-%.]+):?(%d*)(/.*)")()
        if not (address and port and path) then
            log.error(LOG, "malformed", url)
            return nil
        end
        if 0 == #port then
            port = "80"
        end
        return {address, port, path}
    end,

    -- send an HTTP request to url for method with header
    -- return HTTP response if successful; otherwise, nil and the error
    transact = function(self, url, method, read_timeout, header, body)
        local parsed_url = self:url_parse(url)
        if not parsed_url then
            return nil, url .. "\tunparsed"
        end
        local address, port, path = table.unpack(parsed_url)

        -- compose host, action
        local host = table.concat({address, port}, ":")
        local action = table.concat({method, path, self.PROTOCOL}, " ")

        -- managing a persistent connection lifecycle is not worth the effort
        -- instead, we always close the connection after receiving the response.

        -- connect
        local socket, connect_error = cosock.socket.connect(address, port)
        if connect_error then
            log.error(LOG, host, action, connect_error)
            return nil, connect_error
        end

        -- compose request
        local request = {
            action,
            "HOST: " .. host,
            "CONNECTION: keep-alive"
            -- "CONNECTION: close",
            -- even though we will close the connection,
            -- we don't want our peer to do so unless it lingers long enough
            -- for everything to be received by us (some don't).
            -- we will close once this is done and our peer will follow suit.
        }
        if header then
            for _, field in ipairs(header) do
                table.insert(request, field)
            end
        end
        if body then
            table.insert(request, "CONTENT-LENGTH: " .. #body)
            table.insert(request, "")
            table.insert(request, body)
        else
            table.insert(request, self.EOL)
        end

        -- send request
        local _, send_error = socket:send(table.concat(request, self.EOL))
        if send_error then
            log.error(LOG, host, action, send_error)
            socket:close()
            return nil, send_error
        end

        -- read response
        local ok, response = pcall(function()
            return self:message(self:reader(socket, read_timeout))
        end)

        socket:close()

        if ok and response then
            return response
        end

        log.error(LOG, host, action, response)
        return nil, response
    end,

    get = function(self, url, read_timeout)
        return self:transact(url, "GET", read_timeout)
    end,
}
