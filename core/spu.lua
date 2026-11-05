
local SPU = {}
SPU.__index = SPU

local bit = require("bit")

local SAMPLE_RATE = 44100
local VOICE_COUNT = 24
local SPU_RAM_SIZE = 512 * 1024

local ADPCM_FILTERS = {
    { 0, 0 },
    { 60, 0 },
    { 115, -52 },
    { 98, -55 },
    { 122, -60 }
}

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function signed16(value)
    value = bit.band(value, 0xFFFF)
    if value >= 0x8000 then
        return value - 0x10000
    end
    return value
end

function SPU.new()
    local self = setmetatable({}, SPU)

    self.ram = ffi and ffi.new("uint8_t[?]", SPU_RAM_SIZE) or nil
    self.ram_table = {}

    self.voices = {}

    for i = 1, VOICE_COUNT do
        self.voices[i] = {
            volume_left = 0,
            volume_right = 0,
            pitch = 0x1000,
            start_address = 0,
            repeat_address = 0,
            current_address = 0,

            decoded = {},
            decoded_index = 1,

            previous1 = 0,
            previous2 = 0,

            active = false,
            loop = false,
            end_flag = false
        }
    end

    self.registers = {}
    self.master_volume_left = 0x3FFF
    self.master_volume_right = 0x3FFF

    self.control = 0
    self.status = 0

    self.transfer_address = 0
    self.transfer_fifo = {}

    self.output_left = {}
    self.output_right = {}

    self.sample_rate = SAMPLE_RATE
    self.enabled = true

    return self
end

function SPU:readRAM8(address)
    address = bit.band(address, SPU_RAM_SIZE - 1)

    if self.ram then
        return tonumber(self.ram[address])
    end

    return self.ram_table[address] or 0
end

function SPU:writeRAM8(address, value)
    address = bit.band(address, SPU_RAM_SIZE - 1)
    value = bit.band(value, 0xFF)

    if self.ram then
        self.ram[address] = value
    else
        self.ram_table[address] = value
    end
end

function SPU:readRAM16(address)
    local lo = self:readRAM8(address)
    local hi = self:readRAM8(address + 1)

    return lo + hi * 256
end

function SPU:writeRAM16(address, value)
    self:writeRAM8(address, bit.band(value, 0xFF))
    self:writeRAM8(address + 1, bit.rshift(value, 8))
end

