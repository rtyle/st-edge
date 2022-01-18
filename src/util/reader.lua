local classify = require "util.classify"

-- Reader of spooled chunks from given read function.
local Reader = {

    _init = function(_, self, read)
        self._read = read
        self._queue = {}
    end,

    -- Dequeue spooled bytes up through "queue[i][j]"
    _dequeue = function(self, i, j)
        local queue = {}
        for _ = 1, i - 1 do
            table.insert(queue, table.remove(self._queue, 1))
        end
        local chunk = self._queue[1]
        if j < #chunk then
            table.insert(queue, chunk:sub(1, j))
            self._queue[1] = chunk:sub(j + 1)
        else
            table.insert(queue, chunk)
            table.remove(self._queue, 1)
        end
        return table.concat(queue)
    end,

    _pump_once = function(self)
        local whole, _error, part = self._read()
        if whole then
            table.insert(self._queue, whole)
        elseif part and 0 < #part then
            table.insert(self._queue, part)
        else
            error(_error, 0)
        end
    end,

    _read_exactly = function(self, length, i)
        if (i > #self._queue) then
            self:_pump_once()
        else
            local chunk_length = #self._queue[i]
            if length <= chunk_length then
                return self:_dequeue(i, length)
            end
            length = length - chunk_length
            i = i + 1
        end
        return self:_read_exactly(length, i)
    end,

    read_exactly = function(self, length)
        return self:_read_exactly(length, 1)
    end,

    _read_until = function(self, terminator, i)
        if (i > #self._queue) then
            self:_pump_once()
        else
            local chunk = self._queue[i]
            for j = 1, #chunk do
                if terminator == chunk:sub(j, j) then
                    return self:_dequeue(i, j)
                end
            end
            i = i + 1
        end
        return self:_read_until(terminator, i)
    end,

    read_until = function(self, terminator)
        assert(1 == #terminator)
        return self:_read_until(terminator, 1)
    end,
}

classify.single(Reader)

return Reader
