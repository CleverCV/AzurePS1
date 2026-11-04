local GTE = {}
GTE.__index = GTE

function GTE.new()
    local self = setmetatable({}, GTE)

    self.data = {}
    self.control = {}

    for i = 0, 31 do
        self.data[i] = 0
        self.control[i] = 0
    end

    self.cycles = 0

    return self
end

function GTE:readData(index)
    return self.data[index] or 0
end

function GTE:writeData(index, value)
    self.data[index] = value
end

function GTE:readControl(index)
    return self.control[index] or 0
end

function GTE:writeControl(index, value)
    self.control[index] = value
end

function GTE:execute(command)
    -- GTE instruction implementation will go here.
    -- RTPS, NCLIP, OP, MVMVA, etc.

    self.cycles = self.cycles + 1
end

return GTE