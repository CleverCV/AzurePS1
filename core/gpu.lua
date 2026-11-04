
local bit = require("bit")

local GPU = {}
GPU.__index = GPU

local floor = math.floor
local min = math.min
local max = math.max

local function u32(v)
    return bit.band(v, 0xFFFFFFFF)
end

local function byte(v, shift)
    return bit.band(bit.rshift(v, shift), 0xFF)
end

local function color555(r, g, b)
    return bit.bor(
        bit.rshift(r, 3),
        bit.lshift(bit.rshift(g, 3), 5),
        bit.lshift(bit.rshift(b, 3), 10)
    )
end

local function decodeXY(v)
    local x = bit.band(v, 0x7FF)
    local y = bit.band(bit.rshift(v, 16), 0x7FF)

    if x >= 0x400 then x = x - 0x800 end
    if y >= 0x400 then y = y - 0x800 end

    return x, y
end

local function decodeWH(v)
    return bit.band(v, 0xFFFF),
           bit.band(bit.rshift(v, 16), 0xFFFF)
end

local function decodeColor(v)
    return byte(v, 0), byte(v, 8), byte(v, 16)
end

local function signed11(v)
    v = bit.band(v, 0x7FF)
    if v >= 1024 then v = v - 2048 end
    return v
end

function GPU.new(interrupts)
    local self = setmetatable({}, GPU)

    self.interrupts = interrupts

    self.vram_width = 1024
    self.vram_height = 512

    self.vram = {}

    for i = 1, self.vram_width * self.vram_height do
        self.vram[i] = 0
    end

    self.imageData = nil
    self.image = nil
    self.image_dirty = true

    self.command_buffer = {}
    self.transfer = nil
    self.read_transfer = nil

    self.cycles = 0

    self:reset()

    print("[GPU] Initialized: 1024x512 VRAM")

    return self
end

function GPU:reset()
    self.status = 0x14802000

    self.display_enabled = false
    self.dma_direction = 0

    self.display_x = 0
    self.display_y = 0

    self.horizontal_start = 0x200
    self.horizontal_end = 0xC00

    self.vertical_start = 0x10
    self.vertical_end = 0x100

    self.display_mode = 0

    self.draw_mode = 0
    self.texture_window = 0

    self.drawing_area_left = 0
    self.drawing_area_top = 0
    self.drawing_area_right = 1023
    self.drawing_area_bottom = 511

    self.drawing_offset_x = 0
    self.drawing_offset_y = 0

    self.mask_set = false
    self.mask_check = false

    self.command_buffer = {}
    self.transfer = nil
    self.read_transfer = nil

    self.gp0_read_latch = 0

    self.cycles = 0
    self.image_dirty = true
end

function GPU:getVRAMIndex(x, y)
    x = bit.band(x, 0x3FF)
    y = bit.band(y, 0x1FF)

    return y * self.vram_width + x + 1
end

function GPU:readPixel(x, y)
    return self.vram[self:getVRAMIndex(x, y)] or 0
end

function GPU:writeRawPixel(x, y, value)
    x = bit.band(x, 0x3FF)
    y = bit.band(y, 0x1FF)

    self.vram[self:getVRAMIndex(x, y)] =
        bit.band(value, 0xFFFF)

    self.image_dirty = true
end

function GPU:writePixel(x, y, color)
    x = x + self.drawing_offset_x
    y = y + self.drawing_offset_y

    if x < self.drawing_area_left
    or x > self.drawing_area_right
    or y < self.drawing_area_top
    or y > self.drawing_area_bottom then
        return
    end

    if x < 0 or x >= self.vram_width
    or y < 0 or y >= self.vram_height then
        return
    end

    local index = self:getVRAMIndex(x, y)

    if self.mask_check and bit.band(self.vram[index], 0x8000) ~= 0 then
        return
    end

    local value = bit.band(color, 0x7FFF)

    if self.mask_set then
        value = bit.bor(value, 0x8000)
    end

    self.vram[index] = value
    self.image_dirty = true
end

function GPU:fillRect(x, y, w, h, color)
    if w <= 0 or h <= 0 then return end

    for py = 0, h - 1 do
        for px = 0, w - 1 do
            self:writePixel(x + px, y + py, color)
        end
    end
