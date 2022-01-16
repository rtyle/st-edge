local cosock = require "cosock"

-- mDNS
local MULTIADDR = "224.0.0.251"
local PORT = 5353

-- resolve host name using mDNS. resolution is called with each address
return function(name, resolution)
    local labels = {}
    for label in string.gmatch(name, "[%a%d-]+") do
        table.insert(labels, string.char(#label))   -- length
        table.insert(labels, label)                 -- label
    end
    table.insert(labels, string.char(0))            -- end
    labels = table.concat(labels)

    local question = table.concat({
        string.char(
            0, 0,       -- Transaction ID
            0, 0,       -- Flags
            0, 1,       -- Questions
            0, 0,       -- Answer RRs
            0, 0,       -- Authority RRs
            0, 0        -- Additional RRs
        ),
        labels,
        string.char(
            0, 1,       -- Type: A (Host Address)
            0, 1        -- Class: IN
        )
    })

    local answer_prefix = table.concat({
        string.char(
            0, 0,       -- Transaction ID
            0x84, 0,    -- Flags: Standard query response, No error
            0, 0,       -- Questions
            0, 1,       -- Answer RRs
            0, 0,       -- Authority RRs
            0, 0        -- Additional RRs (ignore)
        ),
        labels,
        string.char(
            0, 1,       -- Type: A (Host Address)
            0, 1,       -- Class: IN, Cache flush: True (ignore)
            0, 0, 0, 0, -- Time to live (ignore)
            0, 4        -- Data length: 4
        )
        -- a, b, c, d   -- IPv4 address octets
    })

    local resolver = cosock.socket.udp()

    -- ask question, expect unicast response to our ephemeral port
    resolver:sendto(question, MULTIADDR, PORT)

    -- after a short wait, receive all answers and dispatch any resolution
    cosock.socket.sleep(0.1)
    while cosock.socket.select({resolver}, {}, 0.001) do
        local answer = resolver:receive(2048)
        if #answer_prefix + 4 <= answer:len() then
            local match = {answer:byte(1, #answer_prefix)}
            match[11] = 0                   -- ignore Additional RRs
            match[12] = 0                   -- ignore Additional RRs
            match[#answer_prefix - 7] = 0   -- ignore Cache flush
            match[#answer_prefix - 5] = 0   -- ignore TTL
            match[#answer_prefix - 4] = 0   -- ignore TTL
            match[#answer_prefix - 3] = 0   -- ignore TTL
            match[#answer_prefix - 2] = 0   -- ignore TTL
            if answer_prefix == string.char(table.unpack(match)) then
                local address = table.concat({answer:byte(#answer_prefix + 1, #answer_prefix + 4)}, ".")
                resolution(address)
            end
        end
    end

    resolver:close()
end
