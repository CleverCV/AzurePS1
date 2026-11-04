local bit = require("bit")

local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local lshift = bit.lshift
local rshift = bit.rshift
local tobit = bit.tobit

local GTE = {}
GTE.__index = GTE

local function s16(value)
    value = band(value, 0xFFFF)
    if value >= 0x8000 then
        return value - 0x10000
    end
    return value
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function shift(value, amount)
    return math.floor(value / (2 ^ amount))
end

local function u32(value)
    return tobit(value)
end

function GTE.new()
    local self = setmetatable({}, GTE)

    self.data = {}
    self.control = {}

    self.cycles = 0
    self.flag = 0

    for i = 0, 31 do
        self.data[i] = 0
        self.control[i] = 0
    end

    return self
end

function GTE:reset()
    for i = 0, 31 do
        self.data[i] = 0
        self.control[i] = 0
    end

    self.cycles = 0
    self.flag = 0
end

function GTE:readData(index)
    index = band(index, 31)

    if index == 15 then
        return u32(self.data[14])
    end

    if index == 28 then
        local r = band(self.data[9], 0x1F)
        local g = band(self.data[10], 0x1F)
        local b = band(self.data[11], 0x1F)

        return bor(
            r,
            lshift(g, 5),
            lshift(b, 10)
        )
    end

    if index == 29 then
        return u32(self.data[28])
    end

    if index == 31 then
        return u32(self.data[31])
    end

    return u32(self.data[index] or 0)
end

function GTE:writeData(index, value)
    index = band(index, 31)
    value = u32(value)

    if index == 15 then
        self.data[12] = self.data[13]
        self.data[13] = self.data[14]
        self.data[14] = value

    elseif index == 28 then
        self.data[28] = value

        local rgb = band(value, 0x7FFF)

        self.data[9] = band(rgb, 31) * 0x400
        self.data[10] = band(rshift(rgb, 5), 31) * 0x400
        self.data[11] = band(rshift(rgb, 10), 31) * 0x400

    elseif index == 30 then
        self.data[30] = value

        local v = value
        local count = 0

        if v < 0 then
            v = bxor(v, -1)
        end

        for i = 31, 0, -1 do
            if band(rshift(v, i), 1) ~= 0 then
                break
            end

            count = count + 1
        end

        self.data[31] = count

    elseif index == 31 then
        -- LZCR es de solo lectura.

    else
        self.data[index] = value
    end
end

function GTE:readControl(index)
    index = band(index, 31)

    if index == 31 then
        return u32(self.flag)
    end

    return u32(self.control[index] or 0)
end

function GTE:writeControl(index, value)
    index = band(index, 31)
    value = u32(value)

    if index == 31 then
        self.flag = band(value, 0x7FFFF000)
        self.data[31] = self.flag
    else
        self.control[index] = value
    end
end

function GTE:_begin()
    self.flag = 0
end

function GTE:_finish()
    if band(self.flag, 0x7F87E000) ~= 0 then
        self.flag = bor(self.flag, 0x80000000)
    end

    self.data[31] = self.flag
end

function GTE:_setMAC(index, value)
    if value > 2147483647 then
        self.flag = bor(
            self.flag,
            lshift(1, 30 - index)
        )
    elseif value < -2147483648 then
        self.flag = bor(
            self.flag,
            lshift(1, 27 - index)
        )
    end

    self.data[24 + index] = u32(value)
end

function GTE:_setIR(index, value, lm)
    local minimum = lm and 0 or -32768

    if value < minimum or value > 32767 then
        self.flag = bor(
            self.flag,
            lshift(1, 25 - index)
        )
    end

    self.data[8 + index] = clamp(value, minimum, 32767)
end

function GTE:_vector(index)
    local xy = self.data[index * 2] or 0
    local z = self.data[index * 2 + 1] or 0

    return {
        s16(band(xy, 0xFFFF)),
        s16(rshift(xy, 16)),
        s16(band(z, 0xFFFF))
    }
end

