
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
    self.interrupts = nil

    return self
end

function Memory:setGPU(gpu)
    self.gpu = gpu
end

function Memory:setInterrupts(interrupts)
    self.interrupts = interrupts
end

function Memory:translate(address)
    -- Normaliza direcciones virtuales KUSEG, KSEG0 y KSEG1.
    -- La máscara física de PlayStation es 0x1FFFFFFF.
    return bit.band(address, 0x1FFFFFFF)
end

function Memory:readPhysical8(address)
    address = self:translate(address)

    -- RAM principal y sus espejos.
    if address < RAM_MIRROR_SIZE then
        return tonumber(self.ram[address % RAM_SIZE])
    end

    -- Scratchpad.
    if address >= 0x1F800000
    and address < 0x1F800400 then
        return tonumber(
            self.scratchpad[address - 0x1F800000]
        )
    end

    -- BIOS.
    if address >= 0x1FC00000
    and address < 0x1FC80000 then
        return tonumber(
            self.bios[address - 0x1FC00000]
        )
    end

    -- Registros de interrupciones.
    if address >= I_STAT and address < I_STAT + 4 then
        if self.interrupts then
            local pending = self.interrupts.pending or 0
            return bit.band(
                bit.rshift(pending, (address - I_STAT) * 8),
                0xFF
            )
        end
    end

    if address >= I_MASK and address < I_MASK + 4 then
        if self.interrupts then
            local mask = self.interrupts.mask or 0
            return bit.band(
                bit.rshift(mask, (address - I_MASK) * 8),
                0xFF
            )
        end
    end

    -- Dispositivos no implementados todavía.
    return 0
end

function Memory:read8(address)
    return self:readPhysical8(address)
end

function Memory:read16(address)
    -- Lectura directa de dos bytes.
    -- No llama a read32 ni genera recursión.
    local a = self:readPhysical8(address)
    local b = self:readPhysical8(address + 1)

    return a + b * 0x100
end

function Memory:read32(address)
    address = self:translate(address)

    -- Registros GPU.
    if self.gpu then
        if address == GPU_GP0 then
            return u32(self.gpu:readGP0())
        end

        if address == GPU_GP1 then
            return u32(self.gpu:readGP1())
        end
    end

    -- Registro de estado de interrupciones.
    if address == I_STAT then
        if self.interrupts then
            return u32(self.interrupts.pending or 0)
        end

        return 0
    end

    -- Máscara de interrupciones.
    if address == I_MASK then
        if self.interrupts then
            return u32(self.interrupts.mask or 0)
        end

        return 0
    end

    -- Lectura directa de cuatro bytes.
    local a = self:readPhysical8(address)
    local b = self:readPhysical8(address + 1)
    local c = self:readPhysical8(address + 2)
    local d = self:readPhysical8(address + 3)

    return u32(
        a +
        b * 0x100 +
        c * 0x10000 +
        d * 0x1000000
    )
end

function Memory:writePhysical8(address, value)
    address = self:translate(address)
    value = u8(value)

    -- RAM y espejos.
    if address < RAM_MIRROR_SIZE then
        self.ram[address % RAM_SIZE] = value
        return
    end

    -- Scratchpad.
    if address >= 0x1F800000
    and address < 0x1F800400 then
        self.scratchpad[address - 0x1F800000] = value
        return
    end

    -- BIOS: solo lectura.
end

function Memory:write8(address, value)
    self:writePhysical8(address, value)
end

function Memory:write16(address, value)
    value = u16(value)

    self:writePhysical8(address, value)
    self:writePhysical8(address + 1, bit.rshift(value, 8))
end

function Memory:write32(address, value)
    address = self:translate(address)
    value = u32(value)

    -- GPU GP0.
    if self.gpu and address == GPU_GP0 then
        self.gpu:writeGP0(value)
        return
    end

    -- GPU GP1.
    if self.gpu and address == GPU_GP1 then
        self.gpu:writeGP1(value)
        return
    end

    -- I_STAT: escribir un bit a cero limpia la interrupción.
    if address == I_STAT then
        if self.interrupts then
            local pending = self.interrupts.pending or 0
            self.interrupts.pending = bit.band(
                pending,
                value
            )

            if self.interrupts.updateStatus then
                self.interrupts:updateStatus()
            end
        end

        return
    end

    -- I_MASK.
    if address == I_MASK then
        if self.interrupts then
            self.interrupts:setMask(
                bit.band(value, 0x7FF)
            )
        end

        return
    end

    -- Escritura directa de cuatro bytes.
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
