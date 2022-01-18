local function new(class, ...)
    local self = setmetatable({}, class)
    class:_init(self, ...)
    return self
end

local function super(class)
    return getmetatable(class).__index
end

local function supers(class)
    return coroutine.wrap(function()
        for _, _super in ipairs(super(class)()) do
            coroutine.yield(_super)
        end
    end)
end

local function join(_supers)
    return function(class, key)
        if nil == key then
            return _supers
        end
        for _, _super in ipairs(_supers) do
            local value = _super[key]
            if nil ~= value then
                class[key] = value
                return value
            end
        end
    end
end

return {
    super = super,

    supers = supers,

    single = function(class, super_class)
        class.__index = class
        setmetatable(class, {
            __index = super_class,
            __call = new
        })
    end,

    multiple = function(class, ...)
        class.__index = class
        setmetatable(class, {
            __index = join{...},
            __call = new
        })
    end,

    error = function(class)
        class.__index = class
        setmetatable(class, {
            __call = function(_class, ...)
                error(setmetatable({...}, _class))
            end
        })
    end,
}