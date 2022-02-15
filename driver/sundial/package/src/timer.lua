local cosock    = require "cosock"
local log       = require "log"

local date      = require "date"
local suncalc   = require "suncalc"

local classify  = require "util.classify"

local function epoch_time()
    return date.diff(date(true), date.epoch()):spanseconds()
end

local function local_iso_time(time)
    return date(time):tolocal():fmt("${iso}")
end

local function delta_time(time)
    return date(time):fmt("%T")
end

-- suncalc.getTimes() results always include these
local NADIR_KEY     = "nadir"
local ZENITH_KEY     = "solarNoon"
local NADIR_ANGLE   = -90
local ZENITH_ANGLE  = 90

-- set of angles explicit in suncalc.times and implied by suncalc.getTimes results
local angles = {[ZENITH_ANGLE] = true}
for _, angle__ in ipairs(suncalc.times) do
    local angle, _, _ = table.unpack(angle__)
    angles[angle] = true
end

-- A Timer is like a 24 hour mechanical timer with settable on and off trippers.
-- Instead of many trippers controlling one switch during the hours of each day,
-- independent on/off pairs of trippers are made for solar angles relative to the horizon.
return classify.single({
    angles = angles,    -- export

    -- angle_method is a set of angles, each of which is associated with a method.
    -- method(true ) is called when we trip on the angle relative to dawn.
    -- method(false) is called when we trip on the angle relative to dusk.
    -- for an angle of -90 or 90,
    -- method(true ) is called when we trip on the nadir  angle and
    -- method(false) is called when we trip on the zenith angle.
    -- a self.refresh_method table is maintained to support our refresh method
    -- at which time one or all methods will be called/refreshed.
    _init = function(_, self, name, latitude, longitude, height, angle_method)
        latitude        = latitude      or 0
        longitude       = longitude     or 0
        height          = height        or 0
        angle_method    = angle_method  or {}

        local empty = nil == next(angle_method)
        log.debug("timer", name, latitude, longitude, height, not empty)
        if empty then return end

        -- for refresh()
        self.refresh_method = {}

        -- for stop()
        local sender, receiver = cosock.channel.new()
        self.sender = sender

        self.run = true -- stop() sets it to false

        -- construct times from angle_method
        local nadir_zenith_method
        local times = {}
        for angle, method in pairs(angle_method) do
            assert(-90 <= angle and angle <= 90, "angle range error: " .. angle)
            if NADIR_ANGLE == angle or ZENITH_ANGLE == angle then
                nadir_zenith_method = method
            else
                -- angle, dawn key, dusk key
                table.insert(times, {angle, {angle, method, 1}, {angle, method, 2}})
            end
        end
        local nadir_key  = {NADIR_ANGLE , nadir_zenith_method, 1}
        local zenith_key = {ZENITH_ANGLE, nadir_zenith_method, 2}

        local ordered_next_times = {}

        local function get_times()
            local this_time = epoch_time()

            -- get non-empty set of next_times that are no smaller than this_time
            local next_time = this_time
            local next_times
            while true do
                local suncalc_get_times = suncalc.getTimes(next_time, latitude, longitude, height, times)

                -- rewrite suncalc_get_times as next_times using our keys
                -- and find the latest_time
                next_times = {}
                local latest_time = this_time - 1
                for key, time in pairs(suncalc_get_times) do
                    latest_time = math.max(latest_time, time)
                    if "table" == type(key) then
                        next_times[key] = time
                    else
                        -- replace suncalc NADIR_KEY/ZENITH_KEY with our nadir_key/zenith_key
                        if nadir_zenith_method then
                            if NADIR_KEY == key then
                                next_times[nadir_key ] = time
                            elseif ZENITH_KEY == key then
                                next_times[zenith_key] = time
                            end
                        end
                    end
                end

                if this_time <= latest_time then break end

                -- this_time > latest_time
                -- try again with next_time a day after this zenith
                next_time = suncalc_get_times[ZENITH_KEY] + 24 * 60 * 60
            end

            -- split/order next_times relative to this_time
            local ordered_past_times = {}
            for key, time in pairs(next_times) do
                if this_time > time then
                    table.insert(ordered_past_times, {time, key})
                else
                    table.insert(ordered_next_times, {time, key})
                end
            end
            table.sort(ordered_past_times, function(a, b) return a[1] < b[1] end)
            table.sort(ordered_next_times, function(a, b) return a[1] < b[1] end)

            -- log
            for _, value in ipairs(ordered_past_times) do
                local time, key = table.unpack(value)
                local angle, _, index = table.unpack(key)
                log.debug("timer", name, ">", local_iso_time(time), angle, 1 == index)
            end
            log.debug("timer", name, "-", local_iso_time(this_time))
            for _, value in ipairs(ordered_next_times) do
                local time, key = table.unpack(value)
                local angle, _, index = table.unpack(key)
                log.debug("timer", name, "<", local_iso_time(time), angle, 1 == index)
            end

            -- build self.refresh_method set indexed by method,
            -- each of which is associated with a dawn, dusk time pair
            self.refresh_method = {}
            for key, time in pairs(next_times) do
                local _, method, index = table.unpack(key)
                local array = self.refresh_method[method]
                if not array then
                    array = {}
                    self.refresh_method[method] = array
                end
                array[index] = time
            end
        end

        -- populate self.refresh_method before we spawn our timer thread
        -- so that refresh can be called immediately
        get_times()

        -- timer thread
        cosock.spawn(function()
            log.debug("timer", name, "start")

            while self.run do
                while self.run and 0 < #ordered_next_times do
                    local time, key = table.unpack(table.remove(ordered_next_times, 1))
                    local angle, method, index = table.unpack(key)
                    local dawn = 1 == index
		            local timeout = math.max(0, time - epoch_time())
                    log.debug("timer", name, "wait", local_iso_time(time), angle, dawn, delta_time(timeout))
                    if not cosock.socket.select({receiver}, {}, timeout) then
                        log.debug("timer", name, "trip", local_iso_time(epoch_time()), angle, dawn)
                        method(dawn)
                    end
                end
                if self.run then
                    get_times()
                end
            end

            log.debug("timer", name, "stop")
        end, name)
    end,

    stop = function(self)
        if self.sender then
            self.run = false
            self.sender:send(0)
        end
    end,

    refresh = function(self, method)
        if self.refresh_method then
            local time = epoch_time()
            if method then
                local dawn_dusk = self.refresh_method[method]
                if dawn_dusk then
                    local dawn, dusk = table.unpack(dawn_dusk)
                    method(time >= dawn and time < dusk)
                end
            else
                for each_method, dawn_dusk in pairs(self.refresh_method) do
                    local dawn, dusk = table.unpack(dawn_dusk)
                    each_method(time >= dawn and time < dusk)
                end
            end
        end
    end,
})
