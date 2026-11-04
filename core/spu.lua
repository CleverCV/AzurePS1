local SPU = {}
SPU.__index = SPU

function SPU.new()
    local self = setmetatable({}, SPU)

    self.voices = {}

    for i = 1, 24 do
        self.voices[i] = {
            volume_left = 0,
            volume_right = 0,
            pitch = 0,
            active = false,
            sample_position = 0
        }
    end

    self.master_volume_left = 0
    self.master_volume_right = 0

    self.sample_rate = 44100
    self.enabled = false

    return self
end

function SPU:reset()
    for i = 1, 24 do
        self.voices[i].active = false
        self.voices[i].sample_position = 0
    end

    self.enabled = false
end

function SPU:update(dt)
    if not self.enabled then
        return
    end

    -- Voice processing and ADPCM decoding.
end

return SPU