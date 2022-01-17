-- vim: ts=4:sw=4:expandtab

-- require st provided libraries
local capabilities  = require "st.capabilities"
local cosock        = require "cosock"
local Driver        = require "st.driver"
local log           = require "log"

local lc7001 = require "lc7001"
local Emitter = require "util.emitter"

-- device models/types, sub_drivers
local PARENT    = "lc7001"
local SWITCH    = "switch"
local DIMMER    = "dimmer"

-- subscription methods
local ON        = "on"
local OFF       = "off"

-- Adapter callbacks from device
local ADAPTER       = "adapter"
local INFO_CHANGED  = "info_changed"
local POWER         = "power"
local POWER_LEVEL   = "power_level"
local REFRESH       = "refresh"
local REMOVED       = "removed"
local SUBSCRIBE     = "subscribe"

local authentication = {}
local inventory = lc7001.Inventory(authentication)

local function super(class)
    return getmetatable(class).__index
end

local function new(class, ...)
    local self = setmetatable({}, class)
    class:_init(self, ...)
    return self
end

-- A Built instance remembers adapters that have been built for devices
-- and emits device_network_id events with the adapter after it has been added
local Built = {
    _init = function(_, self)
        self.emitter = Emitter()
        self.adapter = {}
    end,

    add = function(self, adapter)
        local device_network_id = adapter.device.device_network_id
        self.adapter[device_network_id] = adapter
        self.emitter:emit(device_network_id, adapter)
    end,

    remove = function(self, device_network_id)
        self.adapter[device_network_id] = nil
    end,

    after = function(self, device_network_id, handler)
        if not device_network_id then
            handler()
        else
            local adapter = self.adapter[device_network_id]
            if adapter then
                handler(adapter)
                return adapter
            end
            self.emitter:once(device_network_id, handler)
        end
    end,

    flush = function(self)
        self.emitter = Emitter()
    end,
}

Built.__index = Built
setmetatable(Built, {
    __call = new
})

local built = Built()

local function refresh(hub, device_network_id, method)
    local parent = built.adapter[device_network_id]
    if parent then
        parent:subscribe(hub, method)
        parent:refresh()
    end
end

local discovery_sender

inventory:on(inventory.EVENT_ADD, function(hub, device_network_id)
    refresh(hub, device_network_id, ON)
    if discovery_sender then
        log.debug("discovery", "add", device_network_id)
        discovery_sender:send(device_network_id)
    end
end)

inventory:on(inventory.EVENT_REMOVE, function(hub, device_network_id)
    refresh(hub, device_network_id, OFF)
end)

local Adapter = {
    _init = function(_, self, driver, device)
        log.debug("init", device.device_network_id, device.st_store.label)
        self.driver = driver
        self.device = device
        device:set_field(ADAPTER, self)
        local hub = self:hub()
        if hub then
            self:subscribe(hub, ON)
        end
        self:refresh()
    end,

    removed = function(self)
        local device = self.device
        local hub = self:hub()
        if hub then
            self:subscribe(hub, OFF)
        end
        self.device:set_field(ADAPTER, nil)
        self.device = nil
        self.driver = nil
        log.debug("removed", device.device_network_id, device.st_store.label)
    end,

    call = function(device, method, ...)
        local adapter = device:get_field(ADAPTER)
        if adapter then
            adapter[method](adapter, ...)
        else
            -- we will end up here after SmartThings hub reboot
            -- when the parent adapter (for the hub) is refreshed (on init)
            -- but its child zone adapters have not yet been created. 
            log.warn(method, device.device_network_id, device.st_store.label)
        end
    end,

    subscribe = function(self, hub, method)
        log.debug(method, self.device.device_network_id, self.device.st_store.label)
        for event, handler in pairs(self.subscription) do
            hub[method](hub, event, handler)
        end
    end,

    refresh = function(self, method)
        log.debug("refresh", self.device.device_network_id, self.device.st_store.label)
        local hub = self:hub()
        if hub and hub:online() then
            if method then
                method(hub)
            else
                self.device:online()
            end
        else
            self.device:offline()
        end
    end,
}

-- Adapter subclasses cannot extend its capability_handlers by lua inheritance
-- but can copy entries
Adapter.capability_handlers = {
    [capabilities.refresh.ID] = {
        [capabilities.refresh.commands.refresh.NAME] = function(_, device)
            Adapter.call(device, REFRESH)
        end,
    },
}

