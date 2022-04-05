-- vim: ts=4:sw=4:expandtab

-- https://en.wikipedia.org/wiki/Wake-on-LAN

-- require st provided libraries
local capabilities  = require "st.capabilities"
local cosock        = require "cosock"
local Driver        = require "st.driver"
local log           = require "log"

local classify      = require "classify"

-- device models/types, sub_drivers
local PARENT        = "bridge"
local CHILD         = "switch"

-- Adapter callback support from device
local ADAPTER       = "adapter"
local INFO_CHANGED  = "info_changed"
local PUSH          = "push"
local REMOVED       = "removed"

local LABEL         = "Wake-on-LAN"

-- uuid -v5 ns:URL https://github.com/rtyle/st-edge/driver/wake-on-lan
local NAMESPACE     = "72e034da-6376-518f-ae42-a52d3f7cdf1a"

local Adapter = classify.single({
    _init = function(_, self, driver, device)
        log.debug("init", device.device_network_id)
        self.driver = driver
        self.device = device
        device:set_field(ADAPTER, self)
    end,

    removed = function(self)
        local device = self.device
        self.device:set_field(ADAPTER, nil)
        self.device = nil
        self.driver = nil
        log.debug("removed", device.device_network_id)
        return device.device_network_id
    end,

    call = function(device, method, ...)
        local adapter = device:get_field(ADAPTER)
        if adapter then
            return adapter[method](adapter, ...)
        end
    end,

    create = function(driver, device_network_id, model, label, parent_device_id)
        log.debug("create", device_network_id, model, label, parent_device_id)
        driver:try_create_device{
            type = "LAN",
            device_network_id = device_network_id,
            label = label,
            profile = model,
            manufacturer = "rtyle",
            model = model,
            parent_device_id = parent_device_id,
        }
    end
})

-- encode hexadecimal string into encoded numeric bytes
local function encode(decoded)
    local encoded = {}
    for decode in decoded:gmatch("%x%x") do
        table.insert(encoded, tonumber(decode, 16))
    end
    return string.pack("BBBBBB", table.unpack(encoded))
end

local parent, Child

local Parent = classify.single({
    _init = function(class, self, driver, device)
        classify.super(class):_init(self, driver, device)
        parent = self
        -- create socket for UDP broadcast to discard port (9)
        self.socket = cosock.socket.udp()
        self.socket:setoption("broadcast", true)
        self.socket:setpeername("255.255.255.255", 9)
        self.prefix = encode("ffffffffffff")
    end,

    removed = function(self)
        self.prefix = nil
        self.socket:close()
        self.socket = nil
        parent = nil
        return Adapter.removed(self)
    end,

    info_changed = function(self, event, _)
        log.debug("info", self.device.device_network_id, event)
        Child.create(self.driver, self, self.device.st_store.preferences.address:lower())
    end,

    wake = function(self, address, password)
        local packet = {self.prefix}
        for _ = 1, 16 do
            table.insert(packet, address)
        end
        table.insert(packet, password)
        self.socket:send(table.concat(packet))
    end,

    create = function(driver)
        Adapter.create(driver, NAMESPACE, PARENT, LABEL)
    end,
}, Adapter)

Child = classify.single({
    _init = function(class, self, driver, device)
        classify.super(class):_init(self, driver, device)
        self.address = encode(device.device_network_id:match("%s(%x+)"))
    end,

    removed = function(self)
        self.address = nil
        return Adapter.removed(self)
    end,

    info_changed = function(self, event, _)
        log.debug("info", self.device.device_network_id, event)
        self.password = encode(self.device.st_store.preferences.password)
    end,

    push = function(self)
        log.debug("push", self.device.device_network_id)
        if parent then
            parent:wake(self.address, self.password)
        end
    end,

    create = function(driver, _parent, address)
        Adapter.create(driver,
            table.concat({parent.device.device_network_id, address}, "\t"),
            CHILD,
            table.concat({LABEL, address}, " "),
            _parent.device.id)
    end,

    capability_handlers = {
        [capabilities.momentary.ID] = {
            [capabilities.momentary.commands.push.NAME] = function(_, device)
                Adapter.call(device, PUSH)
            end,
        },
    },
}, Adapter)

Driver("WoL", {
    discovery = function(driver, _, _)
        log.debug("discovery")
        if nil == parent then
            Parent.create(driver)
        end
    end,

    lifecycle_handlers = {
        removed = function(_, device) Adapter.call(device, REMOVED) end,
        infoChanged = function(_, device, event, args) Adapter.call(device, INFO_CHANGED, event, args) end,
    },

    sub_drivers = {
        {
            NAME = PARENT,
            can_handle = function(_, _, device) return device.st_store.model == PARENT end,
            lifecycle_handlers = {
                init = function(driver, device) Parent(driver, device) end,
            },
        },
        {
            NAME = CHILD,
            can_handle = function(_, _, device) return device.st_store.model == CHILD end,
            lifecycle_handlers = {
                init = function(driver, device) Child(driver, device) end,
            },
            capability_handlers = Child.capability_handlers,
        },
    },
}):run()
