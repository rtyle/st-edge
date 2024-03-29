-- vim: ts=4:sw=4:expandtab

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

local Emitter       = require "emitter"
local Reader        = require "reader"
local classify      = require "classify"
local resolve       = require "resolve"

--[[
we should not have to define lua socket related error constants!
referencing https://github.com/diegonehab/luasocket source

    io.c: io_strerror

        switch (err) {
            case IO_DONE: return NULL;
            case IO_CLOSED: return "closed";
            case IO_TIMEOUT: return "timeout";
            default: return "unknown error";
        }

    usocket.c: socket_strerror

        if (err <= 0) return io_strerror(err);
        switch (err) {
            case EADDRINUSE: return PIE_ADDRINUSE;
            case EISCONN: return PIE_ISCONN;
            case EACCES: return PIE_ACCESS;
            case ECONNREFUSED: return PIE_CONNREFUSED;
            case ECONNABORTED: return PIE_CONNABORTED;
            case ECONNRESET: return PIE_CONNRESET;
            case ETIMEDOUT: return PIE_TIMEDOUT;
            default: {
                return strerror(err);
            }
        }

    pierror.h:

        #define PIE_HOST_NOT_FOUND "host not found"
        #define PIE_ADDRINUSE      "address already in use"
        #define PIE_ISCONN         "already connected"
        #define PIE_ACCESS         "permission denied"
        #define PIE_CONNREFUSED    "connection refused"
        #define PIE_CONNABORTED    "closed"
        #define PIE_CONNRESET      "closed"
        #define PIE_TIMEDOUT       "timeout"
        #define PIE_AGAIN          "temporary failure in name resolution"
        #define PIE_BADFLAGS       "invalid value for ai_flags"
        #define PIE_BADHINTS       "invalid value for hints"
        #define PIE_FAIL           "non-recoverable failure in name resolution"
        #define PIE_FAMILY         "ai_family not supported"
        #define PIE_MEMORY         "memory allocation failure"
        #define PIE_NONAME         "host or service not provided, or not known"
        #define PIE_OVERFLOW       "argument buffer overflow"
        #define PIE_PROTOCOL       "resolved protocol is unknown"
        #define PIE_SERVICE        "service not supported for socket type"
        #define PIE_SOCKTYPE       "ai_socktype not supported"

SmartThings fork of luasocket (where is it?) must be different as an
ECONNRESET condition results in "Connection reset by peer".
]]--

local SOCKET_ERROR_CLOSED        = "closed"
local SOCKET_ERROR_CONNRESET     = "Connection reset by peer"   -- strerror(ECONRESET)
local SOCKET_ERROR_TIMEOUT       = "timeout"