function GTE:_matrix(base)
    local matrix = {
        {0, 0, 0},
        {0, 0, 0},
        {0, 0, 0}
    }

    for row = 1, 3 do
        for column = 1, 3 do
            local element = (row - 1) * 3 + column - 1
            local register = base + math.floor(element / 2)
            local packed = self.control[register] or 0

            if element == 8 then
                matrix[row][column] = s16(band(packed, 0xFFFF))
            elseif element % 2 == 0 then
                matrix[row][column] = s16(band(packed, 0xFFFF))
            else
                matrix[row][column] = s16(rshift(packed, 16))
            end
        end
    end

    return matrix
end

function GTE:_translation(base)
    return {
        tobit(self.control[base] or 0),
        tobit(self.control[base + 1] or 0),
        tobit(self.control[base + 2] or 0)
    }
end

function GTE:_multiply(matrix, vector, translation, sf, lm)
    local amount = sf and 12 or 0

    for i = 1, 3 do
        local result =
            translation[i] * 4096
            + matrix[i][1] * vector[1]
            + matrix[i][2] * vector[2]
            + matrix[i][3] * vector[3]

        result = shift(result, amount)

        self:_setMAC(i, result)
        self:_setIR(i, result, lm)
    end
end

function GTE:_setSZ(value)
    if value < 0 or value > 65535 then
        self.flag = bor(self.flag, lshift(1, 18))
    end

    self.data[16] = self.data[17]
    self.data[17] = self.data[18]
    self.data[18] = self.data[19]
    self.data[19] = clamp(value, 0, 65535)
end

function GTE:_setSXY(x, y)
    local sx = clamp(x, -1024, 1023)
    local sy = clamp(y, -1024, 1023)

    if sx ~= x then
        self.flag = bor(self.flag, lshift(1, 14))
    end

    if sy ~= y then
        self.flag = bor(self.flag, lshift(1, 13))
    end

    self.data[12] = self.data[13]
    self.data[13] = self.data[14]

    self.data[14] = u32(
        bor(
            band(sx, 0xFFFF),
            lshift(band(sy, 0xFFFF), 16)
        )
    )
end

function GTE:_rtps(vectorIndex, sf, lm)
    local matrix = self:_matrix(0)
    local vector = self:_vector(vectorIndex)
    local translation = self:_translation(5)

    self:_multiply(
        matrix,
        vector,
        translation,
        sf,
        lm
    )

    local depth = self.data[27]

    self:_setSZ(
        shift(depth, sf and 0 or 12)
    )

    local h = band(self.control[26] or 0, 0xFFFF)
    local sz = self.data[19]

    local quotient

    if sz == 0 then
        quotient = 0x1FFFF
        self.flag = bor(self.flag, lshift(1, 17))
    else
        quotient = math.floor(
            (h * 0x20000 / sz + 1) / 2
        )

        if quotient > 0x1FFFF then
            quotient = 0x1FFFF
            self.flag = bor(self.flag, lshift(1, 17))
        end
    end

    local sx = shift(
        (self.control[24] or 0) + quotient * self.data[9],
        16
    )

    local sy = shift(
        (self.control[25] or 0) + quotient * self.data[10],
        16
    )

    self:_setSXY(sx, sy)

    local dqa = s16(self.control[27] or 0)
    local dqb = tobit(self.control[28] or 0)

    local ir0 = shift(
        quotient * dqa + dqb,
        12
    )

    if ir0 < 0 or ir0 > 4096 then
        self.flag = bor(self.flag, lshift(1, 12))
    end

    self.data[8] = clamp(ir0, 0, 4096)
end

function GTE:_nclip()
    local function getXY(index)
        local value = self.data[index]

        return
            s16(band(value, 0xFFFF)),
            s16(rshift(value, 16))
    end

    local x0, y0 = getXY(12)
    local x1, y1 = getXY(13)
    local x2, y2 = getXY(14)

    self.data[24] = u32(
        x0 * y1
        + x1 * y2
        + x2 * y0
        - x0 * y2
        - x1 * y0
        - x2 * y1
    )
end

