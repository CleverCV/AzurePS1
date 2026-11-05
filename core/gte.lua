
local bit = require("bit")

local GTE = {}
GTE.__index = GTE

local function u32(v)
    return bit.tobit(v)
end

local function s16(v)
    v = bit.band(v, 0xFFFF)
    return v >= 0x8000 and v - 0x10000 or v
end

local function hi16(v)
    return s16(bit.rshift(v, 16))
end

local function clamp(v, low, high)
    if v < low then return low end
    if v > high then return high end
    return v
end

local function sign(v, bits)
    local limit = 2 ^ (bits - 1)
    local mod = 2 ^ bits
    v = v % mod
    return v >= limit and v - mod or v
end

function GTE.new()
    local self = setmetatable({}, GTE)

    self.data = {}
    self.control = {}
    self.mac = {0, 0, 0, 0}
    self.flags = 0
    self.cycles = 0

    self:reset()
    return self
end

function GTE:reset()
    for i = 0, 31 do
        self.data[i] = 0
        self.control[i] = 0
    end

    self.mac = {0, 0, 0, 0}
    self.flags = 0
    self.cycles = 0
end

function GTE:readData(index)
    index = bit.band(index, 31)

    if index == 15 then
        self.data[12] = self.data[13]
        self.data[13] = self.data[14]
    elseif index == 28 then
        return bit.bor(
            bit.band(bit.rshift(self.data[9] or 0, 7), 0x7C00),
            bit.band(bit.rshift(self.data[10] or 0, 2), 0x03E0),
            bit.band(bit.rshift(self.data[11] or 0, 7), 0x001F)
        )
    elseif index == 29 then
        return bit.bor(
            bit.band(bit.rshift(self.data[9] or 0, 12), 0x001F),
            bit.band(bit.rshift(self.data[10] or 0, 7), 0x03E0),
            bit.band(bit.rshift(self.data[11] or 0, 2), 0x7C00)
        )
    end

    return self.data[index] or 0
end

function GTE:writeData(index, value)
    index = bit.band(index, 31)
    value = u32(value)

    if index == 15 then
        self.data[12] = self.data[13]
        self.data[13] = self.data[14]
        self.data[14] = value
        return
    end

    if index == 28 or index == 29 then
        local r = bit.band(value, 31)
        local g = bit.band(bit.rshift(value, 5), 31)
        local b = bit.band(bit.rshift(value, 10), 31)

        self.data[9] = bit.bor(
            bit.band(self.data[9], 0xFFFF0000),
            bit.lshift(r, 7)
        )
        self.data[10] = bit.bor(
            bit.band(self.data[10], 0xFFFF0000),
            bit.lshift(g, 7)
        )
        self.data[11] = bit.bor(
            bit.band(self.data[11], 0xFFFF0000),
            bit.lshift(b, 7)
        )
        return
    end

    self.data[index] = value
end

function GTE:readControl(index)
    return self.control[bit.band(index, 31)] or 0
end

function GTE:writeControl(index, value)
    index = bit.band(index, 31)
    value = u32(value)

    if index == 31 then
        self.flags = bit.band(value, 0x7FFFF000)
        self.control[31] = self.flags
    else
        self.control[index] = value
    end
end

function GTE:setFlag(flag)
    self.flags = bit.bor(self.flags, flag)
end

function GTE:finishFlags()
    local f = self.flags

    if bit.band(f, 0x7F87E000) ~= 0 then
        f = bit.bor(f, 0x80000000)
    end

    self.flags = bit.band(f, 0x7FFFF000)
    self.control[31] = self.flags
end

function GTE:pushSXY(x, y)
    self.data[12] = self.data[13]
    self.data[13] = self.data[14]

    x = clamp(x, -1024, 1023)
    y = clamp(y, -1024, 1023)

    self.data[14] = u32(bit.bor(
        bit.band(x, 0xFFFF),
        bit.lshift(bit.band(y, 0xFFFF), 16)
    ))
end

function GTE:pushSZ(z)
    self.data[16] = self.data[17]
    self.data[17] = self.data[18]
    self.data[18] = self.data[19]
    self.data[19] = u32(clamp(z, 0, 65535))
end

