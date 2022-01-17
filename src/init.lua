-- vim: ts=4:sw=4:expandtab

-- require st provided libraries
local capabilities  = require "st.capabilities"
local cosock        = require "cosock"
local Driver        = require "st.driver"
local log           = require "log"

local lc7001 = require "lc7001"

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

local parent_by_device_network_id = {}
local discovery_parent_sender, discovery_parent_receiver = nil, nil

local function refresh(hub, device_network_id, method)
    local parent = parent_by_device_network_id[device_network_id]
    if parent then
        parent:subscribe(hub, method)
        parent:refresh()
    end
end

inventory:on(inventory.EVENT_ADD, function(hub, device_network_id)
    refresh(hub, device_network_id, ON)
    if (discovery_parent_sender) then
        log.debug("discovery", "add", device_network_id)
        discovery_parent_sender:send(device_network_id)
    end
end)

inventory:on(inventory.EVENT_REMOVE, function(hub, device_network_id)
    refresh(hub, device_network_id, OFF)
end)

local function super(class)
    return getmetatable(class).__index
end

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
            -- after discovery, sometimes device is added without being init'ed
            -- (why?!) and we will end up here (instead of aborting).
            -- rebooting the hub seems to fix things.
            log.error(method, device.device_network_id, device.st_store.label)
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
        parent_by_device_network_id[device.device_network_id] = self
        if (discovery_parent_sender) then
            log.debug("discovery", "init", device.device_network_id)
            discovery_parent_sender:send(device.device_network_id)
        end
    end,

    removed = function(self)
        parent_by_device_network_id[self.device.device_network_id] = nil
        Adapter.removed(self)
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

local zone_by_device_network_id = {}

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
        zone_by_device_network_id[device.device_network_id] = self
    end,

    removed = function(self)
        zone_by_device_network_id[self.device.device_network_id] = nil
        Adapter.removed(self)
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

local function new(class, ...)
    local self = setmetatable({}, class)
    class:_init(self, ...)
    return self
end

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

        local function create(device_network_id, model, label, parent_device_id)
            log.debug("discovery", "create", device_network_id, model, label, parent_device_id)
            driver:try_create_device({
                type = "LAN",
                device_network_id = device_network_id,
                label = label,
                profile = model,
                manufacturer = "legrand",
                model = model,
                parent_device_id = parent_device_id,
            })
            cosock.socket.sleep(1)
        end

        log.debug("discovery", "start")
        discovery_parent_sender, discovery_parent_receiver = cosock.channel.new()
        inventory:discover()
        repeat
            for device_network_id, hub in pairs(inventory.hub) do
                local parent = parent_by_device_network_id[device_network_id]
                if not parent then
                    -- try to create parent device for hub
                    create(device_network_id, PARENT, "Legrand Whole House Lighting Controller " .. device_network_id)
                elseif hub:online() then
                    -- try to create zone devices reported by hub
                    -- queue zones from hub thread back to this one
                    local zone_sender, zone_receiver = cosock.channel.new()
                    hub:converse(hub:compose_list_zones(), function(_, zones)
                        local zones_status = hub.Status(zones)
                        if zones_status.error then
                            log.error("discovery", "zones", device_network_id, zones_status.text)
                        else
                            for _, zone in pairs(zones[hub.ZONE_LIST]) do
                                local zid = zone[hub.ZID]
                                local zone_device_network_id = device_network_id .. ":" .. zid
                                if not zone_by_device_network_id[zone_device_network_id] then
                                    hub:converse(hub:compose_report_zone_properties(zid), function(_, properties)
                                        local status = hub.Status(properties)
                                        if status.error then
                                            log.error("discovery", "zone", zone_device_network_id, status.text)
                                        else
                                            local property_list = properties[hub.PROPERTY_LIST]
                                            zone_sender:send({
                                                zone_device_network_id,
                                                property_list[hub.DEVICE_TYPE]:lower(),
                                                property_list[hub.NAME],
                                                parent.device.id,
                                            })
                                        end
                                    end)
                                end
                            end
                        end
                    end)
                    while cosock.socket.select({zone_receiver}, {}, 4) and should_continue() do
                        create(table.unpack(zone_receiver:receive()))
                    end
                end
            end
            local timeout = 8
            while should_continue() and cosock.socket.select({discovery_parent_receiver}, {}, timeout) do
                log.debug("discovery", "ready", discovery_parent_receiver:receive())
                timeout = 0
            end
        until not should_continue()
        discovery_parent_sender, discovery_parent_receiver = nil, nil
        log.debug("discovery", "stop")
    end,

    lifecycle_handlers = {removed = function(_, device) Adapter.call(device, REMOVED) end},

    sub_drivers = {
        {
            NAME = PARENT,
            can_handle = function(_, _, device) return device.st_store.model == PARENT end,
            lifecycle_handlers = {
                init = function(driver, device) Parent(driver, device) end,
                infoChanged = function(_, device, event, args) Adapter.call(device, INFO_CHANGED, event, args) end,
            },
            capability_handlers = Parent.capability_handlers,
        },
        {
            NAME = SWITCH,
            can_handle = function(_, _, device) return device.st_store.model == SWITCH end,
            lifecycle_handlers = {init = function(driver, device) Switch(driver, device) end},
            capability_handlers = Switch.capability_handlers,
        },
        {
            NAME = DIMMER,
            can_handle = function(_, _, device) return device.st_store.model == DIMMER end,
            lifecycle_handlers = {init = function(driver, device) Dimmer(driver, device) end},
            capability_handlers = Dimmer.capability_handlers,
        },
    },
})

driver:run()
