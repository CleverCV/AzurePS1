local Audio = {}
Audio.__index = Audio

function Audio.new()
    return setmetatable({
        enabled = true,
        volume = 1.0,
        sample_rate = 44100
    }, Audio)
end

function Audio:setVolume(value)
    self.volume = math.max(0, math.min(1, value))
end

function Audio:setEnabled(value)
    self.enabled = value
end

function Audio:update(dt)
    -- SPU audio streaming will be connected here.
end

return Audio