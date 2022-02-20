-- vim: ts=4:sw=4:expandtab

-- require st provided libraries
local capabilities  = require "st.capabilities"
local Driver        = require "st.driver"
local log           = require "log"

local Timer         = require "timer"

local classify      = require "util.classify"
local Semaphore     = require "util.semaphore"

-- device models/types, sub_drivers
local PARENT        = "parent"
local CHILD         = "child"

-- Adapter callback support from device
local ADAPTER       = "adapter"
local INFO_CHANGED  = "info_changed"
local REFRESH       = "refresh"
local REMOVED       = "removed"

local LABEL         = "Sundial"

-- although we are not technically a LAN driver,
-- that is what try_create_device requires at this time.
-- so, each device that we create must have a unique device_network_id.
-- to this end, we use a NAMESPACE (uuid) as a prefix in each device_network_id.
-- uuid -v5 ns:URL https://github.com/rtyle/st-edge/driver/sundial
local NAMESPACE     = "9db4ad4d-85e7-534a-a204-045d9bce50c4"

local Parent, Child

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
        local pending_use = self.pending[device_network_id]
        if pending_use then
            for _, use in ipairs(pending_use) do
                use(adapter)
            end
            self.pending[device_network_id] = nil
        end
        try_create_device_semaphore:release()
    end,

    remove = function(self, device_network_id)
        self.adapter[device_network_id] = nil
    end,

    acquire = function(self, device_network_id, use)
        local adapter = self.adapter[device_network_id]
        if adapter then
            use(adapter)
            return
        end
        local pending_use = self.pending[device_network_id]
        if pending_use then
            table.insert(pending_use, use)
        else
            self.pending[device_network_id] = {use}
        end
    end,
}

local Adapter = classify.single({
    _init = function(_, self, driver, device)
        log.debug("init", device.device_network_id, device.st_store.label)
        self.driver = driver
        self.device = device
        device:set_field(ADAPTER, self)
    end,

    removed = function(self)
        local device = self.device
        self.device:set_field(ADAPTER, nil)
        self.device = nil
        self.driver = nil
        log.debug("removed", device.device_network_id, device.st_store.label)
        return device.device_network_id
    end,

    call = function(device, method, ...)
        local adapter = device:get_field(ADAPTER)
        if adapter then
            return adapter[method](adapter, ...)
        end
    end,

    refresh = function(self)
        log.debug("refresh", self.device.device_network_id, self.device.st_store.label)
        self.device:online()
    end,

    create = function(driver, device_network_id, model, label, parent_device_id)
        log.debug("create?", device_network_id, model, label, parent_device_id)
        try_create_device_semaphore:acquire(function()
            log.debug("create!", device_network_id, model, label, parent_device_id)
            driver:try_create_device{
                type = "LAN",
                device_network_id = device_network_id,
                label = label,
                profile = model,
                manufacturer = "rtyle",
                model = model,
                parent_device_id = parent_device_id,
            }
        end)
        return device_network_id
    end
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

Parent = classify.single({
    list = {},

    start = function(self)
        self.timer = Timer(
            self.index,
            self.device.st_store.preferences.latitude,
            self.device.st_store.preferences.longitude,
            self.device.st_store.preferences.height,
            self.angle_method
        )
    end,

    stop = function(self)
        self.timer:stop()
        self.timer = nil
    end,

    restart = function(self)
        self:stop()
        self:start()
    end,

    _init = function(class, self, driver, device)
        classify.super(class):_init(self, driver, device)
        local it = device.device_network_id:gmatch("%S+")
        it()
        self.index = tonumber(it())
        Parent.list[self.index] = self
        self.angle_method = {}
        self:start()
    end,

    removed = function(self)
        self:stop()
        self.angle_method = nil
        Parent.list[self.index] = nil
        self.index = nil
        return Adapter.removed(self)
    end,

    info_changed = function(self, event, _)
        log.debug("info", self.device.device_network_id, self.device.st_store.label, event)
        self:restart()
        self:refresh()
        local angle = self.device.st_store.preferences.angle:lower()
        if not self.angle_method[angle] then
            local number = tonumber(angle)
            if Timer.MORNING == angle or (number and -90 <= number and number <= 90) then
                Child.create(self.driver, self, angle)
            else
                log.warn("info", self.device.device_network_id, self.device.st_store.label, "angle", angle)
            end
        end
        if self.device.st_store.preferences.sundial then
            Parent.create(self.driver)
        end
    end,

    angle_method_add = function(self, angle, method)
        self.angle_method[angle] = method
        self:restart()
    end,

    angle_method_remove = function(self, angle)
        -- Parent is removed before each Child is removed.
        -- guard against accessing destroyed Parent resources when Child calls this
        if self.angle_method then
            self.angle_method[angle] = nil
            self:restart()
        end
    end,

    refresh = function(self, angle)
        Adapter.refresh(self)
        self.timer:refresh(self.angle_method[angle])
    end,

    create = function(driver)
        local index = #Parent.list + 1
        Parent.list[index] = false  -- placeholder until init'ed
        ready:acquire(
            Adapter.create(driver,
                table.concat({NAMESPACE, index}, "\t"),
                PARENT,
                table.concat({LABEL, index}, " ")),
            function(parent)
                for angle, _ in pairs(Timer.angles) do
                    Child.create(driver, parent, angle)
                end
            end
        )
    end,

    capability_handlers = {
        [capabilities.refresh.ID] = Adapter.capability_handlers[capabilities.refresh.ID],
    },
}, Adapter)

Child = classify.single({
    _init = function(class, self, driver, device)
        classify.super(class):_init(self, driver, device)
        local it = device.device_network_id:gmatch("%S+")
        local parent_device_network_id = table.concat({it(), it()}, "\t")
        self.angle = it()
        ready:acquire(parent_device_network_id, function(parent)
            self.parent = parent
            self.parent:angle_method_add(self.angle, function(dawn)
                if dawn then
                    self.device:emit_event(capabilities.presenceSensor.presence.present())
                else
                    self.device:emit_event(capabilities.presenceSensor.presence.not_present())
                end
            end)
            self:refresh()
        end)
    end,

    removed = function(self)
        self.parent:angle_method_remove(self.angle)
        self.parent = nil
        self.angle = nil
        return Adapter.removed(self)
    end,

    refresh = function(self)
        Adapter.refresh(self)
        self.parent:refresh(self.angle)
    end,

    create = function(driver, parent, angle)
        Adapter.create(driver,
            table.concat({NAMESPACE, parent.index, angle}, "\t"),
            CHILD,
            table.concat({LABEL, parent.index, angle}, " "),
            parent.device.id)
    end,

    capability_handlers = {
        [capabilities.refresh.ID] = Adapter.capability_handlers[capabilities.refresh.ID],
    },
}, Adapter)

local driver = Driver("sundial", {

    discovery = function(driver, _, _)
        log.debug("discovery", #Parent.list)
        if 0 == #Parent.list then
            Parent.create(driver)
        end
    end,

    lifecycle_handlers = {
        removed = function(_, device) ready:remove(Adapter.call(device, REMOVED)) end,
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
            NAME = CHILD,
            can_handle = function(_, _, device) return device.st_store.model == CHILD end,
            lifecycle_handlers = {
                init = function(driver, device) ready:add(Child(driver, device)) end,
            },
            capability_handlers = Child.capability_handlers,
        },
    },
})

driver:run()
