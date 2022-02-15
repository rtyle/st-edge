-- vim: ts=4:sw=4:expandtab

local cosock    = require "cosock"

local classify  = require "util.classify"
local Timer     = require "timer"

local Parent = classify.single({
    _init = function(_, self, name, latitude, longitude, height)
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
        self.timer = Timer(name, latitude, longitude, height)
        self.child = {}
        self.angle_methods = {}
    end,

    add = function(self, child)
        self.child[child] = true
        self.angle_methods[child.angle] = child.method
        self.timer:stop()
        self.timer = Timer(self.name, self.latitude, self.longitude, self.height, self.angle_methods)
    end,

    remove = function(self, child)
        self.child[child] = nil
        self.angle_methods[child.angle] = nil
        self.timer:stop()
        self.timer = Timer(self.name, self.latitude, self.longitude, self.height, self.angle_methods)
    end,
})

local Child = classify.single({
    _init = function(_, self, parent, angle)
        self.parent = parent
        self.angle = angle
        self.method = function(bool)
            print(angle, bool)
        end
        parent:add(self)
    end
})

local parent = Parent("LA", 34.052235, -118.243683, 0)

for angle, _ in pairs(Timer.angles) do
    Child(parent, angle)
end

cosock.run()