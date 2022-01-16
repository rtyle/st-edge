local cosock        = require "cosock"
local json          = require "dkjson"
local log           = require "log"

local Lockbox       = require "lockbox"
Lockbox.ALLOW_INSECURE = true   -- for MD5
local Array         = require "lockbox.util.array"
local Stream        = require "lockbox.util.stream"
local MD5           = require "lockbox.digest.md5"
local ECBMode       = require "lockbox.cipher.mode.ecb"
local ZeroPadding   = require "lockbox.padding.zero"
local AES128Cipher  = require "lockbox.cipher.aes128"

local Emitter       = require "util.emitter"
local Reader        = require "util.reader"
local resolve       = require "util.resolve"

local socket        = cosock.socket    -- layer over require("socket")

local function super(class)
    return getmetatable(class).__index
end

local function supers(class)
    return coroutine.wrap(function()
        for _, _super in ipairs(super(class)()) do
            coroutine.yield(_super)
        end
    end)
end

local function starts_with(whole, part)
    return part == whole:sub(1, #part)
end

local function json_decode(encoded)
    return coroutine.wrap(function()
        local begin = 1
        while (begin <= #encoded) do
            local decoded, _end, _error = json.decode(encoded, begin)
            if _error then
                log.warn("json.decode", encoded:sub(begin), "error", _error)
                _end = #encoded + 1
            else
                if "array" == getmetatable(decoded).__jsontype then
                    for _, object in ipairs(decoded) do
                        coroutine.yield(object)
                    end
                else -- "object"
                    coroutine.yield(decoded)
                end
            end
            begin = _end
        end
    end)
end

local M = {

    hash_password = function(data)
        -- Return a hash of data for turning a password into a key.
        return Array.toString(MD5().update(Stream.fromArray(Array.fromString(data))).finish().asBytes())
    end,

    -- Composer of messages.
    Composer = {
        -- message keys
        APP_CONTEXT_ID  = "AppContextId",   -- echoed in reply
        ID              = "ID",             -- echoed in reply
        PROPERTY_LIST   = "PropertyList",
        SCENE_LIST      = "SceneList",
        SERVICE         = "Service",
        SID             = "SID",            -- json_integer, 0-99
        ZID             = "ZID",            -- json_integer, 0-99
        ZONE_LIST       = "ZoneList",

        -- PROPERTY_LIST keys
        NAME            = "Name",           -- json_string, 1-20 characters

        ---- SCENE PROPERTY_LIST keys
        DAY_BITS        = "DayBits",        -- json_integer, DAY_BITS values
        DELTA           = "Delta",          -- json_integer, minutes before/after TRIGGER_TIME
        FREQUENCY       = "Frequency",      -- json_integer, FREQUENCY values
        SKIP            = "Skip",           -- json_boolean, True to skip next trigger
        TRIGGER_TIME    = "TriggerTime",    -- json_integer, time_t
        TRIGGER_TYPE    = "TriggerType",    -- json_integer, TRIGGER_TYPE values

        -- SCENE PROPERTY_LIST, DAY_BITS values
        SUNDAY          = 0,
        MONDAY          = 1,
        TUESDAY         = 2,
        WEDNESDAY       = 3,
        THURSDAY        = 4,
        FRIDAY          = 5,
        SATURDAY        = 6,

        -- SCENE PROPERTY_LIST, FREQUENCY values
        NONE            = 0,
        ONCE            = 1,
        WEEKLY          = 2,

        -- SCENE PROPERTY_LIST, TRIGGER_TYPE values
        REGULAR_TIME    = 0,
        SUNRISE         = 1,
        SUNSET          = 2,

        -- SCENE PROPERTY_LIST, ZONE_LIST array, item keys (always with ZID)
        LEVEL           = "Lvl",            -- json_integer, 1-100 (POWER_LEVEL)
        RR              = "RR",             -- json_integer, 1-100 (RAMP_RATE)
        ST              = "St",             -- json_boolean, True/False (POWER state)

        -- ZONE PROPERTY_LIST keys
        DEVICE_TYPE     = "DeviceType",     -- json_string, DIMMER/, reported only
        POWER           = "Power",          -- json_boolean, True/False
        POWER_LEVEL     = "PowerLevel",     -- json_integer, 1-100
        RAMP_RATE       = "RampRate",       -- json_integer, 1-100

        -- ZONE PROPERTY_LIST, DEVICE_TYPE values
        DIMMER          = "Dimmer",
        SWITCH          = "Switch",

        -- SERVICE values
        CREATE_SCENE                = "CreateScene",
        DELETE_SCENE                = "DeleteScene",
        DELETE_ZONE                 = "DeleteZone",
        LIST_SCENES                 = "ListScenes",
        LIST_ZONES                  = "ListZones",
        REPORT_SCENE_PROPERTIES     = "ReportSceneProperties",
        REPORT_SYSTEM_PROPERTIES    = "ReportSystemProperties",
        REPORT_ZONE_PROPERTIES      = "ReportZoneProperties",
        RUN_SCENE                   = "RunScene",
        SET_SCENE_PROPERTIES        = "SetSceneProperties",
        SET_SYSTEM_PROPERTIES       = "SetSystemProperties",
        SET_ZONE_PROPERTIES         = "SetZoneProperties",
        TRIGGER_RAMP_COMMAND        = "TriggerRampCommand",
        TRIGGER_RAMP_ALL_COMMAND    = "TriggerRampAllCommand",

        -- SET_SYSTEM_PROPERTIES PROPERTY_LIST keys
        ADD_A_LIGHT             = "AddALight",          -- json_boolean, True to enable
        TIME_ZONE               = "TimeZone",           -- json_integer, seconds offset from GMT
        EFFECTIVE_TIME_ZONE     = "EffectiveTimeZone",  -- json_integer, seconds offset from GMT including DST
        DAYLIGHT_SAVING_TIME    = "DaylightSavingTime", -- json_boolean, True for DST
        LOCATION_debug          = "Locationdebug",      -- json_string, LOCATION description
        LOCATION                = "Location",           -- json_object, LAT and LONG
        CONFIGURED              = "Configured",         -- json_boolean, True to say LCM configured
        LAT                     = "Lat",                -- json_object, latitude in DEG, MIN, SEC
        LONG                    = "Long",               -- json_object longitude in DEG, MIN, SEC
        DEG                     = "Deg",                -- json_integer, degrees
        MIN                     = "Min",                -- json_integer, minutes
        SEC                     = "Sec",                -- json_integer, seconds

        -- SET_SYSTEM_PROPERTIES PROPERTY_LIST security keys
        KEYS = "Keys",

        _init = function(class, self)
            self.Composer = class
        end,

        wrap = function(self, id, message)
            -- Wrap a composed message, with id, in a frame.
            message[self.ID] = id
            return json.encode(message) .. "\x00"
        end,

        compose_delete_scene = function(self, sid)
            -- Compose a DELETE_SCENE message.
            return {[self.SERVICE] = self.DELETE_SCENE, [self.SID] = sid}
        end,

        compose_delete_zone = function(self, zid)
            -- Compose a DELETE_ZONE message.
            return {[self.SERVICE] = self.DELETE_ZONE, [self.ZID] = zid}
        end,

        compose_list_scenes = function(self)
            -- Compose a LIST_SCENES message.
            return {[self.SERVICE] = self.LIST_SCENES}
        end,

        compose_list_zones = function(self)
            -- Compose a LIST_ZONES message.
            return {[self.SERVICE] = self.LIST_ZONES}
        end,

        compose_report_scene_properties = function(self, sid)
            -- Compose a REPORT_SCENE_PROPERTIES message.
            return {[self.SERVICE] = self.REPORT_SCENE_PROPERTIES, [self.SID] = sid}
        end,

        compose_report_system_properties = function(self)
            -- Compose a REPORT_SYSTEM_PROPERTIES message.
            return {[self.SERVICE] = self.REPORT_SYSTEM_PROPERTIES}
        end,

        compose_report_zone_properties = function(self, zid)
            -- Compose a REPORT_ZONE_PROPERTIES message.
            return {[self.SERVICE] = self.REPORT_ZONE_PROPERTIES, [self.ZID] = zid}
        end,

        compose_set_system_properties = function(self, property_list)
            -- Compose a SET_SYSTEM_PROPERTIES message.
            return {
                [self.SERVICE] = self.SET_SYSTEM_PROPERTIES,
                [self.PROPERTY_LIST] = property_list
            }
        end,

        compose_set_zone_properties = function(self, zid, property_list)
            -- Compose a SET_ZONE_PROPERTIES message.
            return {
                [self.SERVICE] = self.SET_ZONE_PROPERTIES,
                [self.ZID] = zid,
                [self.PROPERTY_LIST] = property_list
            }
        end,

        _encrypt = function(key, data)
            return ECBMode.Cipher()
                .setKey(Array.fromString(key))
                .setBlockCipher(AES128Cipher)
                .setPadding(ZeroPadding)
                .init()
                .update(Stream.fromArray(Array.fromString(data))).finish()
                .asHex()
        end,

        compose_keys = function(self, _old, new)
            -- Compose a message to change key from old to new.
            local old = _old or Array.toString(Array.fromHex("d41d8cd98f00b204e9800998ecf8427e"))
            return {
                [self.SERVICE] = self.SET_SYSTEM_PROPERTIES,
                [self.PROPERTY_LIST] = {[self.KEYS] = self._encrypt(old, old) .. self._encrypt(old, new)}
            }
        end,
    },

    -- Sender of messages.
    Sender = {
        _init = function(class, self)
            self.Sender = class
            super(class):_init(self)
            self._send_id = 0 -- id of last send
            self._writer = nil
        end,

        connected = function(self)
            return nil ~= self._writer
        end,

        send = function(self, message)
            -- Send a composed message with the next ID.
            local writer = self._writer
            if not writer then
                log.warn("\t!", json.encode(message))
            else
                self._send_id = self._send_id + 1
                local frame = self:wrap(self._send_id, message)
                writer.write(frame)
                log.debug("\t<", frame)
            end
        end,
    },

    -- A Receiver's messages are handled by an abstract receive method.
    Receiver = {

        -- Status has status, error, code and text values derived from a message.
        Status = {
            -- status is STATUS (or STATUS_ERROR)
            -- error is true if status is not STATUS_SUCCESS,
            -- code is ERROR_CODE value (or 0)
            -- text is ERROR_TEXT value (or status)

            -- message keys
            ERROR_TEXT      = "ErrorText",
            ERROR_CODE      = "ErrorCode",
            STATUS          = "Status",

            -- STATUS values
            STATUS_SUCCESS  = "Success",
            STATUS_ERROR    = "Error",

            _init = function(class, self, message)
                self.Status = class
                self.status = message[self.STATUS] or self.STATUS_ERROR
                self.error  = self.STATUS_SUCCESS ~= self.status
                self.code   = tonumber(message[self.ERROR_CODE] or "0")
                self.text   = message[self.ERROR_TEXT] or self.status
            end,

            error_if = function(self)
                if self.error then
                    error("RFLC error: " .. self.text)
                end
            end,
        },

        _init = function(class, self)
            self.Receiver = class
            super(class):_init(self)
            self._reader = nil
        end,

        unwrap = function(self, frame)
            for message in json_decode(frame) do
                self:receive(message)
            end
        end,

        _frames = function(self)
            return function()
                return self._reader:read_until("\x00"):sub(1, -2)
            end
        end,

        session = function(self)
            for frame in self:_frames() do
                log.debug("\t\t>", frame)
                self:unwrap(frame)
            end
        end,
    },

    -- ReceiverEmitter is a Receiver and Emitter that emits received messages.
    ReceiverEmitter = {

        -- events emitted with message
        EVENT_BROADCAST                 = "ID:0",
        EVENT_DELETE_ZONE               = "Service:DeleteZone",
        EVENT_LIST_SCENES               = "Service:ListScenes",
        EVENT_LIST_ZONES                = "Service:ListZones",
        EVENT_PING                      = "Service:ping",
        EVENT_REPORT_SCENE_PROPERTIES   = "Service:ReportSceneProperties",
        EVENT_REPORT_SYSTEM_PROPERTIES  = "Service:ReportSystemProperties",
        EVENT_REPORT_ZONE_PROPERTIES    = "Service:ReportZoneProperties",
        EVENT_RUN_SCENE                 = "Service:RunScene",
        EVENT_SET_SCENE_PROPERTIES      = "Service:SetSceneProperties",
        EVENT_SET_SYSTEM_PROPERTIES     = "Service:SetSystemProperties",
        EVENT_SET_ZONE_PROPERTIES       = "Service:SetZoneProperties",
        EVENT_SCENE_CREATED             = "Service:SceneCreated",
        EVENT_SCENE_DELETED             = "Service:SceneDeleted",
        EVENT_SCENE_PROPERTIES_CHANGED  = "Service:ScenePropertiesChanged",
        EVENT_SYSTEM_PROPERTIES_CHANGED = "Service:SystemPropertiesChanged",
        EVENT_TRIGGER_RAMP_COMMAND      = "Service:TriggerRampCommand",
        EVENT_TRIGGER_RAMP_ALL_COMMAND  = "Service:TriggerRampAllCommand",
        EVENT_ZONE_ADDED                = "Service:ZoneAdded",
        EVENT_ZONE_DELETED              = "Service:ZoneDeleted",
        EVENT_ZONE_PROPERTIES_CHANGED   = "Service:ZonePropertiesChanged",

        _init = function(class, self)
            self.ReceiverEmitter = class
            for _super in supers(class) do
                _super:_init(self)
            end
            self._emit_id = 1   -- id of next emit
        end,

        receive = function(self, message)
            local id = message[self.ID]
            if id then
                if id ~= 0 then
                    -- emit what we received (nothing) until caught up.
                    -- such will be acknowledged but not forwarded by Once.
                    while self._emit_id < id do
                        self:emit(self.ID .. ":" .. self._emit_id, self.Once.EVENT_NIL)
                        self._emit_id = self._emit_id + 1
                    end
                end
                self:emit(self.ID .. ":" .. id, self, message)
            end
            local service = message[self.SERVICE]
            if service then
                self:emit(self.SERVICE .. ":" .. service, self, message)
                local zid = message[self.ZID]
                if zid ~= nil then
                    self:emit(self.SERVICE .. ":" .. service .. ":" .. zid, self, message)
                end
            end
        end,

        converse = function(self, command, respond)
            self:once(self.ID .. ":" .. self._send_id + 1, respond)
            self:send(command)
        end,
    },

    -- An Authenticator overrides Receiver functionality until authenticated.
    Authenticator = {
        -- events emitted
        EVENT_IDENTIFIED        = "identified",
        EVENT_AUTHENTICATED     = "authenticated",

        -- Security message prefixes
        SECURITY_MAC            = '{"MAC":',
        SECURITY_HELLO          = "Hello V1 ",
        SECURITY_HELLO_INVALID  = "[INVALID]",
        SECURITY_HELLO_OK       = "[OK]",
        SECURITY_SETKEY         = "[SETKEY]",

        -- SECURITY_MAC and SECURITY_SETKEY key
        MAC = "MAC",

        _init = function(class, self, authentication)
            self.Authenticator = class
            super(class):_init(self)
            self._authentication = authentication
        end,

        _identified = function(self, hub_id)
            self._hub_id = hub_id:lower()
            self:emit(self.EVENT_IDENTIFIED, self, self._hub_id)
        end,

        hub_id = function(self)
            return self._hub_id
        end,

        _authenticated = function(self)
            -- restore Receiver functionality
            self.unwrap = self.Receiver.unwrap
            self:emit(self.EVENT_AUTHENTICATED, self)
        end,

        online = function(self)
            return self:connected() and self.unwrap == self.Receiver.unwrap
        end,

        _get_authentication = function(self)
            if self._authentication then
                local authentication = self._authentication[self._hub_id]
                if nil ~= authentication then
                    return authentication
                end
            end
            self.Continue("noauth", self:name(), self._hub_id)
        end,

        _send_challenge_response = function(self, authentication, challenge)
            local response = self._encrypt(authentication, challenge)
            self._writer.write(response)
            log.debug("\t<", response)
        end,

        _receive_security_setkey = function(self)
            -- } terminated json encoding
            local frame = self._reader:read_until("}")
            log.debug("\t\t>", frame)
            local message = json_decode(frame)()
            self:_identified(message[self.MAC])
            self:converse(self:compose_keys(nil, self:_get_authentication()), function(_, authenticated)
                self.Status(authenticated):error_if()
                self:_authenticated()
            end)
        end,

        _receive_security_hello = function(self)
            -- space terminated challenge phrase
            local challenge = self._reader:read_until(" "):sub(1, -2)
            log.debug("\t\t>\t", challenge)
            -- 12 byte MAC address
            local hub_id = self._reader:read_exactly(12)
            log.debug("\t\t>\t", hub_id)
            self:_identified(hub_id)
            self:_send_challenge_response(self:_get_authentication(), Array.toString(Array.fromHex(challenge)))
        end,

        _receive_security_hello_ok = function(self)
            self:_authenticated()
        end,

        _receive_security_hello_invalid = function(self)
            self.Continue("unauth", self:name(), self._hub_id)
        end,

        _receive_security_mac = function(self, message)
            self:_identified(message[self.MAC])
            self:_authenticated()
        end,

        _unwrap_security_mac = function(self, frame)
            local decoder = json_decode(frame)
            local message = decoder()
            if message then
                self:_receive_security_mac(message)
                -- decoder may have more
                for _message in decoder do
                    self:receive(_message)
                end
            end
        end,

        unwrap = function(self, frame)
            if starts_with(frame, self.SECURITY_MAC) then
                self:_unwrap_security_mac(frame)
            elseif starts_with(frame, self.SECURITY_SETKEY) then
                self:_receive_security_setkey()
            elseif starts_with(frame, self.SECURITY_HELLO) then
                self:_receive_security_hello()
            elseif starts_with(frame, self.SECURITY_HELLO_OK) then
                self:_receive_security_hello_ok()
            elseif starts_with(frame, self.SECURITY_HELLO_INVALID) then
                self:_receive_security_hello_invalid()
            else
                self.Receiver.unwrap(self, frame)
            end
        end,

        session = function(self)
            -- (re)override Receiver functionality until authenticated
            self.unwrap = self.Authenticator.unwrap
            self.Receiver.session(self)
        end,
    },

    -- A Hub is an Authenticator that loops over connections/sessions.
    Hub = {

        -- for loop control, from same thread
        Break       = {},
        Continue    = {},

        -- events emitted
        EVENT_DISCONNECTED  = "disconnected",
        EVENT_STOPPED       = "stopped",

        -- default arguments
        HOST                = "LCM1.local",
        PORT                = 2112,
        LOOP_BACKOFF_CAP    = 8,
        READ_TIMEOUT        = 20.0,  -- expect ping every 5 seconds

        _init = function(class, self, host, port, authentication)
            self.Connector = class
            super(class):_init(self, authentication)
            self._host = host or self.HOST
            self._port = port or self.PORT
        end,

        host = function(self)
            return self._host
        end,

        port = function(self)
            return self._port
        end,

        name = function(self)
            return self._host .. ":" .. self._port
        end,

        loop = function(self, backoff_cap, read_timeout, break_on_connect_error)
            -- loop continues to (re)connect and run sessions.
            -- a Continue object constructed in this context causes a reconnect.
            -- a Break object constructed in this context causes the loop to stop.
            -- the loop also stops on a connect_error if told to (break_on_connect_error).
            backoff_cap = backoff_cap or self.LOOP_BACKOFF_CAP
            read_timeout = read_timeout or self.READ_TIMEOUT
            local stop_error
            local backoff = 0
            while true do
                local client = socket.tcp()
                local connected, connect_error = client:connect(self._host, self._port)
                if connected then
                    client:settimeout(0)
                    self._reader = Reader(function()
                        local _, _, receive_error = socket.select({client}, {}, read_timeout)
                        if receive_error then
                            error(receive_error, 0)     -- expect "timeout", below
                        end
                        return client:receive(2048)
                    end)
                    self._writer = {
                        write = function(data)
                            local length, send_error = client:send(data)
                            if send_error then
                                error(send_error, 0)    -- expect "closed", below
                            end
                            return length
                        end
                    }
                    local _, session_error = pcall(function() return self:session() end)
                    client:close()
                    self._reader = nil
                    self._writer = nil
                    log.warn(self.EVENT_DISCONNECTED)
                    self:emit(self.EVENT_DISCONNECTED, self)
                    if "timeout" == session_error then
                        backoff = 0
                        log.warn(session_error)
                    elseif "closed" == session_error then
                        backoff = 0
                        log.warn(session_error)
                    elseif self.Break == getmetatable(session_error) then
                        log.debug(table.unpack(session_error))
                        break
                    elseif self.Continue == getmetatable(session_error) then
                        log.debug(table.unpack(session_error))
                        -- continue
                    else
                        stop_error = session_error
                        break
                    end
                else
                    client:close()
                    log.warn(connect_error)
                    if break_on_connect_error then
                        break
                    end
                end
                -- reconnect after capped exponential backoff
                socket.sleep(1 << math.min(backoff, backoff_cap))
                backoff = backoff + 1
            end
            log.debug(self.EVENT_STOPPED)
            self:emit(self.EVENT_STOPPED, self)
            if stop_error then
                log.error(stop_error)
                error(stop_error)
            end
        end,
    },

    -- Manage an inventory of identified Hubs.
    Inventory = {

        -- events emitted
        EVENT_ADD       = "add",
        EVENT_REMOVE    = "remove",

        -- default arguments
        DISCOVER_BACKOFF_CAP = 8,

        _init = function(class, self, authentication, Hub)
            super(class):_init(self)
            self._authentication = authentication
            self.Hub = Hub

            -- inventory
            self.hub = {}       -- by hub:hub_id()
            self._running = {}  -- by hub:name()

            self._subscription = {
                [Hub.EVENT_IDENTIFIED]      = function(hub, hub_id)
                    self:_add(hub, hub_id)
                end,
                [Hub.EVENT_STOPPED]         = function(hub)
                    self:_remove(hub)
                end,
            }
        end,

        _remove = function(self, hub)
            for event, handler in pairs(self._subscription) do
                hub:off(event, handler)
            end
            local name = hub:name()
            self._running[name] = nil
            if not hub._dup then
                local hub_id = hub:hub_id()
                self.hub[hub_id] = nil
                log.debug(self.EVENT_REMOVE, name, hub_id)
                self:emit(self.EVENT_REMOVE, hub, hub_id)
                if hub._rediscover then
                    self._discover_sender:send(0)
                end
            end
        end,

        _add = function(self, new_hub, new_hub_id)
            local old_hub = self.hub[new_hub_id]
            if new_hub ~= old_hub then
                if old_hub then
                    new_hub._dup = true
                    self.Hub.Break("dup", new_hub:name(), new_hub_id)
                else
                    self.hub[new_hub_id] = new_hub
                    log.debug(self.EVENT_ADD, new_hub:name(), new_hub_id)
                    self:emit(self.EVENT_ADD, new_hub, new_hub_id)
                end
            end
        end,

        ask = function(self, hub, loop_backoff_cap, read_timeout, rediscover)
            local name = hub:name()
            log.debug("ask", name)
            if self._running[name] then
                log.debug("dup", name)
            else
                self._running[name] = true
                for event, handler in pairs(self._subscription) do
                    hub:on(event, handler)
                end
                cosock.spawn(function()
                    hub:loop(loop_backoff_cap, read_timeout, rediscover)
                end, "lc7001.Hub " .. name)
            end
        end,

        discover = function(self, backoff_cap, loop_backoff_cap, read_timeout)
            backoff_cap = backoff_cap or self.DISCOVER_BACKOFF_CAP
            if self._discover_sender then
                self._discover_sender:send(0)
            else
                local sender, receiver = cosock.channel.new()
                self._discover_sender = sender
                receiver:settimeout(0)
                cosock.spawn(function()
                    local backoff = 0
                    while true do
                        resolve(self.Hub.HOST, function(host)
                            local hub = self.Hub(host, nil, self._authentication)
                            hub._rediscover = true
                            self:ask(hub, loop_backoff_cap, read_timeout, true)
                        end)
                        -- rediscover after capped exponential backoff
                        -- or our receiver hears from our sender.
                        if socket.select({receiver}, {}, 1 << math.min(backoff, backoff_cap)) then
                            log.debug("rediscover")
                            backoff = receiver:receive()
                        else
                            backoff = backoff + 1
                        end
                    end
                end, "lc7001.Inventory.discover")
            end
        end,
    },
}

local function new(class, ...)
    local self = setmetatable({}, class)
    class:_init(self, ...)
    return self
end

local function join(_supers)
    return function(class, key)
        if nil == key then
            return _supers
        end
        for _, _super in ipairs(_supers) do
            local value = _super[key]
            if nil ~= value then
                class[key] = value
                return value
            end
        end
    end
end

M.Composer.__index = M.Composer
setmetatable(M.Composer, {
    __call = new
})

M.Sender.__index = M.Sender
setmetatable(M.Sender, {
    __index = M.Composer,
    __call = new
})

M.Receiver.__index = M.Receiver
setmetatable(M.Receiver, {
    __index = M.Sender,
    __call = new
})

M.Receiver.Status.__index = M.Receiver.Status
setmetatable(M.Receiver.Status, {
    __call = new
})

M.ReceiverEmitter.__index = M.ReceiverEmitter
setmetatable(M.ReceiverEmitter, {
    __index = join{M.Receiver, Emitter},
    __call = new
})

M.Authenticator.__index = M.Authenticator
setmetatable(M.Authenticator, {
    __index = M.ReceiverEmitter,
    __call = new
})

M.Hub.__index = M.Hub
setmetatable(M.Hub, {
    __index = M.Authenticator,
    __call = new
})

local function _error(class, ...)
    error(setmetatable({...}, class))
end

M.Hub.Break.__index = M.Hub.Break
setmetatable(M.Hub.Break, {
    __call = _error
})

M.Hub.Continue.__index = M.Hub.Continue
setmetatable(M.Hub.Continue, {
    __call = _error
})

M.Inventory.__index = M.Inventory
setmetatable(M.Inventory, {
    __index = Emitter,
    __call = function(class, ...)
	    return new(class, ..., M.Hub)
    end
})

return M