local Parent = {
    _init = function(class, self, driver, device)
        self.subscription = {
            [lc7001.Hub.EVENT_AUTHENTICATED] = function() self:refresh() end,
            [lc7001.Hub.EVENT_DISCONNECTED]  = function() self:refresh() end,
        }
        super(class):_init(self, driver, device)
        authentication[self.device.device_network_id] = lc7001.hash_password(self.device.st_store.preferences.password)
    end,

    info_changed = function(self, event, _)
        log.debug("info", self.device.device_network_id, self.device.st_store.label, event)
        authentication[self.device.device_network_id] = lc7001.hash_password(self.device.st_store.preferences.password)
    end,

    hub = function(self)
        return inventory.hub[self.device.device_network_id]
    end,

    subscribe = function(self, hub, method)
        Adapter.subscribe(self, hub, method)
        for _, device in ipairs(self.driver:get_devices()) do
            if device.parent_device_id == self.device.id then
                Adapter.call(device, SUBSCRIBE, hub, method)
            end
        end
    end,

    refresh = function(self)
        Adapter.refresh(self)
        for _, device in ipairs(self.driver:get_devices()) do
            if device.parent_device_id == self.device.id then
                Adapter.call(device, REFRESH)
            end
        end
    end,

    capability_handlers = {
        [capabilities.refresh.ID] = Adapter.capability_handlers[capabilities.refresh.ID],
    },
}

local Switch = {
    _init = function(class, self, driver, device)
        local it = device.device_network_id:gmatch("%x+")
        self.parent_device_network_id, self.zid = it(), tonumber(it())
        self.subscription = {
            [lc7001.Hub.EVENT_REPORT_ZONE_PROPERTIES  .. ":" .. self.zid] = function(hub, properties)
                self:emit(hub, properties)
            end,
            [lc7001.Hub.EVENT_ZONE_PROPERTIES_CHANGED .. ":" .. self.zid] = function(hub, properties)
                self:emit(hub, properties)
            end,
            [lc7001.Hub.EVENT_ZONE_DELETED .. ":" .. self.zid] = function()
                log.warn("deleted", self.parent_device_network_id, self.zid, self.device.st_store.label)
                self.device:offline()
            end,
            [lc7001.Hub.EVENT_ZONE_ADDED .. ":" .. self.zid] = function()
                log.warn("added", self.parent_device_network_id, self.zid, self.device.st_store.label)
                self:refresh()
            end,
        }
        super(class):_init(self, driver, device)
    end,

    hub = function(self)
        return inventory.hub[self.parent_device_network_id]
    end,

    emit = function(self, hub, properties)
        local status = hub.Status(properties)
        if status.error then
            log.error("offline", self.parent_device_network_id, self.zid, self.device.st_store.label, status.text)
            self.device:offline()
            return nil
        end
        self.device:online()
        local property_list = properties[hub.PROPERTY_LIST]
        local power = property_list[hub.POWER]
        if power then
            self.device:emit_event(capabilities.switch.switch.on())
        else
            self.device:emit_event(capabilities.switch.switch.off())
        end
        return property_list
    end,

    refresh = function(self)
        Adapter.refresh(self, function(hub)
            hub:send(hub:compose_report_zone_properties(self.zid))
        end)
    end,

    power = function(self, on)
        local hub = self:hub()
        if hub and hub:online() then
            hub:send(hub:compose_set_zone_properties(self.zid, {[hub.POWER] = on}))
        end
    end,

    capability_handlers = {
        [capabilities.refresh.ID] = Adapter.capability_handlers[capabilities.refresh.ID],
        [capabilities.switch.ID] = {
            [capabilities.switch.commands.on.NAME] = function(_, device)
                Adapter.call(device, POWER, true)
            end,
            [capabilities.switch.commands.off.NAME] = function(_, device)
                Adapter.call(device, POWER, false)
            end,
        },
    },
}

local Dimmer = {
    emit = function(self, hub, properties)
        local property_list = Switch.emit(self, hub, properties)
        if property_list then
            local power_level = property_list[hub.POWER_LEVEL]
            if power_level then
                self.device:emit_event(capabilities.switchLevel.level(power_level))
            end
        end
    end,

    power_level = function(self, level)
        local hub = self:hub()
        if hub and hub:online() then
            hub:send(hub:compose_set_zone_properties(self.zid, {[hub.POWER_LEVEL] = math.max(1, level)}))
        end
    end,

    capability_handlers = {
        [capabilities.refresh.ID] = Adapter.capability_handlers[capabilities.refresh.ID],
        [capabilities.switch.ID] = Switch.capability_handlers[capabilities.switch.ID],
        [capabilities.switchLevel.ID] = {
            [capabilities.switchLevel.commands.setLevel.NAME] = function(_, device, command)
                Adapter.call(device, POWER_LEVEL, tonumber(command.args.level))
            end,
        },
    },
}

