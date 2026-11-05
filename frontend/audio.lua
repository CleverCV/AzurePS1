
local Audio = {}
Audio.__index = Audio

local SAMPLE_RATE = 44100
local CHANNELS = 2
local BITS = 16
local BUFFER_COUNT = 8

function Audio.new()
    local self = setmetatable({}, Audio)

    self.source = nil
    self.enabled = true
    self.volume = 0.7
    self.initialized = false

    self:initialize()

    return self
end

function Audio:initialize()
    if not love or not love.audio or not love.sound then
        print("[Audio] LÖVE audio unavailable")
        return false
    end

    local success, source = pcall(
        love.audio.newQueueableSource,
        SAMPLE_RATE,
        BITS,
        CHANNELS,
        BUFFER_COUNT
    )

    if not success or not source then
        print("[Audio] Failed to create queueable source")
        return false
    end

    self.source = source
    self.source:setVolume(self.volume)
    self.initialized = true

    print("[Audio] Queueable source initialized")

    return true
end

function Audio:queue(left, right)
    if not self.initialized or not self.enabled then
        return false
    end

    if not left or not right then
        return false
    end

    local count = math.min(#left, #right)

    if count == 0 then
        return false
    end

    local success, soundData = pcall(
        love.sound.newSoundData,
        count,
        SAMPLE_RATE,
        BITS,
        CHANNELS
    )

    if not success or not soundData then
        return false
    end

    for i = 1, count do
        soundData:setSample(
            i - 1,
            1,
            math.max(-1, math.min(1, left[i] or 0))
        )

        soundData:setSample(
            i - 1,
            2,
            math.max(-1, math.min(1, right[i] or 0))
        )
    end

    local queued, err = pcall(
        self.source.queue,
        self.source,
        soundData
    )

    if not queued then
        print("[Audio] Queue error: " .. tostring(err))
        return false
    end

    if not self.source:isPlaying() then
        self.source:play()
    end

    return true
end

function Audio:update(dt, spu)
    if not self.initialized or not self.enabled then
        return
    end

    if not spu or type(spu.consumeSamples) ~= "function" then
        return
    end

    local left, right = spu:consumeSamples()

    if left and right then
        self:queue(left, right)
    end
end

function Audio:stop()
    if not self.source then
        return
    end

    pcall(function()
        self.source:stop()
    end)

    -- No llamar clearQueue(): no está disponible
    -- en todas las versiones de LÖVE.
end

function Audio:play()
    if not self.initialized or not self.enabled then
        return
    end

    if self.source and not self.source:isPlaying() then
        self.source:play()
    end
end

function Audio:setEnabled(enabled)
    self.enabled = not not enabled

    if not self.enabled then
        self:stop()
    end
end

function Audio:setVolume(volume)
    self.volume = math.max(0, math.min(1, volume))

    if self.source then
        self.source:setVolume(self.volume)
    end
end

function Audio:isPlaying()
    return self.source ~= nil and self.source:isPlaying()
end

function Audio:shutdown()
    self:stop()

    if self.source then
        pcall(function()
            self.source:release()
        end)
    end

    self.source = nil
    self.initialized = false
end

return Audio
