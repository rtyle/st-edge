-- vim: ts=4:sw=4:expandtab

-- require st provided libraries
local cosock        = require "cosock"
local Driver        = require "st.driver"
local log           = require "log"

local classify      = require "classify"
local Semaphore     = require "semaphore"

local denon         = require "denon"
local UPnP          = require "upnp"

-- device models/types, sub_drivers
local PARENT        = "avr"
local CHILD         = "zone"

-- Adapter callback support from device
local ADAPTER       = "adapter"
local REMOVED       = "removed"

local LABEL         = "AVR"

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

local Child
local upnp = UPnP()

local Parent = classify.multiple({
    _init = function(_, self, driver, device)
        Adapter:_init(self, driver, device)
        denon.AVR:_init(self, device.device_network_id, upnp)
    end,

    create = function(driver, device_network_id)
        ready:acquire(
            Adapter.create(driver,
                device_network_id,
                PARENT,
                LABEL),
            function(parent)
                for _, zone in ipairs{"MainZone", "Zone2", "Zone3"} do
                    Child.create(driver, parent, zone)
                end
            end
        )
    end,
}, Adapter, denon.AVR)

Child = classify.single({
    _init = function(class, self, driver, device)
        classify.super(class):_init(self, driver, device)
        local it = device.device_network_id:gmatch("%S+")
        local parent_device_network_id = it()
        self.zone = it()
        ready:acquire(parent_device_network_id, function(parent)
            self.parent = parent
        end)
    end,

    create = function(driver, parent, zone)
        Adapter.create(driver,
            table.concat({parent.device.device_network_id, zone}, "\t"),
            CHILD,
            table.concat({LABEL, zone}, " "),
            parent.device.id)
    end,
}, Adapter)

local driver = Driver("denon-avr", {
    lan_info_changed_handler = function(_)
        -- TODO: UPnP eventing update for new address
    end,

    discovery = function(driver, _, should_continue)
        local function found(address, port, header, device)
            local device_network_id = header.usn.uuid
            log.debug("found", device_network_id, address, port, header.location, device.friendlyName)
            local adapter = ready.adapter[device_network_id]
            if not adapter then
                Parent.create(driver, device_network_id)
            end
        end

        local discover = denon.Discover(upnp, found)

        while should_continue() do
            discover:search()
            cosock.socket.sleep(8)
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
