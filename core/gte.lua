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

local function lo16(v)
    return s16(v)
end

local function clamp(v, low, high)
    if v < low then return low end
    if v > high then return high end
    return v
end

function GTE.new()
    local self = setmetatable({}, GTE)

    self.data = {}
    self.control = {}

    for i = 0, 31 do
        self.data[i] = 0
        self.control[i] = 0
    end

    self.cycles = 0
    self.flags = 0
    self.mac = {0, 0, 0, 0}

    return self
end

function GTE:reset()
    for i = 0, 31 do
        self.data[i] = 0
        self.control[i] = 0
    end

    self.cycles = 0
    self.flags = 0
end

function GTE:readData(index)
    index = bit.band(index, 31)

    if index == 15 then
        self.data[12] = self.data[13]
        self.data[13] = self.data[14]
    end

    if index == 28 then
        return bit.bor(
            bit.band(bit.rshift(self.data[9] or 0, 7), 0x7C00),
            bit.band(bit.rshift(self.data[10] or 0, 2), 0x03E0),
            bit.band(bit.rshift(self.data[11] or 0, 7), 0x001F)
        )
    end

    if index == 29 then
        return bit.bor(
            bit.band(bit.rshift(self.data[9] or 0, 12), 0x1F),
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
        self.data[14] = value
        self.data[12] = self.data[13]
        self.data[13] = self.data[14]
        return
    end

    if index == 28 or index == 29 then
        local r = bit.band(value, 0x1F)
        local g = bit.band(bit.rshift(value, 5), 0x1F)
        local b = bit.band(bit.rshift(value, 10), 0x1F)

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

    local sx = clamp(x, -1024, 1023)
    local sy = clamp(y, -1024, 1023)

    self.data[14] = u32(bit.bor(
        bit.band(sx, 0xFFFF),
        bit.lshift(bit.band(sy, 0xFFFF), 16)
    ))
end

function GTE:pushSZ(value)
    self.data[16] = self.data[17]
    self.data[17] = self.data[18]
    self.data[18] = self.data[19]
    self.data[19] = u32(clamp(value, 0, 65535))
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

function GTE:transformVertex(index, sf, lm)
    local vx = s16(self.data[index] or 0)
    local vy = hi16(self.data[index] or 0)
    local vz = s16(self.data[index + 1] or 0)

    local rotation = {
        {s16(self.control[0]), hi16(self.control[0]), s16(self.control[1])},
        {hi16(self.control[1]), s16(self.control[2]), hi16(self.control[2])},
        {s16(self.control[3]), hi16(self.control[3]), s16(self.control[4])}
    }

    -- The PS1 stores the rotation matrix in packed halfwords.
    local m = {
        {s16(self.control[0]), hi16(self.control[0]), s16(self.control[1])},
        {hi16(self.control[1]), s16(self.control[2]), hi16(self.control[2])},
        {s16(self.control[3]), hi16(self.control[3]), s16(self.control[4])}
    }

    local tx = self.control[5]
    local ty = self.control[6]
    local tz = self.control[7]

    local x = tx + m[1][1] * vx + m[1][2] * vy + m[1][3] * vz
    local y = ty + m[2][1] * vx + m[2][2] * vy + m[2][3] * vz
    local z = tz + m[3][1] * vx + m[3][2] * vy + m[3][3] * vz

    if lm then
        x = math.max(0, x)
        y = math.max(0, y)
        z = math.max(0, z)
    end

    if sf then
        x = math.floor(x / 65536)
        y = math.floor(y / 65536)
        z = math.floor(z / 65536)
    end

    self.mac[1], self.mac[2], self.mac[3] = x, y, z

    self.data[25] = u32(x)
    self.data[26] = u32(y)
    self.data[27] = u32(z)

    self:pushSZ(z)
    return x, y, z
end

function GTE:projectVertex(index, sf, lm)
    local _, _, z = self:transformVertex(index, sf, lm)

    local h = bit.band(self.control[26], 0xFFFF)
    if h == 0 then h = 1 end

    local factor = h / math.max(1, z)
    local x = math.floor(self.mac[1] * factor)
    local y = math.floor(self.mac[2] * factor)

    local ofx = self.control[24]
    local ofy = self.control[25]

    local sx = math.floor(ofx / 65536) + x
    local sy = math.floor(ofy / 65536) + y

    local dqa = s16(self.control[27])
    local dqb = self.control[28]
    local depth = math.floor(dqb + dqa * factor)

    self.data[8] = u32(depth)
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
    local x0 = s16(self.data[12])
    local y0 = hi16(self.data[12])
    local x1 = s16(self.data[13])
    local y1 = hi16(self.data[13])
    local x2 = s16(self.data[14])
    local y2 = hi16(self.data[14])

    local value = x0 * y1 + x1 * y2 + x2 * y0 -
        x0 * y2 - x1 * y0 - x2 * y1

    self.data[24] = u32(value)
    self.mac[0] = value
end

function GTE:avsz3()
    local z = (self.data[17] or 0) +
        (self.data[18] or 0) +
        (self.data[19] or 0)

    local zsf = s16(self.control[29])
    self.data[7] = u32(math.floor(z * zsf / 4096))
    self.data[OTZ] = self.data[7]
end

function GTE:avsz4()
    local z = (self.data[16] or 0) +
        (self.data[17] or 0) +
        (self.data[18] or 0) +
        (self.data[19] or 0)

    local zsf = s16(self.control[30])
    self.data[7] = u32(math.floor(z * zsf / 4096))
end

function GTE:execute(command)
    local fn = bit.band(command, 0x3F)
    local sf = bit.band(command, 0x00080000) ~= 0
    local lm = bit.band(command, 0x00040000) ~= 0

    self.cycles = self.cycles + 1

    if fn == 0x01 then
        self:rtps(sf, lm)

    elseif fn == 0x06 then
        self:nclip()

    elseif fn == 0x0C then
        -- OP: outer product.
        local vx = s16(self.data[0])
        local vy = hi16(self.data[0])
        local vz = s16(self.data[1])

        local r = {
            s16(self.control[0]), s16(self.control[2]), s16(self.control[4])
        }

        local x = r[2] * vz - r[3] * vy
        local y = r[3] * vx - r[1] * vz
        local z = r[1] * vy - r[2] * vx

        if sf then
            x, y, z = math.floor(x / 65536),
                math.floor(y / 65536), math.floor(z / 65536)
        end

        self.data[25], self.data[26], self.data[27] =
            u32(x), u32(y), u32(z)

    elseif fn == 0x10 then
        self:execute(bit.bor(command, 0x10))

    elseif fn == 0x11 then
        -- SQR
        for i = 1, 3 do
            local v = s32(self.data[24 + i])
            local result = v * v
            if sf then result = math.floor(result / 65536) end
            self.data[24 + i] = u32(result)
        end

    elseif fn == 0x12 then
        -- DCPL: approximate depth cue interpolation.
        local r = bit.band(self.data[6], 0xFF)
        local g = bit.band(bit.rshift(self.data[6], 8), 0xFF)
        local b = bit.band(bit.rshift(self.data[6], 16), 0xFF)
        self:pushRGB(r, g, b, bit.rshift(self.data[6], 24))

    elseif fn == 0x13 then
        -- INTPL
        self:pushRGB(
            bit.band(self.data[6], 255),
            bit.band(bit.rshift(self.data[6], 8), 255),
            bit.band(bit.rshift(self.data[6], 16), 255),
            bit.rshift(self.data[6], 24)
        )

    elseif fn == 0x2D then
        self:avsz3()

    elseif fn == 0x2E then
        self:avsz4()

    elseif fn == 0x30 then
        self:rtpt(sf, lm)

    elseif fn == 0x3D then
        -- GPF
        for i = 1, 3 do
            local value = s32(self.data[24 + i])
            if sf then value = math.floor(value / 65536) end
            self.data[24 + i] = u32(value)
        end

    elseif fn == 0x3E then
        -- GPL
        for i = 1, 3 do
            self.data[24 + i] = u32(
                self.data[24 + i] + self.mac[i]
            )
        end
    end

    self:finishFlags()
end

return GTE