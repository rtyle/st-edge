local xml2lua   = require "xml2lua"
local tree      = require "xmlhandler.tree"

return {
    decode = function(encoded)
        encoded = encoded or ""
        local decoded = tree:new()
        local parser = xml2lua.parser(decoded)
        parser:parse(encoded)
        return decoded
    end,

    encode = function(decoded, name)
        return xml2lua.toXml(decoded, name)
    end
}