Adapter.__index = Adapter
setmetatable(Adapter, {
    __call = new
})

Parent.__index = Parent
setmetatable(Parent, {
    __index = Adapter,
    __call = new
})

Switch.__index = Switch
setmetatable(Switch, {
    __index = Adapter,
    __call = new
})

Dimmer.__index = Dimmer
setmetatable(Dimmer, {
    __index = Switch,
    __call = new
})

inventory:discover()

local driver = Driver("legrand-rflc", {

    discovery = function(driver, _, should_continue)

        -- spawn a build thread that will not try to create another device
        -- until after the last one has been built.
        local build_sender, build_receiver = cosock.channel.new()
        cosock.spawn(function()
            log.debug("discovery", "start")
            local last_device_network_id
            while cosock.socket.select({build_receiver}) do
                local device_network_id, model, label, parent_device_id = table.unpack(build_receiver:receive())
                if not device_network_id then break end
                built:after(last_device_network_id, function()
                    log.debug("discovery", "create", device_network_id, model, label, parent_device_id)
                    driver:try_create_device{
                        type = "LAN",
                        device_network_id = device_network_id,
                        label = label,
                        profile = model,
                        manufacturer = "legrand",
                        model = model,
                        parent_device_id = parent_device_id,
                    }
                end)
                last_device_network_id = device_network_id
            end
            built:flush()
            log.debug("discovery", "stop")
        end, "build")

        inventory:discover()

        local discovery_receiver
        discovery_sender, discovery_receiver = cosock.channel.new()
        local pending = {}
        repeat
            for device_network_id, hub in pairs(inventory.hub) do
                if not built:after(device_network_id, function(parent)
                    if hub:online() then
                        -- build zone devices reported by parent hub
                        hub:converse(hub:compose_list_zones(), function(_, zones)
                            local zones_status = hub.Status(zones)
                            if zones_status.error then
                                log.error("discovery", "zones", device_network_id, zones_status.text)
                            else
                                for _, zone in pairs(zones[hub.ZONE_LIST]) do
                                    local zid = zone[hub.ZID]
                                    local zone_device_network_id = device_network_id .. ":" .. zid
                                    if not (built.adapter[zone_device_network_id]
                                            or pending[zone_device_network_id]) then
                                        hub:converse(hub:compose_report_zone_properties(zid), function(_, properties)
                                            local status = hub.Status(properties)
                                            if status.error then
                                                log.error("discovery", "zone", zone_device_network_id, status.text)
                                            else
                                                local property_list = properties[hub.PROPERTY_LIST]
                                                pending[zone_device_network_id] = true
                                                build_sender:send{
                                                    zone_device_network_id,
                                                    property_list[hub.DEVICE_TYPE]:lower(),
                                                    property_list[hub.NAME],
                                                    parent.device.id,
                                                }
                                            end
                                        end)
                                    end
                                end
                            end
                        end)
                    end
                end) then
                    -- build parent device for zones
                    if not pending[device_network_id] then
                        pending[device_network_id] = true
                        build_sender:send{
                            device_network_id,
                            PARENT,
                            "Legrand Whole House Lighting Controller " .. device_network_id,
                        }
                    end
                end
            end
            local timeout = 8
            while should_continue() and cosock.socket.select({discovery_receiver}, {}, timeout) do
                log.debug("discovery", "ready", discovery_receiver:receive())
                timeout = 0
            end
        until not should_continue()
        discovery_sender = nil
        build_sender:send{}
    end,

    lifecycle_handlers = {
        removed = function(_, device)
            Adapter.call(device, REMOVED)
            built:remove(device.device_network_id)
        end,
    },

    sub_drivers = {
        {
            NAME = PARENT,
            can_handle = function(_, _, device) return device.st_store.model == PARENT end,
            lifecycle_handlers = {
                init = function(driver, device) built:add(Parent(driver, device)) end,
                infoChanged = function(_, device, event, args) Adapter.call(device, INFO_CHANGED, event, args) end,
            },
            capability_handlers = Parent.capability_handlers,
        },
        {
            NAME = SWITCH,
            can_handle = function(_, _, device) return device.st_store.model == SWITCH end,
            lifecycle_handlers = {init = function(driver, device) built:add(Switch(driver, device)) end},
            capability_handlers = Switch.capability_handlers,
        },
        {
            NAME = DIMMER,
            can_handle = function(_, _, device) return device.st_store.model == DIMMER end,
            lifecycle_handlers = {init = function(driver, device) built:add(Dimmer(driver, device)) end},
            capability_handlers = Dimmer.capability_handlers,
        },
    },
})

driver:run()
