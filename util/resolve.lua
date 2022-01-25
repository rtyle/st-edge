local cosock = require "cosock"

-- mDNS
local ADDRESS = "224.0.0.251"
local PORT = 5353

-- resolve host name using mDNS. resolution is called with each address
return function(name, resolution)
    local labels = {}
    for label in string.gmatch(name, "[%a%d-]+") do
        table.insert(labels, string.pack("> s1", label))
    end
    labels = table.concat(labels)

    local transaction_id    = 0
    local type              = 1 -- Type: A (Host Address0)
    local class             = 1 -- Class: IN
    local question = table.concat({
        string.pack("> I2 I2 I2 I2 I2 I2 z I2 I2",
            transaction_id,
            0,              -- Flags
            1,              -- Questions
            0,              -- Answer RRs
            0,              -- Authority RRs
            0,              -- Additional RRs
            labels,
            type,
            class
        ),
    })

    local answer_len = 12 + (labels:len() + 1) + 14

    local resolver = cosock.socket.udp()

    -- ask question, expect unicast response to our ephemeral port
    resolver:sendto(question, ADDRESS, PORT)

    -- after a short wait, receive all answers and dispatch any resolution
    cosock.socket.sleep(0.1)
    while cosock.socket.select({resolver}, {}, 0.001) do
        local answer = resolver:receive(2048)

        if answer_len <= answer:len() then
            local
                _transaction_id,
                flags,
                questions,
                answers,
                authorities,
                _,              -- additional (ignore)
                _labels,
                _type,
                _class,
                _,              -- TTL (ignore)
                length,
                a, b, c, d
            = string.unpack("> I2 I2 I2 I2 I2 I2 z I2 I2 I4 I2 BBBB", answer)
            if true
                and transaction_id  == _transaction_id
                and 0x8400          == flags
                and 0               == questions
                and 1               == answers
                and 0               == authorities
                and labels          == _labels
                and type            == _type
                and class           == _class & ~0x8000 -- ignore Cache flush: True
                and 4               == length
            then
                local address = table.concat({a, b, c, d}, ".")
                resolution(address)
            end
        end
    end

    resolver:close()
end

