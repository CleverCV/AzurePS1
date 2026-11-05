
local bit = require("bit")
local ffi = require("ffi")

local Memory = {}
Memory.__index = Memory

local RAM_SIZE = 2 * 1024 * 1024
local BIOS_SIZE = 512 * 1024
local SCRATCH_SIZE = 1024
local RAM_MIRROR_SIZE = 8 * 1024 * 1024

local GPU_GP0 = 0x1F801810
local GPU_GP1 = 0x1F801814
local I_STAT = 0x1F801070
local I_MASK = 0x1F801074

local SPU_BASE = 0x1F801C00
local SPU_END = 0x1F801E00

local function u32(value)
    return bit.tobit(value)
end

local function u8(value)
    return bit.band(value, 0xFF)
end

local function u16(value)
    return bit.band(value, 0xFFFF)
end

function Memory.new()
    local self = setmetatable({}, Memory)

    self.ram = ffi.new("uint8_t[?]", RAM_SIZE)
    self.bios = ffi.new("uint8_t[?]", BIOS_SIZE)
    self.scratchpad = ffi.new("uint8_t[?]", SCRATCH_SIZE)

    self.bios_loaded = false
    self.gpu = nil
    self.spu = nil
    self.interrupts = nil

    return self
end

function Memory:setGPU(gpu)
    self.gpu = gpu
end

function Memory:setSPU(spu)
    self.spu = spu
end

function Memory:setInterrupts(interrupts)
    self.interrupts = interrupts
end

function Memory:translate(address)
    return bit.band(address, 0x1FFFFFFF)
end

function Memory:readPhysical8(address)
    address = self:translate(address)

    if address < RAM_MIRROR_SIZE then
        return tonumber(self.ram[address % RAM_SIZE])
    end

    if address >= 0x1F800000 and address < 0x1F800400 then
        return tonumber(self.scratchpad[address - 0x1F800000])
    end

    if address >= 0x1FC00000 and address < 0x1FC80000 then
        return tonumber(self.bios[address - 0x1FC00000])
    end

    if address >= I_STAT and address < I_STAT + 4 then
        local pending = self.interrupts and self.interrupts.pending or 0
        return bit.band(
            bit.rshift(pending, (address - I_STAT) * 8),
            0xFF
        )
    end

    if address >= I_MASK and address < I_MASK + 4 then
        local mask = self.interrupts and self.interrupts.mask or 0
        return bit.band(
            bit.rshift(mask, (address - I_MASK) * 8),
            0xFF
        )
    end

    return 0
end

function Memory:read8(address)
    address = self:translate(address)

    if address >= SPU_BASE and address < SPU_END and self.spu then
        local aligned = bit.band(address - SPU_BASE, 0x1FE)
        local value = self.spu:readRegister(aligned)
        if bit.band(address, 1) == 0 then
            return bit.band(value, 0xFF)
        end
        return bit.band(bit.rshift(value, 8), 0xFF)
    end

    return self:readPhysical8(address)
end

function Memory:read16(address)
    address = self:translate(address)

    if address >= SPU_BASE and address < SPU_END and self.spu then
        return self.spu:readRegister(address - SPU_BASE)
    end

    local a = self:readPhysical8(address)
    local b = self:readPhysical8(address + 1)

    return a + b * 0x100
end

function Memory:read32(address)
    address = self:translate(address)

    if self.gpu then
        if address == GPU_GP0 then
            return u32(self.gpu:readGP0())
        elseif address == GPU_GP1 then
            return u32(self.gpu:readGP1())
        end
    end

    if address == I_STAT then
        return u32(self.interrupts and self.interrupts.pending or 0)
    elseif address == I_MASK then
        return u32(self.interrupts and self.interrupts.mask or 0)
    end

    local a = self:readPhysical8(address)
    local b = self:readPhysical8(address + 1)
    local c = self:readPhysical8(address + 2)
    local d = self:readPhysical8(address + 3)

    return u32(
        a + b * 0x100 +
        c * 0x10000 + d * 0x1000000
    )
end

function Memory:writePhysical8(address, value)
    address = self:translate(address)
    value = u8(value)

    if address < RAM_MIRROR_SIZE then
        self.ram[address % RAM_SIZE] = value
        return
    end

    if address >= 0x1F800000 and address < 0x1F800400 then
        self.scratchpad[address - 0x1F800000] = value
        return
    end

    -- BIOS es de solo lectura.
end

function Memory:write8(address, value)
    address = self:translate(address)

    if address >= SPU_BASE and address < SPU_END and self.spu then
        local aligned = bit.band(address - SPU_BASE, 0x1FE)
        local old = self.spu:readRegister(aligned)

        if bit.band(address, 1) == 0 then
            self.spu:writeRegister(
                aligned,
                bit.bor(bit.band(old, 0xFF00), u8(value))
            )
        else
            self.spu:writeRegister(
                aligned,
                bit.bor(
                    bit.band(old, 0x00FF),
                    bit.lshift(u8(value), 8)
                )
            )
        end

        return
    end

    self:writePhysical8(address, value)
end

function Memory:write16(address, value)
    address = self:translate(address)
    value = u16(value)

    if address >= SPU_BASE and address < SPU_END and self.spu then
        self.spu:writeRegister(address - SPU_BASE, value)
        return
    end

    self:writePhysical8(address, value)
    self:writePhysical8(address + 1, bit.rshift(value, 8))
end

function Memory:write32(address, value)
    address = self:translate(address)
    value = u32(value)

    if self.gpu then
        if address == GPU_GP0 then
            self.gpu:writeGP0(value)
            return
        elseif address == GPU_GP1 then
            self.gpu:writeGP1(value)
            return
        end
    end

    if address == I_STAT then
        if self.interrupts then
            self.interrupts.pending = bit.band(
                self.interrupts.pending or 0,
                value
            )

            if self.interrupts.updateStatus then
                self.interrupts:updateStatus()
            end
        end
        return
    end

    if address == I_MASK then
        if self.interrupts then
            self.interrupts:setMask(bit.band(value, 0x7FF))
        end
        return
    end

    if address >= SPU_BASE and address < SPU_END and self.spu then
        self.spu:writeRegister(address - SPU_BASE, bit.band(value, 0xFFFF))
        self.spu:writeRegister(address - SPU_BASE + 2, bit.band(
            bit.rshift(value, 16), 0xFFFF
        ))
        return
    end

    self:writePhysical8(address, value)
    self:writePhysical8(address + 1, bit.rshift(value, 8))
    self:writePhysical8(address + 2, bit.rshift(value, 16))
    self:writePhysical8(address + 3, bit.rshift(value, 24))
end

function Memory:loadBIOS(data)
    if type(data) ~= "string" then
        return false, "BIOS data must be a string"
    end

    if #data ~= BIOS_SIZE then
        return false, "Invalid BIOS size: expected 512 KiB"
    end

    ffi.copy(self.bios, data, BIOS_SIZE)
    self.bios_loaded = true

    return true
end

function Memory:clearRAM()
    ffi.fill(self.ram, RAM_SIZE, 0)
end

function Memory:clearScratchpad()
    ffi.fill(self.scratchpad, SCRATCH_SIZE, 0)
end

function Memory:getRAMSize()
    return RAM_SIZE
end

function Memory:getBIOSSize()
    return BIOS_SIZE
end

return Memory
