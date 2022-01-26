-- vim: ts=4:sw=4:expandtab

-- require st provided libraries
local capabilities  = require "st.capabilities"
local cosock        = require "cosock"
local Driver        = require "st.driver"
local log           = require "log"

local lc7001        = require "lc7001"

local classify      = require "util.classify"
local Semaphore     = require "util.semaphore"

-- device models/types, sub_drivers
local PARENT        = "lc7001"
local SWITCH        = "switch"
local DIMMER        = "dimmer"

-- subscription methods
local ON            = "on"
local OFF           = "off"

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

-- use a binary Semaphore to serialize access to driver:try_create_device() calls;
-- otherwise, these requests tend to get ignored or not completed through lifecycle init.
local try_create_device_semaphore = Semaphore()

-- ready remembers adapters (by device_network_id) that have been init'ed for devices.
-- ready:add does a try_create_device_semaphore:release
-- and any pending use of this adapter is performed.
local ready = {
    adapter = {},
    pending = {},

    add = function(self, adapter)
        local device_network_id = adapter.device.device_network_id
        self.adapter[device_network_id] = adapter
        try_create_device_semaphore:release()
        local use = self.pending[device_network_id]
        if use then
            use()
            self.pending[device_network_id] = nil
        end
    end,

    remove = function(self, device_network_id)
        self.adapter[device_network_id] = nil
    end,

    acquire = function(self, device_network_id, use)
        local adapter = self.adapter[device_network_id]
        if adapter then
            use(adapter)
            return adapter
        end
        self.pending[device_network_id] = use
    end,
}

local function refresh(controller, device_network_id, method)
    local parent = ready.adapter[device_network_id]
    if parent then
        parent:subscribe(controller, method)
        parent:refresh()
    end
end

local discovery_sender

inventory:on(inventory.EVENT_ADD, function(controller, device_network_id)
    refresh(controller, device_network_id, ON)
    if discovery_sender then
        log.debug("discovery", "add", device_network_id)
        discovery_sender:send(device_network_id)
    end
end)

inventory:on(inventory.EVENT_REMOVE, function(controller, device_network_id)
    refresh(controller, device_network_id, OFF)
end)

local Adapter = classify.single({
    _init = function(_, self, driver, device)
        log.debug("init", device.device_network_id, device.st_store.label)
        self.driver = driver
        self.device = device
        device:set_field(ADAPTER, self)
        local controller = self:controller()
        if controller then
            self:subscribe(controller, ON)
        end
        self:refresh()
    end,

    removed = function(self)
        local device = self.device
        local controller = self:controller()
        if controller then
            self:subscribe(controller, OFF)
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
            -- when the parent adapter (for the controller) is refreshed (on init)
            -- but its child zone adapters have not yet been created.
            log.warn(method, device.device_network_id, device.st_store.label)
        end
    end,

    subscribe = function(self, controller, method)
        log.debug(method, self.device.device_network_id, self.device.st_store.label)
        for event, handler in pairs(self.subscription) do
            controller[method](controller, event, handler)
        end
    end,

    refresh = function(self, method)
        log.debug("refresh", self.device.device_network_id, self.device.st_store.label)
        local controller = self:controller()
        if controller and controller:online() then
            if method then
                method(controller)
            else
                self.device:online()
            end
        else
            self.device:offline()
        end
    end,
})
-- Adapter subclasses cannot extend its capability_handlers by lua inheritance
-- but can copy entries
Adapter.capability_handlers = {
    [capabilities.refresh.ID] = {
        [capabilities.refresh.commands.refresh.NAME] = function(_, device)
            Adapter.call(device, REFRESH)
        end,
    },
}

local Parent = classify.single({
    _init = function(class, self, driver, device)
        self.subscription = {
            [lc7001.Controller.EVENT_AUTHENTICATED] = function() self:refresh() end,
            [lc7001.Controller.EVENT_DISCONNECTED]  = function() self:refresh() end,
        }
        classify.super(class):_init(self, driver, device)
        authentication[self.device.device_network_id] = lc7001.hash_password(self.device.st_store.preferences.password)
    end,

    info_changed = function(self, event, _)
        log.debug("info", self.device.device_network_id, self.device.st_store.label, event)
        authentication[self.device.device_network_id] = lc7001.hash_password(self.device.st_store.preferences.password)
    end,

    controller = function(self)
        return inventory.controller[self.device.device_network_id]
    end,

    subscribe = function(self, controller, method)
        Adapter.subscribe(self, controller, method)
        for _, device in ipairs(self.driver:get_devices()) do
            if device.parent_device_id == self.device.id then
                Adapter.call(device, SUBSCRIBE, controller, method)
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
}, Adapter)

