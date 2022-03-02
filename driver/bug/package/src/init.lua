-- vim: ts=4:sw=4:expandtab

-- require st provided libraries
local Driver        = require "st.driver"
local log           = require "log"

local classify      = require "classify"
local Semaphore     = require "semaphore"

-- device models/types, sub_drivers
local PARENT        = "parent"
local CHILD         = "child"

-- Adapter callback support from device
local ADAPTER       = "adapter"
local REMOVED       = "removed"

local LABEL         = "Bug"

-- although we are not technically a LAN driver,
-- that is what try_create_device requires at this time.
-- so, each device that we create must have a unique device_network_id.
-- to this end, we use a NAMESPACE (uuid) as a prefix in each device_network_id.
-- uuid -v5 ns:URL https://github.com/rtyle/st-edge/driver/bug
local NAMESPACE     = "a455007a-daf1-51d4-b36c-1b5e6dc9ac5f"

local Parent, Child

-- use a binary Semaphore to serialize access to driver:try_create_device() calls;
-- otherwise, these requests tend to get ignored or not completed through lifecycle init.
local try_create_device_semaphore = Semaphore(100)

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
        self.device = device
        device:set_field(ADAPTER, self)
    end,

    removed = function(self)
        local device = self.device
        self.device:set_field(ADAPTER, nil)
        self.device = nil
        log.debug("removed", device.device_network_id, device.st_store.label)
        return device.device_network_id
    end,

    call = function(device, method, ...)
        local adapter = device:get_field(ADAPTER)
        if adapter then
            return adapter[method](adapter, ...)
        end
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

Parent = classify.single({
    create = function(driver)
        ready:acquire(
            Adapter.create(driver,
                NAMESPACE,
                PARENT,
                LABEL),
            function(parent)
                for index = 1, 100 do
                    Child.create(driver, parent, index)
                end
            end
        )
    end,
}, Adapter)

Child = classify.single({
    create = function(driver, parent, index)
        Adapter.create(driver,
            table.concat({NAMESPACE, index}, "\t"),
            CHILD,
            table.concat({LABEL, index}, " "),
            parent.device.id)
    end,
}, Adapter)

local driver = Driver("bug", {

    discovery = function(driver, _, _)
        local devices = driver:get_devices()
        log.debug("discovery", #devices)
        if 0 == #devices then
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
            },
        },
        {
            NAME = CHILD,
            can_handle = function(_, _, device) return device.st_store.model == CHILD end,
            lifecycle_handlers = {
                init = function(driver, device) ready:add(Child(driver, device)) end,
            },
        },
    },
})

driver:run()