local function starts_with(whole, part)
    return part == whole:sub(1, #part)
end

local function json_decode(encoded)
    return coroutine.wrap(function()
        local begin = 1
        while (begin <= #encoded) do
            local decoded, _end, _error = json.decode(encoded, begin)
            if _error then
                -- log.warn("json.decode", encoded:sub(begin), "error", _error)
                -- ^ no, don't do this. instead, quietly swallow the error because,
                -- in the smartthings environment, log.warn implicitly coroutine.yield's a value like
                -- {from=function: 0xXXXXXX, method="print", params={log_level="warn", log_opts={}, message="..."}}
                -- which is intended to be processed by the cosock coroutine executor
                -- and that is not what we want.
                -- we could yield an error and depend on our caller to log.warn for us but ... not for now.
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

local Controller

local M = {

    hash_password = function(data)
        -- Return a hash of data for turning a password into a key.
        return Array.toString(MD5().update(Stream.fromArray(Array.fromString(data))).finish().asBytes())
    end,

    -- Composer of messages.
    Composer = classify.single({
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
    }),

    -- Sender of messages.
    Sender = {
        _init = function(class, self)
            self.Sender = class
            classify.super(class):_init(self)
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
        Status = classify.single({
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
        }),

        _init = function(class, self)
            self.Receiver = class
            classify.super(class):_init(self)
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
            for _super in classify.supers(class) do
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
            classify.super(class):_init(self)
            self._authentication = authentication
        end,

        _identified = function(self, controller_id)
            self._controller_id = controller_id:lower()
            self:emit(self.EVENT_IDENTIFIED, self, self._controller_id)
        end,

        controller_id = function(self)
            return self._controller_id
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
                local authentication = self._authentication[self._controller_id]
                if nil ~= authentication then
                    return authentication
                end
            end
            self.Continue("noauth", self._controller_id)
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
            local controller_id = self._reader:read_exactly(12)
            log.debug("\t\t>\t", controller_id)
            self:_identified(controller_id)
            self:_send_challenge_response(self:_get_authentication(), Array.toString(Array.fromHex(challenge)))
        end,

        _receive_security_hello_ok = function(self)
            self:_authenticated()
        end,

        _receive_security_hello_invalid = function(self)
            self.Continue("unauth", self._controller_id)
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

    -- A Controller is an Authenticator that loops over connections/sessions.
    Controller = {

        -- for loop control, from same thread
        Break       = classify.error({}),
        Continue    = classify.error({}),

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
            classify.super(class):_init(self, authentication)
            self._host = host or self.HOST
            self._port = port or self.PORT
        end,

        host = function(self)
            return self._host
        end,

        port = function(self)
            return self._port
        end,

        address = function(self)
            return self._host .. ":" .. self._port
        end,

        loop = function(self, backoff_cap, read_timeout, break_on_connect_error)
            -- loop continues to (re)connect and run sessions.
            -- a Continue object constructed in this context causes a reconnect.
            -- a Break object constructed in this context causes the loop to stop.
            -- the loop also stops on a connect_error if told to (break_on_connect_error).
            backoff_cap = backoff_cap or self.LOOP_BACKOFF_CAP
            read_timeout = read_timeout or self.READ_TIMEOUT
            local continue_on = {
                [SOCKET_ERROR_TIMEOUT]      = true,
                [SOCKET_ERROR_CLOSED]       = true,
                [SOCKET_ERROR_CONNRESET]    = true,
            }
            local abort_error
            local backoff = 0
            while true do
                local client = cosock.socket.tcp()
                local connected, connect_error = client:connect(self._host, self._port)
                if connected then
                    client:settimeout(0)    -- when anything ready, receive something
                    self._reader = Reader(function()
                        local _, _, receive_error = cosock.socket.select({client}, {}, read_timeout)
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
                    log.warn("close", self:address(), self:controller_id())
                    self:emit(self.EVENT_DISCONNECTED, self)
                    if continue_on[session_error] then
                        backoff = 0
                        log.warn(session_error, self:address(), self:controller_id())
                    elseif self.Break == classify.class(session_error) then
                        log.debug("break", self:address(), table.unpack(session_error))
                        break
                    elseif self.Continue == classify.class(session_error) then
                        log.debug("cont", self:address(), table.unpack(session_error))
                        -- continue
                    else
                        abort_error = session_error
                        break
                    end
                else
                    -- connect will fail if the host is unreachable.
                    -- this will not happen for a neighbor unless/until
                    -- the host is not in, or ages out of, the ARP cache.
                    client:close()
                    log.warn("close", self:address(), connect_error)
                    if break_on_connect_error then
                        break
                    end
                end
                -- reconnect after capped exponential backoff
                cosock.socket.sleep(1 << math.min(backoff, backoff_cap))
                backoff = backoff + 1
            end
            -- on an unexpected abort_error,
            -- our EVENT_STOPPED may not come with a controller_id
            -- as our peer may never have been identified.
            log.debug(self.EVENT_STOPPED, self:address(), self:controller_id())
            self:emit(self.EVENT_STOPPED, self, self:controller_id())
            if abort_error then
                log.error("abort", self:address(), abort_error)
                error(abort_error)
            end
        end,
    },

    -- Manage an inventory of identified Controllers.
    Inventory = classify.single({

        -- events emitted
        EVENT_ADD       = "add",
        EVENT_REMOVE    = "remove",

        -- default arguments
        DISCOVER_BACKOFF_CAP = 8,

        _init = function(class, self, authentication)
            classify.super(class):_init(self)
            self._authentication = authentication

            -- inventory
            self.controller = {}    -- by controller:controller_id()
            self._running = {}      -- by controller:address()

            self._subscription = {
                [Controller.EVENT_IDENTIFIED]      = function(controller, controller_id)
                    self:_add(controller, controller_id)
                end,
                [Controller.EVENT_STOPPED]         = function(controller, controller_id)
                    if controller_id then
                        self:_remove(controller, controller_id)
                    end
                end,
            }
        end,

        _subscribe = function(self, controller, method)
            log.debug("sub " .. method, controller:address(), controller:controller_id())
            for event, handler in pairs(self._subscription) do
                controller[method](controller, event, handler)
            end
        end,

        _remove = function(self, controller, controller_id)
            self:_subscribe(controller, "off")
            local address = controller:address()
            self._running[address] = nil
            if not controller._dup then
                self.controller[controller_id] = nil
                log.debug(self.EVENT_REMOVE, address, controller_id)
                self:emit(self.EVENT_REMOVE, controller, controller_id)
            end
            if controller._rediscover then
                self._discover_sender:send(0)
            end
        end,

        _add = function(self, new_controller, controller_id)
            local old_controller = self.controller[controller_id]
            if new_controller ~= old_controller then
                if old_controller then
                    -- the new_controller resolves to the same controller_id as an old_controller.
                    -- this may happen when DHCP affects a change on the lc7001's IP address.
                    -- this could/should be avoided by registering a static lease in the DHCP service!
                    -- the old_controller loop will be continually trying to re-connect
                    -- and will not stop (and be removed from our inventory) until
                    -- its entry ages out of the system's ARP cache.
                    -- we will break out of (and stop) the new_controller.
                    -- when it is _remove'd from our inventory, we will notice that
                    -- we marked it as a _dup to prevent the old_controller from being removed
                    -- from our inventory.
                    -- our discover method/thread will mark a Controller it creates with _rediscover
                    -- and _remove will tell it to immediately try to rediscover it.
                    -- this behavior will continue until the old_controller fails, stops
                    -- and the old_controller is removed from our inventory.
                    new_controller._dup = true
                    Controller.Break(controller_id, "dup")
                else
                    self.controller[controller_id] = new_controller
                    log.debug(self.EVENT_ADD, new_controller:address(), controller_id)
                    self:emit(self.EVENT_ADD, new_controller, controller_id)
                end
            end
        end,

        ask = function(self, controller, loop_backoff_cap, read_timeout, rediscover)
            local address = controller:address()
            log.debug("ask", address)
            if self._running[address] then
                log.debug("dup", address)
            else
                self._running[address] = true
                self:_subscribe(controller, "on")
                cosock.spawn(function()
                    controller:loop(loop_backoff_cap, read_timeout, rediscover)
                end, "lc7001.Controller " .. address)
            end
        end,

        discover = function(self, backoff_cap, loop_backoff_cap, read_timeout)
            backoff_cap = backoff_cap or self.DISCOVER_BACKOFF_CAP
            if self._discover_sender then
                self._discover_sender:send(0)
            else
                local sender, receiver = cosock.channel.new()
                self._discover_sender = sender
                cosock.spawn(function()
                    local backoff = 0
                    while true do
                        resolve(Controller.HOST, function(host)
                            local controller = Controller(host, nil, self._authentication)
                            controller._rediscover = true
                            self:ask(controller, loop_backoff_cap, read_timeout, true)
                        end)
                        -- rediscover after capped exponential backoff
                        -- or our receiver hears from our sender.
                        while cosock.socket.select({receiver}, {}, 1 << math.min(backoff, backoff_cap)) do
                            log.debug("rediscover")
                            backoff = receiver:receive()
                        end
                        backoff = backoff + 1
                    end
                end, "lc7001.Inventory.discover")
            end
        end,
    }, Emitter),
}

Controller = M.Controller

classify.single(M.Sender, M.Composer)
classify.single(M.Receiver, M.Sender)
classify.multiple(M.ReceiverEmitter, M.Receiver, Emitter)
classify.single(M.Authenticator, M.ReceiverEmitter)
classify.single(M.Controller, M.Authenticator)

return M
