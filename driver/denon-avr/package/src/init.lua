-- vim: ts=4:sw=4:expandtab

-- require st provided libraries
local capabilities  = require "st.capabilities"
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
local MUTE          = "mute"
local POWER         = "power"
local REMOVED       = "removed"
local REFRESH       = "refresh"
local VOLUME        = "volume"
local VOLUME_STEP   = "volume_step"

local LOG           = "driver"

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
        log.debug(LOG, "init", device.device_network_id, device.st_store.label)
        self.driver = driver
        self.device = device
        device:set_field(ADAPTER, self)
    end,

    removed = function(self)
        local device = self.device
        self.device:set_field(ADAPTER, nil)
        self.device = nil
        self.driver = nil
        log.debug(LOG, "removed", device.device_network_id, device.st_store.label)
        return device.device_network_id
    end,

    notify_online = function(self, online)
        if online then
            self.device:online()
        else
            self.device:offline()
        end
    end,

    call = function(device, method, ...)
        local adapter = device:get_field(ADAPTER)
        if adapter then
            return adapter[method](adapter, ...)
        end
    end,

    create = function(driver, device_network_id, model, label, parent_device_id)
        log.debug(LOG, "create?", device_network_id, model, label, parent_device_id)
        try_create_device_semaphore:acquire(function()
            local adapter = ready.adapter[device_network_id]
            if adapter then
                try_create_device_semaphore:release()
            else
                log.debug(LOG, "create!", device_network_id, model, label, parent_device_id)
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
        end)
        return device_network_id
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

local Child
local upnp = UPnP()

local Parent = classify.single({
    _init = function(class, self, driver, device)
        classify.super(class):_init(self, driver, device)
        self.child = {}
        self.avr = denon.AVR(device.device_network_id, upnp,
            function(online)
                self:notify_online(online)
                for _, child in ipairs(self.child) do
                    child:notify_online(online)
                end
            end,
            function(zone, power, mute, volume, input)
                local child = self.child[zone]
                if child then
                    child:notify_refresh(power, mute, volume, input)
                end
            end,
            1
        )
    end,

    removed = function(self)
        self.avr:stop()
        self.avr = nil
        return Adapter.removed(self)
    end,

    refresh = function(self)
        self.avr:refresh()
    end,

    create = function(driver, device_network_id, label)
        ready:acquire(
            Adapter.create(driver,
                device_network_id,
                PARENT,
                label),
            function(parent)
                for _, zone in ipairs(parent.avr.ZONE) do
                    Child.create(driver, parent, label, zone)
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
        local parent_device_network_id = it()
        self.zone = it()
        ready:acquire(parent_device_network_id, function(parent)
            self.parent = parent
            parent.child[self.zone] = self
        end)
    end,

    removed = function(self)
        self.parent.child[self.zone] = nil
        self.parent = nil
        return Adapter.removed(self)
    end,

    notify_refresh = function(self, power, mute, volume, input)
        log.debug(LOG, self.device.device_network_id, "power"    , power)
        log.debug(LOG, self.device.device_network_id, "mute"     , mute)
        log.debug(LOG, self.device.device_network_id, "volume"   , volume)
        log.debug(LOG, self.device.device_network_id, "input"    , input)
        if power then
            self.device:emit_event(capabilities.switch.switch.on())
        else
            self.device:emit_event(capabilities.switch.switch.off())
        end
        if mute then
            self.device:emit_event(capabilities.audioMute.mute.muted())
        else
            self.device:emit_event(capabilities.audioMute.mute.unmuted())
        end
        if volume then
            self.device:emit_event(capabilities.audioVolume.volume(volume))
        else
            self.device:emit_event(capabilities.audioVolume.volume(volume))
        end
    end,

    refresh = function(self)
        self.parent.avr:refresh(self.zone)
    end,

    power = function(self, on)
        self.parent.avr:command_power(self.zone, on)
        self:refresh()
    end,

    mute = function(self, on)
        self.parent.avr:command_mute(self.zone, on)
        self:refresh()
    end,

    volume = function(self, volume)
        self.parent.avr:command_volume(self.zone, volume)
        self:refresh()
    end,

    volume_step = function(self, up)
        self.parent.avr:command_volume_step(self.zone, up)
        self:refresh()
    end,

    create = function(driver, parent, label, zone)
        Adapter.create(driver,
            table.concat({parent.device.device_network_id, zone}, "\t"),
            CHILD,
            table.concat({label, zone}, " "),
            parent.device.id)
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
        [capabilities.audioMute.ID] = {
            [capabilities.audioMute.commands.mute.NAME] = function(_, device)
                Adapter.call(device, MUTE, true)
            end,
            [capabilities.audioMute.commands.unmute.NAME] = function(_, device)
                Adapter.call(device, MUTE, false)
            end,
            [capabilities.audioMute.commands.setMute.NAME] = function(_, device, command)
                Adapter.call(device. MUTE, command.args.mute == "muted")
            end,
        },
        [capabilities.audioVolume.ID] = {
            [capabilities.audioVolume.commands.setVolume.NAME] = function(_, device, command)
                Adapter.call(device, VOLUME, command.args.volume)
            end,
            [capabilities.audioVolume.commands.volumeUp.NAME] = function(_, device)
                Adapter.call(device, VOLUME_STEP, true)
            end,
            [capabilities.audioVolume.commands.volumeDown.NAME] = function(_, device)
                Adapter.call(device, VOLUME_STEP, false)
            end,
        },
    },
}, Adapter)

Driver("denon-avr", {
    lan_info_changed_handler = function(_)
        -- our DHCP-leased IP address changed
        -- we must restart upnp services
        upnp:restart()
    end,

    discovery = function(driver, _, should_continue)
        local function find(_, _, header, device)
            Parent.create(driver, header.usn.uuid, device.friendlyName)
        end
        local discover = denon.Discover(upnp, find)
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
}):run()
