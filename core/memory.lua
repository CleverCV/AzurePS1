
local bit = require("bit")
local ffi = require("ffi")

local Memory = {}
Memory.__index = Memory

local RAM_SIZE = 2 * 1024 * 1024
local BIOS_SIZE = 512 * 1024
local SCRATCH_SIZE = 1024

local GPU_GP0 = 0x1F801810
local GPU_GP1 = 0x1F801814

function Memory.new()
    local self = setmetatable({}, Memory)

    self.ram = ffi.new("uint8_t[?]", RAM_SIZE)
    self.bios = ffi.new("uint8_t[?]", BIOS_SIZE)
    self.scratchpad = ffi.new("uint8_t[?]", SCRATCH_SIZE)

    self.bios_loaded = false
    self.gpu = nil

    return self
end

function Memory:setGPU(gpu)
    self.gpu = gpu
end

function Memory:translate(address)
    return bit.band(address, 0x1FFFFFFF)
end

function Memory:read8(address)
    address = self:translate(address)

    if address < 0x00800000 then
        return tonumber(self.ram[address % RAM_SIZE])
    end

    if address >= 0x1F800000
    and address < 0x1F800400 then
        return tonumber(self.scratchpad[address - 0x1F800000])
    end

    if address >= 0x1FC00000
    and address < 0x1FC80000 then
        return tonumber(self.bios[address - 0x1FC00000])
    end

    return 0
end

function Memory:read16(address)
    local a = self:read8(address)
    local b = self:read8(address + 1)

    return a + b * 256
end

function Memory:read32(address)
    address = self:translate(address)

    if self.gpu then
        if address == GPU_GP0 then
            return self.gpu:readGP0()
        elseif address == GPU_GP1 then
            return self.gpu:readGP1()
        end
    end

    local a = self:read16(address)
    local b = self:read16(address + 2)

    return a + b * 65536
end

function Memory:write8(address, value)
    address = self:translate(address)
    value = bit.band(value, 0xFF)

    if address < 0x00800000 then
        self.ram[address % RAM_SIZE] = value
        return
    end

    if address >= 0x1F800000
    and address < 0x1F800400 then
        self.scratchpad[address - 0x1F800000] = value
    end
end

function Memory:write16(address, value)
    self:write8(address, value)
    self:write8(address + 1, bit.rshift(value, 8))
end

function Memory:write32(address, value)
    address = self:translate(address)

    value = bit.tobit(value)

    if self.gpu then
        if address == GPU_GP0 then
            self.gpu:writeGP0(value)
            return
        elseif address == GPU_GP1 then
            self.gpu:writeGP1(value)
            return
        end
    end

    self:write16(address, bit.band(value, 0xFFFF))
    self:write16(address + 2, bit.rshift(value, 16))
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

return Memory
