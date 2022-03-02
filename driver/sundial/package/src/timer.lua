-- vim: ts=4:sw=4:expandtab

local cosock    = require "cosock"
local log       = require "log"

local date      = require "date"
local suncalc   = require "suncalc"

local classify  = require "classify"

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
local NADIR     = "nadir"
local ZENITH    = "solarNoon"

local MORNING   = "morning"

local DAY       = 24 * 60 * 60

-- set of angles explicit in suncalc.times and implied by suncalc.getTimes results
local angles = {[MORNING] = true}
for _, angle__ in ipairs(suncalc.times) do
    local angle, _, _ = table.unpack(angle__)
    angles[angle] = true
end

-- A Timer is like a 24 hour mechanical timer with settable on and off trippers.
-- Instead of many trippers controlling one switch during the hours of each day,
-- independent on/off pairs of trippers are set for solar angles.
return classify.single({
    -- export class constants
    MORNING = MORNING,
    angles  = angles,

    -- angle_method is a set of solar angles, each of which is associated with a method.
    -- for a numeric angle,
    -- method(true ) is called when we trip on this solar altitude relative to dawn.
    -- method(false) is called when we trip on this solar altitude relative to dusk.
    -- for a string angle of MORNING,
    -- method(true ) is called when we trip on the nadir  azimuth angle (-180) and
    -- method(false) is called when we trip on the zenith azimuth angle (0).
    -- a self.refresh_method table is maintained to support our refresh method
    -- at which time one or all methods will be called/refreshed.
    _init = function(_, self, name, latitude, longitude, height, angle_method)
        latitude        = latitude      or 0
        longitude       = longitude     or 0
        height          = height        or 0
        angle_method    = angle_method  or {}

        local empty = nil == next(angle_method)
        log.debug("timer", name, "init", latitude, longitude, height, not empty)
        if empty then return end

        -- for refresh()
        self.refresh_method = {}

        -- for stop()
        local sender, receiver = cosock.channel.new()
        self.sender = sender

        self.run = true -- stop() sets it to false

        -- construct times from angle_method
        local morning_method
        local times = {}
        for angle, method in pairs(angle_method) do
            local number = tonumber(angle)
            if number then
                assert(-90 <= number and number <= 90, "solar altitude angle range error: " .. number)
                -- angle, dawn key, dusk key
                table.insert(times, {angle, {angle, method, 2}, {angle, method, 3}})
            else
                assert(MORNING == angle, "solar azimuth angle range error: " .. angle)
                morning_method = method
            end
        end
        local nadir  = {MORNING, morning_method, 2}
        local zenith = {MORNING, morning_method, 3}

        local ordered_next_times

        local function get_times()
            local this_time = epoch_time()

            -- get non-empty set of next_times that are no smaller than this_time
            local suncalc_get_times
            local next_time = this_time
            local next_times
            while true do
                suncalc_get_times = suncalc.getTimes(next_time, latitude, longitude, height, times)

                -- rewrite suncalc_get_times as next_times using our keys
                -- and find the latest_time
                next_times = {}
                local latest_time = this_time - 1
                for key, time in pairs(suncalc_get_times) do
                    if time ~= time then    -- NaN (there is no time for this key)
                        time = 0            -- fabricate to sort in the past, may change this later
                    end
                    latest_time = math.max(latest_time, time)
                    if "table" == type(key) then
                        next_times[key] = time
                    else
                        -- replace suncalc NADIR/ZENITH with our nadir/zenith
                        if morning_method then
                            if NADIR == key then
                                next_times[nadir ] = time
                            elseif ZENITH == key then
                                next_times[zenith] = time
                            end
                        end
                    end
                end

                if this_time <= latest_time then break end

                -- this_time > latest_time
                -- try again with next_time a day after this zenith
                next_time = suncalc_get_times[ZENITH] + DAY
            end

            -- split/order next_times relative to this_time
            ordered_next_times = {}
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
                log.debug("timer", name, ">", local_iso_time(time), angle, 2 == index)
            end
            log.debug("timer", name, "-", local_iso_time(this_time))
            for _, value in ipairs(ordered_next_times) do
                local time, key = table.unpack(value)
                local angle, _, index = table.unpack(key)
                log.debug("timer", name, "<", local_iso_time(time), angle, 2 == index)
            end

            -- build self.refresh_method set indexed by method,
            -- each of which is associated with a dawn, dusk time pair
            -- self:refresh will call method(true) when the current time is between these;
            -- otherwise it will call method(false).
            self.refresh_method = {}
            for key, time in pairs(next_times) do
                local angle, method, index = table.unpack(key)
                local array = self.refresh_method[method]
                if not array then
                    array = {angle}
                    self.refresh_method[method] = array
                end
                array[index] = time
            end
            -- for angles for which there was no dusk time today, we have said that time was before today (0) so
            -- self:refresh will call method(false) all day.
            -- if the mean solar position is greater than such an angle, say its dusk time is after today so
            -- self:refresh will call method(true ) all day.
            local mean = nil
            for method, angle_dawn_dusk in pairs(self.refresh_method) do
                local angle, dawn, dusk = table.unpack(angle_dawn_dusk)
                if 0 == dusk then
                    if not mean then
                        mean = (
                            suncalc.getPosition(suncalc_get_times[NADIR ], latitude, longitude).altitude +
                            suncalc.getPosition(suncalc_get_times[ZENITH], latitude, longitude).altitude
                        ) / 2
                    end
                    if (angle < mean) then
                        dusk = next_time + DAY  -- self:refresh will call method(true) all day
                    end
                end
                self.refresh_method[method] = {dawn, dusk}
            end
        end

        -- populate self.refresh_method before we spawn our timer thread
        -- so that refresh can be called immediately
        get_times()

        -- timer thread
        cosock.spawn(function()
            log.debug("timer", name, "start")

            while self.run do
                if 0 == #ordered_next_times then
                    -- wait for a half day
                    local timeout = DAY / 2
                    local time = epoch_time() + timeout
                    log.debug("timer", name, "wait", local_iso_time(time), "-", "-", delta_time(timeout))
                    cosock.socket.select({receiver}, {}, timeout)
                else
                    -- wait for each ordered next time for the rest of today
                    while self.run and 0 < #ordered_next_times do
                        local time, key = table.unpack(table.remove(ordered_next_times, 1))
                        local angle, method, index = table.unpack(key)
                        local dawn = 2 == index
                        local timeout = math.max(0, time - epoch_time())
                        log.debug("timer", name, "wait", local_iso_time(time), angle, dawn, delta_time(timeout))
                        if not cosock.socket.select({receiver}, {}, timeout) then
                            log.debug("timer", name, "trip", local_iso_time(epoch_time()), angle, dawn)
                            method(dawn)
                        end
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
                    method(dawn <= time and time < dusk)
                end
            else
                for each_method, dawn_dusk in pairs(self.refresh_method) do
                    local dawn, dusk = table.unpack(dawn_dusk)
                    each_method(dawn <= time and time < dusk)
                end
            end
        end
    end,
})
