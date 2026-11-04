
local bit = require("bit")

local Interrupts = {}
Interrupts.__index = Interrupts

-- Interrupt source indexes
Interrupts.SOURCES = {
    VBLANK = 0,
    GPU = 1,
    CDROM = 2,
    DMA = 3,
    TIMER0 = 4,
    TIMER1 = 5,
    TIMER2 = 6,
    CONTROLLER = 7,
    SIO = 8,
    SPU = 9,
    PIO = 10
}

function Interrupts.new()
    return setmetatable({
        status = 0,
        mask = 0,
        pending = 0
    }, Interrupts)
end

function Interrupts:request(source)
    if source < 0 or source > 10 then
        return false
    end

    self.pending = bit.bor(
        self.pending,
        bit.lshift(1, source)
    )

    self:updateStatus()

    return true
end

function Interrupts:clear(source)
    if source < 0 or source > 10 then
        return false
    end

    self.pending = bit.band(
        self.pending,
        bit.bnot(bit.lshift(1, source))
    )

    self:updateStatus()

    return true
end

function Interrupts:setMask(mask)
    self.mask = bit.band(mask, 0x7FF)
    self:updateStatus()
end

function Interrupts:updateStatus()
    self.status = bit.band(
        self.pending,
        self.mask
    )
end

function Interrupts:isPending()
    self:updateStatus()
    return self.status ~= 0
end

function Interrupts:getStatus()
    self:updateStatus()
    return self.status
end

function Interrupts:getMask()
    return self.mask
end

function Interrupts:reset()
    self.status = 0
    self.mask = 0
    self.pending = 0
end

return Interrupts