function GTE:_op(sf)
    local matrix = self:_matrix(0)

    local x = self.data[9]
    local y = self.data[10]
    local z = self.data[11]

    local values = {
        z * matrix[2][2] - y * matrix[1][1],
        x * matrix[1][1] - z * matrix[2][2],
        y * matrix[2][2] - x * matrix[1][1]
    }

    for i = 1, 3 do
        local result = shift(values[i], sf and 12 or 0)

        self:_setMAC(i, result)
        self:_setIR(i, result, false)
    end
end

function GTE:_mvmva(command)
    local mx = band(rshift(command, 17), 3)
    local vectorSelect = band(rshift(command, 15), 3)
    local translationSelect = band(rshift(command, 13), 3)

    local sf = band(command, lshift(1, 19)) ~= 0
    local lm = band(command, lshift(1, 10)) ~= 0

    local matrixBases = {0, 8, 16}
    local translationBases = {5, 13, 21}

    local matrix = self:_matrix(matrixBases[mx + 1] or 0)

    local vector

    if vectorSelect == 3 then
        vector = {
            self.data[9],
            self.data[10],
            self.data[11]
        }
    else
        vector = self:_vector(vectorSelect)
    end

    local translation

    if translationSelect == 3 then
        translation = {0, 0, 0}
    else
        translation = self:_translation(
            translationBases[translationSelect + 1]
        )
    end

    self:_multiply(
        matrix,
        vector,
        translation,
        sf,
        lm
    )
end

function GTE:_sqr(sf, lm)
    for i = 1, 3 do
        local value = self.data[8 + i]
        local result = shift(value * value, sf and 12 or 0)

        self:_setMAC(i, result)
        self:_setIR(i, result, lm)
    end
end

function GTE:_avsz(count)
    local sum

    if count == 3 then
        sum =
            self.data[17]
            + self.data[18]
            + self.data[19]
    else
        sum =
            self.data[16]
            + self.data[17]
            + self.data[18]
            + self.data[19]
    end

    local scale = s16(
        self.control[count == 3 and 29 or 30] or 0
    )

    local result = sum * scale

    self.data[24] = u32(result)

    local otz = shift(result, 12)

    if otz < 0 or otz > 65535 then
        self.flag = bor(self.flag, lshift(1, 18))
    end

    self.data[7] = clamp(otz, 0, 65535)
end

function GTE:_gpf(sf, lm, addBase)
    local amount = sf and 12 or 0

    for i = 1, 3 do
        local base = 0

        if addBase then
            base = self.data[24 + i]
        end

        local result = shift(
            self.data[8] * self.data[8 + i] + base,
            amount
        )

        self:_setMAC(i, result)
        self:_setIR(i, result, lm)
    end
end

function GTE:execute(command)
    command = u32(command)

    local opcode = band(command, 0x3F)
    local sf = band(command, lshift(1, 19)) ~= 0
    local lm = band(command, lshift(1, 10)) ~= 0

    self:_begin()

    if opcode == 0x01 then
        self:_rtps(0, sf, lm)
        self.cycles = self.cycles + 15

    elseif opcode == 0x30 then
        self:_rtps(0, sf, lm)
        self:_rtps(1, sf, lm)
        self:_rtps(2, sf, lm)
        self.cycles = self.cycles + 23

    elseif opcode == 0x06 then
        self:_nclip()
        self.cycles = self.cycles + 8

    elseif opcode == 0x0C then
        self:_op(sf)
        self.cycles = self.cycles + 6

    elseif opcode == 0x12 then
        self:_mvmva(command)
        self.cycles = self.cycles + 8

    elseif opcode == 0x28 then
        self:_sqr(sf, lm)
        self.cycles = self.cycles + 5

    elseif opcode == 0x2D then
        self:_avsz(3)
        self.cycles = self.cycles + 5

    elseif opcode == 0x2E then
        self:_avsz(4)
        self.cycles = self.cycles + 6

    elseif opcode == 0x3D then
        self:_gpf(sf, lm, false)
        self.cycles = self.cycles + 5

    elseif opcode == 0x3E then
        self:_gpf(sf, lm, true)
        self.cycles = self.cycles + 5

    else
        self:_finish()
        return false, string.format(
            "GTE command 0x%02X is not implemented",
            opcode
        )
    end

    self:_finish()

    return true
end

return GTE