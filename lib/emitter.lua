local classify = require "util.classify"

-- Event emitter pattern implementation.
return classify.single({

    -- Once forwards an emission once.
   Once = classify.single({
        EVENT_NIL = {},

        _init = function(_, self, emitter, event, handler)
            self._closure = function(...)
                self:_forward(emitter, event, handler, ...)
            end
            emitter:on(event, self._closure)
        end,

        _forward = function(self, emitter, event, handler, ...)
            emitter:off(event, self._closure)
            if event ~= self.EVENT_NIL then
                handler(...)
            end
        end,
    }),

    _init = function(class, self)
        self.Emitter = class
        self._handlers = {}
    end,

    on = function(self, event, handler)
        local event_handlers = self._handlers[event]
        if event_handlers then
            event_handlers[handler] = true
        else
            self._handlers[event] = {[handler] = true}
        end
    end,

    off = function(self, event, handler)
        local event_handlers = self._handlers[event]
        if event_handlers then
            event_handlers[handler] = nil
        end
    end,

    once = function(self, event, handler)
        self.Once(self, event, handler)
    end,

    emit = function(self, event, ...)
        local event_handlers = self._handlers[event]
        if event_handlers then
            -- iterate over a copy so that a handler may change event_handlers
            local event_handlers_copy = {}
            for handler, _ in pairs(event_handlers) do
                table.insert(event_handlers_copy, handler)
            end
            for _, handler in ipairs(event_handlers_copy) do
                handler(...)
            end
        end
    end,
})