function GTE:pushRGB(r, g, b, code)
    self.data[20] = self.data[21]
    self.data[21] = self.data[22]
    self.data[22] = u32(
        bit.band(r, 255) +
        bit.lshift(bit.band(g, 255), 8) +
        bit.lshift(bit.band(b, 255), 16) +
        bit.lshift(bit.band(code or 0, 255), 24)
    )
end

function GTE:getVector(index)
    local value = self.data[index] or 0
    local nextValue = self.data[index + 1] or 0

    return s16(value), hi16(value), s16(nextValue)
end

function GTE:getMatrix()
    local c = self.control

    return {
        {s16(c[0]), hi16(c[0]), s16(c[1])},
        {hi16(c[1]), s16(c[2]), hi16(c[2])},
        {s16(c[3]), hi16(c[3]), s16(c[4])}
    }
end

function GTE:transformVertex(index, sf, lm)
    local vx, vy, vz = self:getVector(index)
    local m = self:getMatrix()

    local tx, ty, tz = self.control[5], self.control[6], self.control[7]

    local x = tx + m[1][1] * vx + m[1][2] * vy + m[1][3] * vz
    local y = ty + m[2][1] * vx + m[2][2] * vy + m[2][3] * vz
    local z = tz + m[3][1] * vx + m[3][2] * vy + m[3][3] * vz

    if sf then
        x = math.floor(x / 65536)
        y = math.floor(y / 65536)
        z = math.floor(z / 65536)
    end

    if lm then
        x = math.max(0, x)
        y = math.max(0, y)
        z = math.max(0, z)
    end

    self.mac[1], self.mac[2], self.mac[3] = x, y, z
    self.data[25], self.data[26], self.data[27] =
        u32(x), u32(y), u32(z)

    self:pushSZ(z)
    return x, y, z
end

function GTE:projectVertex(index, sf, lm)
    local x, y, z = self:transformVertex(index, sf, lm)

    local h = bit.band(self.control[26] or 0, 0xFFFF)
    if h == 0 then h = 1 end

    local divisor = math.max(1, z)
    local factor = h / divisor

    local sx = math.floor((self.control[24] or 0) / 65536 + x * factor)
    local sy = math.floor((self.control[25] or 0) / 65536 + y * factor)

    self.data[8] = u32(
        (self.control[28] or 0) +
        s16(self.control[27] or 0) * factor
    )

    self:pushSXY(sx, sy)
    return sx, sy, z
end

function GTE:rtps(sf, lm)
    self.flags = 0
    self:projectVertex(0, sf, lm)
    self:finishFlags()
end

function GTE:rtpt(sf, lm)
    self.flags = 0
    self:projectVertex(0, sf, lm)
    self:projectVertex(2, sf, lm)
    self:projectVertex(4, sf, lm)
    self:finishFlags()
end

function GTE:nclip()
    local x0, y0 = s16(self.data[12]), hi16(self.data[12])
    local x1, y1 = s16(self.data[13]), hi16(self.data[13])
    local x2, y2 = s16(self.data[14]), hi16(self.data[14])

    local value = x0 * y1 + x1 * y2 + x2 * y0 -
        x0 * y2 - x1 * y0 - x2 * y1

    self.data[24] = u32(value)
    self.mac[0] = value
end

function GTE:avsz3()
    local z = (self.data[17] or 0) +
        (self.data[18] or 0) +
        (self.data[19] or 0)

    local zsf = s16(self.control[29] or 0)
    local otz = clamp(math.floor(z * zsf / 4096), 0, 65535)

    self.data[7] = u32(otz)
end

function GTE:avsz4()
    local z = (self.data[16] or 0) +
        (self.data[17] or 0) +
        (self.data[18] or 0) +
        (self.data[19] or 0)

    local zsf = s16(self.control[30] or 0)
    local otz = clamp(math.floor(z * zsf / 4096), 0, 65535)

    self.data[7] = u32(otz)
end