end

function GPU:drawLine(x1, y1, x2, y2, color)
    local dx = math.abs(x2 - x1)
    local dy = math.abs(y2 - y1)

    local sx = x1 < x2 and 1 or -1
    local sy = y1 < y2 and 1 or -1

    local err = dx - dy

    while true do
        self:writePixel(x1, y1, color)

        if x1 == x2 and y1 == y2 then
            break
        end

        local e2 = err * 2

        if e2 > -dy then
            err = err - dy
            x1 = x1 + sx
        end

        if e2 < dx then
            err = err + dx
            y1 = y1 + sy
        end
    end
end

function GPU:drawTriangle(x1, y1, x2, y2, x3, y3, color)
    local minX = max(
        min(x1, x2, x3),
        self.drawing_area_left - self.drawing_offset_x
    )

    local maxX = min(
        max(x1, x2, x3),
        self.drawing_area_right - self.drawing_offset_x
    )

    local minY = max(
        min(y1, y2, y3),
        self.drawing_area_top - self.drawing_offset_y
    )

    local maxY = min(
        max(y1, y2, y3),
        self.drawing_area_bottom - self.drawing_offset_y
    )

    local function edge(ax, ay, bx, by, px, py)
        return (px - ax) * (by - ay)
             - (py - ay) * (bx - ax)
    end

    local area = edge(x1, y1, x2, y2, x3, y3)

    if area == 0 then return end

    for y = minY, maxY do
        for x = minX, maxX do
            local w1 = edge(x2, y2, x3, y3, x, y)
            local w2 = edge(x3, y3, x1, y1, x, y)
            local w3 = edge(x1, y1, x2, y2, x, y)

            if (area > 0 and w1 >= 0 and w2 >= 0 and w3 >= 0)
            or (area < 0 and w1 <= 0 and w2 <= 0 and w3 <= 0) then
                self:writePixel(x, y, color)
            end
        end
    end
end

function GPU:drawQuad(x1, y1, x2, y2, x3, y3, x4, y4, color)
    self:drawTriangle(x1, y1, x2, y2, x3, y3, color)
    self:drawTriangle(x2, y2, x3, y3, x4, y4, color)
end

function GPU:getPacketLength(command)
    local op = byte(command, 24)

    if op <= 0x1F or op >= 0xE0 then
        if op == 0x02 then return 3 end
        return 1
    end

    if op >= 0x20 and op <= 0x3F then
        local vertices = bit.band(op, 0x08) ~= 0 and 4 or 3
        local gouraud = bit.band(op, 0x10) ~= 0
        local textured = bit.band(op, 0x04) ~= 0

        return 1
            + vertices
            + (gouraud and vertices - 1 or 0)
            + (textured and vertices or 0)
    end

    if op >= 0x40 and op <= 0x47 then
        return 3
    end

    if op >= 0x50 and op <= 0x53 then
        return 4
    end

    if op >= 0x60 and op <= 0x7F then
        local sizeMode = bit.band(bit.rshift(op, 3), 3)

        if sizeMode == 0 then
            return 3
        end

        return 2
    end

    if op == 0x80 then return 4 end
    if op == 0xA0 or op == 0xC0 then return 3 end

    return 1
end

function GPU:executePolygon(packet, opcode)
    local gouraud = bit.band(opcode, 0x10) ~= 0
    local textured = bit.band(opcode, 0x04) ~= 0
    local quad = bit.band(opcode, 0x08) ~= 0

    if textured then return end

    local count = quad and 4 or 3
    local positions = {}
    local colors = {}

    local r, g, b = decodeColor(packet[1])
    colors[1] = color555(r, g, b)

    local cursor = 2

    for i = 1, count do
        if gouraud and i > 1 then
            r, g, b = decodeColor(packet[cursor])
            colors[i] = color555(r, g, b)
            cursor = cursor + 1
        elseif not gouraud then
            colors[i] = colors[1]
        end

        local x, y = decodeXY(packet[cursor])
        positions[i] = {x, y}
        cursor = cursor + 1
    end

    local p1 = positions[1]
    local p2 = positions[2]
    local p3 = positions[3]

    self:drawTriangle(
        p1[1], p1[2],
        p2[1], p2[2],
        p3[1], p3[2],
        colors[1]
    )

    if quad then
        local p4 = positions[4]

        self:drawTriangle(
            p2[1], p2[2],
            p3[1], p3[2],
            p4[1], p4[2],
            colors[1]
        )
    end