local Switch = classify.single({
    _init = function(class, self, driver, device)
        local it = device.device_network_id:gmatch("%x+")
        self.parent_device_network_id, self.zid = it(), tonumber(it())
        self.subscription = {
            [lc7001.Controller.EVENT_REPORT_ZONE_PROPERTIES  .. ":" .. self.zid] = function(controller, properties)
                self:emit(controller, properties)
            end,
            [lc7001.Controller.EVENT_ZONE_PROPERTIES_CHANGED .. ":" .. self.zid] = function(controller, properties)
                self:emit(controller, properties)
            end,
            [lc7001.Controller.EVENT_ZONE_DELETED .. ":" .. self.zid] = function()
                log.warn("deleted", self.parent_device_network_id, self.zid, self.device.st_store.label)
                self.device:offline()
            end,
            [lc7001.Controller.EVENT_ZONE_ADDED .. ":" .. self.zid] = function()
                log.warn("added", self.parent_device_network_id, self.zid, self.device.st_store.label)
                self:refresh()
            end,
        }
        classify.super(class):_init(self, driver, device)
    end,

    controller = function(self)
        return inventory.controller[self.parent_device_network_id]
    end,

    emit = function(self, controller, properties)
        local status = controller.Status(properties)
        if status.error then
            log.error("offline", self.parent_device_network_id, self.zid, self.device.st_store.label, status.text)
            self.device:offline()
            return nil
        end
        self.device:online()
        local property_list = properties[controller.PROPERTY_LIST]
        local power = property_list[controller.POWER]
        if power then
            self.device:emit_event(capabilities.switch.switch.on())
        else
            self.device:emit_event(capabilities.switch.switch.off())
        end
        return property_list
    end,

    refresh = function(self)
        Adapter.refresh(self, function(controller)
            controller:send(controller:compose_report_zone_properties(self.zid))
        end)
    end,

    power = function(self, on)
        local controller = self:controller()
        if controller and controller:online() then
            controller:send(controller:compose_set_zone_properties(self.zid, {[controller.POWER] = on}))
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
}, Adapter)

local Dimmer = classify.single({
    emit = function(self, controller, properties)
        local property_list = Switch.emit(self, controller, properties)
        if property_list then
            local power_level = property_list[controller.POWER_LEVEL]
            if power_level then
                self.device:emit_event(capabilities.switchLevel.level(power_level))
            end
        end
    end,

    power_level = function(self, level)
        local controller = self:controller()
        if controller and controller:online() then
            controller:send(controller:compose_set_zone_properties(self.zid,
                {[controller.POWER_LEVEL] = math.max(1, level)}))
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
}, Switch)

inventory:discover()

local driver = Driver("legrand-rflc", {

    discovery = function(driver, _, should_continue)
        log.debug("discovery", "start")

        inventory:discover()

        local pending = {}
        local function create(device_network_id, model, label, parent_device_id)
            pending[device_network_id] = true
            try_create_device_semaphore:acquire(function()
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
        end

        local discovery_receiver
        discovery_sender, discovery_receiver = cosock.channel.new()
        repeat
            for device_network_id, controller in pairs(inventory.controller) do
                if not ready:acquire(device_network_id, function(parent)
                    if controller:online() then
                        -- create zone devices reported by parent controller
                        controller:converse(controller:compose_list_zones(), function(_, zones)
                            local zones_status = controller.Status(zones)
                            if zones_status.error then
                                log.error("discovery", "zones", device_network_id, zones_status.text)
                            else
                                for _, zone in pairs(zones[controller.ZONE_LIST]) do
                                    local zid = zone[controller.ZID]
                                    local zone_device_network_id = device_network_id .. ":" .. zid
                                    if not (ready.adapter[zone_device_network_id]
                                            or pending[zone_device_network_id]) then
                                        controller:converse(controller:compose_report_zone_properties(zid),
                                                function(_, properties)
                                            local status = controller.Status(properties)
                                            if status.error then
                                                log.error("discovery", "zone", zone_device_network_id, status.text)
                                            else
                                                local property_list = properties[controller.PROPERTY_LIST]
                                                local model = property_list[controller.DEVICE_TYPE]:lower()
                                                local label = property_list[controller.NAME]
                                                create(zone_device_network_id, model, label, parent.device.id)
                                            end
                                        end)
                                    end
                                end
                            end
                        end)
                    end
                end) then
                    -- create parent device for zones
                    if not pending[device_network_id] then
                        local label = "Legrand Whole House Lighting Controller " .. device_network_id
                        create(device_network_id, PARENT, label)
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

	-- clear discovery callbacks
        try_create_device_semaphore = Semaphore()
	ready.pending = {}

        log.debug("discovery", "stop")
    end,

    lifecycle_handlers = {
        removed = function(_, device)
            Adapter.call(device, REMOVED)
            ready:remove(device.device_network_id)
        end,
    },

    sub_drivers = {
        {
            NAME = PARENT,
            can_handle = function(_, _, device) return device.st_store.model == PARENT end,
            lifecycle_handlers = {
                init = function(driver, device) ready:add(Parent(driver, device)) end,
                infoChanged = function(_, device, event, args) Adapter.call(device, INFO_CHANGED, event, args) end,
            },
            capability_handlers = Parent.capability_handlers,
        },
        {
            NAME = SWITCH,
            can_handle = function(_, _, device) return device.st_store.model == SWITCH end,
            lifecycle_handlers = {init = function(driver, device) ready:add(Switch(driver, device)) end},
            capability_handlers = Switch.capability_handlers,
        },
        {
            NAME = DIMMER,
            can_handle = function(_, _, device) return device.st_store.model == DIMMER end,
            lifecycle_handlers = {init = function(driver, device) ready:add(Dimmer(driver, device)) end},
            capability_handlers = Dimmer.capability_handlers,
        },
    },
})

driver:run()