function GTE:execute(command)
    local fn = bit.band(command, 0x3F)
    local sf = bit.band(command, 0x00080000) ~= 0
    local lm = bit.band(command, 0x00040000) ~= 0

    self.cycles = self.cycles + 1
    self.flags = 0

    if fn == 0x01 then
        self:rtps(sf, lm)

    elseif fn == 0x06 then
        self:nclip()

    elseif fn == 0x0C then
        local vx, vy, vz = self:getVector(0)
        local m = self:getMatrix()

        local x = m[2][2] * vz - m[2][1] * vy
        local y = m[2][0] * vx - m[2][2] * vz
        local z = m[2][1] * vy - m[2][0] * vx

        if sf then
            x, y, z = math.floor(x / 65536),
                math.floor(y / 65536), math.floor(z / 65536)
        end

        self.data[25], self.data[26], self.data[27] =
            u32(x), u32(y), u32(z)

    elseif fn == 0x10 then
        -- DPCS: depth cue interpolation aproximada.
        local rgb = self.data[6] or 0
        local r = bit.band(rgb, 255)
        local g = bit.band(bit.rshift(rgb, 8), 255)
        local b = bit.band(bit.rshift(rgb, 16), 255)
        local code = bit.band(bit.rshift(rgb, 24), 255)

        self:pushRGB(r, g, b, code)

    elseif fn == 0x11 then
        -- INTPL: interpolación aproximada.
        local rgb = self.data[6] or 0
        self:pushRGB(
            bit.band(rgb, 255),
            bit.band(bit.rshift(rgb, 8), 255),
            bit.band(bit.rshift(rgb, 16), 255),
            bit.band(bit.rshift(rgb, 24), 255)
        )

    elseif fn == 0x12 then
        -- MVMVA: multiplicación matriz-vector aproximada.
        local vx, vy, vz = self:getVector(0)
        local m = self:getMatrix()

        local x = m[1][1] * vx + m[1][2] * vy + m[1][3] * vz
        local y = m[2][1] * vx + m[2][2] * vy + m[2][3] * vz
        local z = m[3][1] * vx + m[3][2] * vy + m[3][3] * vz

        if sf then
            x, y, z = math.floor(x / 65536),
                math.floor(y / 65536), math.floor(z / 65536)
        end

        self.data[25], self.data[26], self.data[27] =
            u32(x), u32(y), u32(z)

    elseif fn == 0x13 or fn == 0x14 or fn == 0x16
    or fn == 0x1B or fn == 0x1C or fn == 0x1E
    or fn == 0x20 or fn == 0x3F then
        -- Operaciones de iluminación/color todavía aproximadas.
        local rgb = self.data[6] or 0
        self:pushRGB(
            bit.band(rgb, 255),
            bit.band(bit.rshift(rgb, 8), 255),
            bit.band(bit.rshift(rgb, 16), 255),
            bit.band(bit.rshift(rgb, 24), 255)
        )

    elseif fn == 0x28 then
        -- SQR.
        for i = 1, 3 do
            local value = bit.tobit(self.data[24 + i] or 0)
            local result = value * value
            if sf then result = math.floor(result / 65536) end
            self.data[24 + i] = u32(result)
        end

    elseif fn == 0x29 then
        -- DCPL aproximado.
        local rgb = self.data[6] or 0
        self:pushRGB(
            bit.band(rgb, 255),
            bit.band(bit.rshift(rgb, 8), 255),
            bit.band(bit.rshift(rgb, 16), 255),
            bit.band(bit.rshift(rgb, 24), 255)
        )

    elseif fn == 0x2A then
        -- DPCT aproximado: procesar los tres colores FIFO.
        for i = 20, 22 do
            local rgb = self.data[i] or 0
            self:pushRGB(
                bit.band(rgb, 255),
                bit.band(bit.rshift(rgb, 8), 255),
                bit.band(bit.rshift(rgb, 16), 255),
                bit.band(bit.rshift(rgb, 24), 255)
            )
        end

    elseif fn == 0x2D then
        self:avsz3()

    elseif fn == 0x2E then
        self:avsz4()

    elseif fn == 0x30 then
        self:rtpt(sf, lm)

    elseif fn == 0x3D then
        -- GPF.
        local ir0 = s16(self.data[8] or 0)
        for i = 1, 3 do
            local ir = bit.tobit(self.data[8 + i] or 0)
            local result = ir * ir0
            if sf then result = math.floor(result / 65536) end
            self.data[24 + i] = u32(result)
        end

    elseif fn == 0x3E then
        -- GPL.
        for i = 1, 3 do
            self.data[24 + i] = u32(
                (self.data[24 + i] or 0) +
                (self.mac[i] or 0)
            )
        end

    else
        -- No detener el BIOS por una operación GTE no implementada.
        -- La instrucción se acepta, pero no altera los registros.
    end

    self:finishFlags()
    return true
end

return GTE