end

function GPU:executePacket(packet)
    if #packet == 0 then return end

    local command = packet[1]
    local opcode = byte(command, 24)

    local r, g, b = decodeColor(command)
    local color = color555(r, g, b)

    if opcode == 0x00 or opcode == 0x01 then
        return
    end

    if opcode == 0x1F then
        self.status = bit.bor(self.status, 0x01000000)

        if self.interrupts and self.interrupts.request then
            self.interrupts:request(1)
        end

        return
    end

    if opcode == 0x02 then
        local x, y = decodeXY(packet[2])
        local w, h = decodeWH(packet[3])

        x = bit.band(x, 0x3F0)
        y = bit.band(y, 0x1FF)

        w = w == 0 and 1024 or w
        h = h == 0 and 512 or h

        for py = 0, h - 1 do
            for px = 0, w - 1 do
                self:writeRawPixel(x + px, y + py, color)
            end
        end

        return
    end

    if opcode >= 0x20 and opcode <= 0x3F then
        self:executePolygon(packet, opcode)
        return
    end

    if opcode >= 0x40 and opcode <= 0x47 then
        local x1, y1 = decodeXY(packet[2])
        local x2, y2 = decodeXY(packet[3])

        self:drawLine(x1, y1, x2, y2, color)
        return
    end

    if opcode >= 0x50 and opcode <= 0x53 then
        local x1, y1 = decodeXY(packet[2])
        local x2, y2 = decodeXY(packet[4])

        self:drawLine(x1, y1, x2, y2, color)
        return
    end

    if opcode >= 0x60 and opcode <= 0x7F then
        local x, y = decodeXY(packet[2])

        local sizeMode = bit.band(bit.rshift(opcode, 3), 3)
        local w, h

        if sizeMode == 0 then
            w, h = decodeWH(packet[3])
        elseif sizeMode == 1 then
            w, h = 1, 1
        elseif sizeMode == 2 then
            w, h = 8, 8
        else
            w, h = 16, 16
        end

        self:fillRect(x, y, w, h, color)
        return
    end

    if opcode == 0x80 then
        local sx, sy = decodeXY(packet[2])
        local dx, dy = decodeXY(packet[3])
        local w, h = decodeWH(packet[4])

        w = w == 0 and 1024 or w
        h = h == 0 and 512 or h

        local copy = {}

        for y = 0, h - 1 do
            for x = 0, w - 1 do
                copy[y * w + x + 1] =
                    self:readPixel(sx + x, sy + y)
            end
        end

        for y = 0, h - 1 do
            for x = 0, w - 1 do
                self:writeRawPixel(
                    dx + x,
                    dy + y,
                    copy[y * w + x + 1]
                )
            end
        end

        return
    end

    if opcode == 0xA0 then
        local x, y = decodeXY(packet[2])
        local w, h = decodeWH(packet[3])

        w = w == 0 and 1024 or w
        h = h == 0 and 512 or h

        self.transfer = {
            x = x,
            y = y,
            width = w,
            position = 0,
            remaining = w * h
        }

        return
    end

    if opcode == 0xC0 then
        local x, y = decodeXY(packet[2])
        local w, h = decodeWH(packet[3])

        w = w == 0 and 1024 or w
        h = h == 0 and 512 or h

        self.read_transfer = {
            x = x,
            y = y,
            width = w,
            position = 0,
            remaining = w * h
        }

        return
    end

    if opcode == 0xE1 then
        self.draw_mode = bit.band(command, 0xFFFFFF)
        return
    end

    if opcode == 0xE2 then
        self.texture_window = bit.band(command, 0xFFFFFF)
        return
    end

    if opcode == 0xE3 then
        local value = bit.band(command, 0xFFFFFF)

        self.drawing_area_left = bit.band(value, 0x3FF)
        self.drawing_area_top =
            bit.band(bit.rshift(value, 10), 0x1FF)

        return
    end

    if opcode == 0xE4 then
        local value = bit.band(command, 0xFFFFFF)

        self.drawing_area_right = bit.band(value, 0x3FF)
        self.drawing_area_bottom =
            bit.band(bit.rshift(value, 10), 0x1FF)

        return
    end

    if opcode == 0xE5 then
        local value = bit.band(command, 0xFFFFFF)

        self.drawing_offset_x = signed11(value)
        self.drawing_offset_y = signed11(bit.rshift(value, 11))

        return
    end

    if opcode == 0xE6 then
        local value = bit.band(command, 0xFFFFFF)

        self.mask_set = bit.band(value, 1) ~= 0
        self.mask_check = bit.band(value, 2) ~= 0

        return
    end