function SPU:decodeBlock(address, voice)
    local header = self:readRAM8(address)
    local flags = self:readRAM8(address + 1)

    local shift = bit.band(header, 0x0F)
    local filter = bit.rshift(header, 4)

    if filter > 4 then
        filter = 0
    end

    local coefficients = ADPCM_FILTERS[filter + 1]
    local decoded = {}

    for i = 0, 27 do
        local packed = self:readRAM8(address + 2 + math.floor(i / 2))
        local nibble

        if i % 2 == 0 then
            nibble = bit.band(packed, 0x0F)
        else
            nibble = bit.rshift(packed, 4)
        end

        if nibble >= 8 then
            nibble = nibble - 16
        end

        local sample = bit.arshift(nibble * 4096, shift)

        sample = sample
            + math.floor((voice.previous1 * coefficients[1]
            + voice.previous2 * coefficients[2] + 32) / 64)

        sample = clamp(sample, -32768, 32767)

        voice.previous2 = voice.previous1
        voice.previous1 = sample

        decoded[#decoded + 1] = sample
    end

    voice.decoded = decoded
    voice.decoded_index = 1

    return flags
end

function SPU:startVoice(index)
    local voice = self.voices[index]

    voice.current_address = bit.band(voice.start_address, 0x7FFFF)
    voice.previous1 = 0
    voice.previous2 = 0
    voice.decoded = {}
    voice.decoded_index = 1
    voice.active = true
    voice.end_flag = false
end

function SPU:stopVoice(index)
    local voice = self.voices[index]

    voice.active = false
    voice.decoded = {}
    voice.decoded_index = 1
end

function SPU:nextVoiceSample(voice)
    if not voice.active then
        return 0
    end

    if voice.decoded_index > #voice.decoded then
        local flags = self:decodeBlock(voice.current_address, voice)

        voice.current_address = bit.band(
            voice.current_address + 16,
            SPU_RAM_SIZE - 1
        )

        if bit.band(flags, 0x01) ~= 0 then
            voice.loop = true
        end

        if bit.band(flags, 0x02) ~= 0 then
            voice.end_flag = true
        end

        if bit.band(flags, 0x04) ~= 0 then
            voice.current_address = bit.band(
                voice.repeat_address,
                SPU_RAM_SIZE - 1
            )
        end
    end

    local sample = voice.decoded[voice.decoded_index] or 0
    voice.decoded_index = voice.decoded_index + 1

    if voice.end_flag and voice.decoded_index > #voice.decoded then
        if voice.loop then
            voice.current_address = bit.band(
                voice.repeat_address,
                SPU_RAM_SIZE - 1
            )
            voice.end_flag = false
        else
            voice.active = false
        end
    end

    return sample
end

function SPU:writeRegister(address, value)
    address = bit.band(address, 0x3FF)
    value = bit.band(value, 0xFFFF)

    self.registers[address] = value

    if address < 0x180 then
        local voice_index = math.floor(address / 0x10) + 1
        local offset = address % 0x10
        local voice = self.voices[voice_index]

        if not voice then return end

        if offset == 0x0 then
            voice.volume_left = signed16(value)
        elseif offset == 0x2 then
            voice.volume_right = signed16(value)
        elseif offset == 0x4 then
            voice.pitch = bit.band(value, 0x3FFF)
        elseif offset == 0x6 then
            voice.start_address = bit.band(value * 8, 0x7FFFF)
        elseif offset == 0xE then
            voice.repeat_address = bit.band(value * 8, 0x7FFFF)
        end

        return
    end

    if address == 0x180 then
        self.master_volume_left = signed16(value)
    elseif address == 0x182 then
        self.master_volume_right = signed16(value)

    elseif address == 0x188 or address == 0x18A then
        local base = address == 0x188 and 0 or 16

        for i = 0, 15 do
            if bit.band(value, bit.lshift(1, i)) ~= 0 then
                local voice_index = base + i + 1

                if voice_index <= VOICE_COUNT then
                    self:startVoice(voice_index)
                end
            end
        end

    elseif address == 0x18C or address == 0x18E then
        local base = address == 0x18C and 0 or 16

        for i = 0, 15 do
            if bit.band(value, bit.lshift(1, i)) ~= 0 then
                local voice_index = base + i + 1

                if voice_index <= VOICE_COUNT then
                    self:stopVoice(voice_index)
                end
            end
        end

    elseif address == 0x1A6 then
        self.transfer_address = bit.band(value * 8, 0x7FFFF)

    elseif address == 0x1A8 then
        self:writeRAM16(self.transfer_address, value)
        self.transfer_address = bit.band(
            self.transfer_address + 2,
            SPU_RAM_SIZE - 1
        )

    elseif address == 0x1AA then
        self.control = value
        self.enabled = bit.band(value, 0x4000) ~= 0
        self.status = bit.band(value, 0x3F)

    end
end

function SPU:readRegister(address)
    address = bit.band(address, 0x3FF)

    if address == 0x1AA then
        return self.control
    elseif address == 0x1AE then
        return self.status
    elseif address == 0x1A8 then
        local value = self:readRAM16(self.transfer_address)

        self.transfer_address = bit.band(
            self.transfer_address + 2,
            SPU_RAM_SIZE - 1
        )

        return value
    end

    return self.registers[address] or 0
end

function SPU:generateSamples(count)
    local left = {}
    local right = {}

    for sample_index = 1, count do
        local mix_left = 0
        local mix_right = 0

        if self.enabled then
            for i = 1, VOICE_COUNT do
                local voice = self.voices[i]

                if voice.active then
                    local sample = self:nextVoiceSample(voice)

                    mix_left = mix_left
                        + sample * voice.volume_left / 32768

                    mix_right = mix_right
                        + sample * voice.volume_right / 32768
                end
            end

            mix_left = mix_left * self.master_volume_left / 32768
            mix_right = mix_right * self.master_volume_right / 32768
        end

        left[sample_index] = clamp(mix_left / 32768, -1, 1)
        right[sample_index] = clamp(mix_right / 32768, -1, 1)
    end

    self.output_left = left
    self.output_right = right

    return left, right
end

function SPU:update(dt)
    if not self.enabled then
        self.output_left = {}
        self.output_right = {}
        return
    end

    local count = math.floor(dt * self.sample_rate)

    if count <= 0 then
        return
    end

    self:generateSamples(count)
end

function SPU:consumeSamples()
    local left = self.output_left
    local right = self.output_right

    self.output_left = {}
    self.output_right = {}

    return left, right
end

function SPU:reset()
    for i = 1, VOICE_COUNT do
        self:stopVoice(i)

        local voice = self.voices[i]

        voice.volume_left = 0
        voice.volume_right = 0
        voice.pitch = 0x1000
        voice.start_address = 0
        voice.repeat_address = 0
        voice.current_address = 0
        voice.previous1 = 0
        voice.previous2 = 0
        voice.loop = false
        voice.end_flag = false
    end

    self.registers = {}
    self.master_volume_left = 0x3FFF
    self.master_volume_right = 0x3FFF
    self.control = 0
    self.status = 0
    self.transfer_address = 0
    self.output_left = {}
    self.output_right = {}
    self.enabled = false
end

return SPU
