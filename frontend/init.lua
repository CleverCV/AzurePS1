
local Interface = require("frontend.interface")
local Renderer = require("frontend.renderer")
local Audio = require("frontend.audio")

local Frontend = {}
Frontend.__index = Frontend

function Frontend.new(core)
    local self = setmetatable({}, Frontend)

    self.core = core
    self.interface = Interface.new()
    self.renderer = Renderer.new()
    self.audio = Audio.new()
    self.gpu = core.gpu

    self.initialized = true
    self.wasRunning = false

    print("[Frontend] Interface initialized")
    print("[Frontend] Renderer initialized")
    print("[Frontend] Audio initialized")
    print("[Frontend] GPU connected:", self.gpu ~= nil)
    print("[Frontend] Frontend ready")

    return self
end

function Frontend:update(dt)
    if not self.initialized then return end

    if self.core and self.core.running then
        self.audio:update(dt, self.core.spu)
        self.wasRunning = true
    elseif self.wasRunning then
        self.audio:stop()
        self.wasRunning = false
    end
end

function Frontend:draw()
    if not self.initialized then return end

    if self.core and self.core.running then
        self.renderer:draw(self.gpu)
    else
        self.interface:draw(self.core)
    end
end

function Frontend:mousepressed(x, y, button)
    if not self.initialized then return end

    if self.core and self.core.running then
        return
    end

    self.interface:mousepressed(
        x,
        y,
        button,
        self.core
    )
end

function Frontend:keypressed(key)
    if not self.initialized then return end

    if key == "f1" then
        if self.core.running then
            self.core:stop()
            self.audio:stop()
            self.wasRunning = false
            print("[Frontend] Emulation stopped")
        else
            local success, err = self.core:start()

            if not success then
                print("[Frontend] " .. tostring(err))
            else
                print("[Frontend] Emulation started")
            end
        end
    end
end

function Frontend:setPage(page)
    self.interface:setPage(page)
end

function Frontend:setAudioEnabled(enabled)
    self.audio:setEnabled(enabled)
end

function Frontend:setAudioVolume(volume)
    self.audio:setVolume(volume)
end

function Frontend:shutdown()
    if self.audio then
        self.audio:destroy()
    end
end

return Frontend