end

function GPU:writeGP0(value)
    value = u32(value)

    if self.transfer then
        local t = self.transfer

        for i = 0, 1 do
            if t.remaining <= 0 then break end

            local pixel = bit.band(
                bit.rshift(value, i * 16),
                0xFFFF
            )

            local x = t.x + (t.position % t.width)
            local y = t.y + floor(t.position / t.width)

            self:writeRawPixel(x, y, pixel)

            t.position = t.position + 1
            t.remaining = t.remaining - 1
        end

        if t.remaining <= 0 then
            self.transfer = nil
        end

        return
    end

    self.command_buffer[#self.command_buffer + 1] = value

    while #self.command_buffer > 0 do
        local needed = self:getPacketLength(self.command_buffer[1])

        if #self.command_buffer < needed then
            break
        end

        local packet = {}

        for i = 1, needed do
            packet[i] = self.command_buffer[i]
        end

        for i = 1, needed do
            table.remove(self.command_buffer, 1)
        end

        self:executePacket(packet)
    end
end

function GPU:readGP0()
    if not self.read_transfer then
        return u32(self.gp0_read_latch or 0)
    end

    local t = self.read_transfer
    local result = 0

    for i = 0, 1 do
        if t.remaining <= 0 then break end

        local x = t.x + (t.position % t.width)
        local y = t.y + floor(t.position / t.width)

        local pixel = self:readPixel(x, y)

        result = bit.bor(
            result,
            bit.lshift(pixel, i * 16)
        )

        t.position = t.position + 1
        t.remaining = t.remaining - 1
    end

    if t.remaining <= 0 then
        self.read_transfer = nil
    end

    self.gp0_read_latch = u32(result)

    return self.gp0_read_latch
end

function GPU:writeGP1(value)
    value = u32(value)

    local command = byte(value, 24)
    local parameter = bit.band(value, 0xFFFFFF)

    if command == 0x00 then
        self:reset()

    elseif command == 0x01 then
        self.command_buffer = {}
        self.transfer = nil
        self.read_transfer = nil

    elseif command == 0x02 then
        self.status = bit.band(self.status, bit.bnot(0x01000000))

    elseif command == 0x03 then
        self.display_enabled = bit.band(parameter, 1) == 0
        self.image_dirty = true

    elseif command == 0x04 then
        self.dma_direction = bit.band(parameter, 3)

    elseif command == 0x05 then
        self.display_x = bit.band(parameter, 0x3FF)
        self.display_y = bit.band(
            bit.rshift(parameter, 10),
            0x1FF
        )

        self.image_dirty = true

    elseif command == 0x06 then
        self.horizontal_start = bit.band(parameter, 0xFFF)
        self.horizontal_end = bit.band(
            bit.rshift(parameter, 12),
            0xFFF
        )

    elseif command == 0x07 then
        self.vertical_start = bit.band(parameter, 0x3FF)
        self.vertical_end = bit.band(
            bit.rshift(parameter, 10),
            0x3FF
        )

    elseif command == 0x08 then
        self.display_mode = bit.band(parameter, 0xFF)
        self.image_dirty = true

    elseif command == 0x10 then
        local index = bit.band(parameter, 7)

        if index == 2 then
            self.gp0_read_latch = self.texture_window
        elseif index == 3 then
            self.gp0_read_latch =
                self.drawing_area_left
                + bit.lshift(self.drawing_area_top, 10)
        elseif index == 4 then
            self.gp0_read_latch =
                self.drawing_area_right
                + bit.lshift(self.drawing_area_bottom, 10)
        elseif index == 5 then
            self.gp0_read_latch =
                bit.band(self.drawing_offset_x, 0x7FF)
                + bit.lshift(
                    bit.band(self.drawing_offset_y, 0x7FF),
                    11
                )
        elseif index == 7 then
            self.gp0_read_latch = 2
        end
    end

    self.image_dirty = true
end

function GPU:readGP1()
    local status = 0x14002000

    if not self.display_enabled then
        status = bit.bor(status, 0x00800000)
    end

    status = bit.bor(status, bit.band(self.draw_mode, 0x1FFF))
    status = bit.bor(status, 0x04000000)
    status = bit.bor(status, 0x10000000)

    status = bit.bor(
        status,
        bit.lshift(self.dma_direction, 29)
    )

    if self.read_transfer then
        status = bit.bor(status, 0x08000000)
    end

    if bit.band(self.status, 0x01000000) ~= 0 then
        status = bit.bor(status, 0x01000000)
    end

    return u32(status)
end

function GPU:getDisplaySize()
    local horizontal = bit.band(self.display_mode, 3)

    local widths = {
        [0] = 256,
        [1] = 320,
        [2] = 512,
        [3] = 640
    }

    local width = widths[horizontal] or 320

    if bit.band(self.display_mode, 0x40) ~= 0 then
        width = 368
    end

    local height = 240

    if bit.band(self.display_mode, 0x04) ~= 0 then
        height = 480
    end

    return width, height
end

function GPU:refreshImage()
    if not love or not love.image or not love.graphics then
        return
    end

    local width, height = self:getDisplaySize()

    if not self.imageData
    or self.imageData:getWidth() ~= width
    or self.imageData:getHeight() ~= height then

        self.imageData = love.image.newImageData(width, height)
        self.image = nil
    end

    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local r, g, b = 0, 0, 0

            if self.display_enabled then
                local pixel = self:readPixel(
                    self.display_x + x,
                    self.display_y + y
                )

                r = bit.band(pixel, 0x1F) / 31
                g = bit.band(bit.rshift(pixel, 5), 0x1F) / 31
                b = bit.band(bit.rshift(pixel, 10), 0x1F) / 31
            end

            self.imageData:setPixel(x, y, r, g, b, 1)
        end
    end

    if not self.image then
        self.image = love.graphics.newImage(self.imageData)
        self.image:setFilter("nearest", "nearest")
    else
        self.image:replacePixels(self.imageData)
    end

    self.image_dirty = false
end

function GPU:getImage()
    if self.image_dirty then
        self:refreshImage()
    end

    return self.image
end

function GPU:update(cycles)
    self.cycles = self.cycles + (cycles or 1)
end

function GPU:getVRAM()
    return self.vram
end

-- Prueba visual: dibuja directamente en VRAM.
function GPU:debugDrawTest()
    self:reset()

    self.display_enabled = true
    self.display_x = 0
    self.display_y = 0
    self.display_mode = 1

    self.drawing_area_left = 0
    self.drawing_area_top = 0
    self.drawing_area_right = 1023
    self.drawing_area_bottom = 511

    self.drawing_offset_x = 0
    self.drawing_offset_y = 0

    -- Fondo azul oscuro.
    self:fillRect(0, 0, 320, 240, color555(12, 20, 55))

    -- Barras de color.
    self:fillRect(20, 20, 60, 35, color555(255, 0, 0))
    self:fillRect(90, 20, 60, 35, color555(0, 255, 0))
    self:fillRect(160, 20, 60, 35, color555(0, 100, 255))
    self:fillRect(230, 20, 60, 35, color555(255, 255, 255))

    -- Triángulos.
    self:drawTriangle(
        30, 90,
        150, 90,
        90, 200,
        color555(255, 220, 0)
    )

    self:drawTriangle(
        170, 90,
        290, 90,
        230, 200,
        color555(255, 0, 200)
    )

    -- Líneas.
    self:drawLine(0, 0, 319, 239, color555(255, 255, 255))
    self:drawLine(319, 0, 0, 239, color555(0, 255, 255))

    -- Rectángulo naranja.
    self:fillRect(125, 175, 70, 35, color555(255, 120, 0))

    self.image_dirty = true

    print("[GPU] Debug drawing test rendered")
end

return GPU
