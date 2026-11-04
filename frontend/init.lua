
local Interface = require("frontend.interface")
local Renderer = require("frontend.renderer")

local Frontend = {}
Frontend.__index = Frontend

function Frontend.new(core)
    local self = setmetatable({}, Frontend)

    self.core = core
    self.interface = Interface.new()
    self.renderer = Renderer.new()
    self.gpu = core.gpu

    self.initialized = true
    self.wasRunning = false

    print("[Frontend] Interface initialized")
    print("[Frontend] Renderer initialized")
    print("[Frontend] GPU connected:", self.gpu ~= nil)
    print("[Frontend] Frontend ready")

    return self
end

function Frontend:update(dt)
    if not self.initialized then return end

    -- La ventana conserva su tamaño normal.
    -- No se activa el modo fullscreen.
end

function Frontend:draw()
    if not self.initialized then return end

    if self.core and self.core.running then
        -- Dibujar la imagen de la GPU en toda la ventana.
        self.renderer:draw(self.gpu)
    else
        -- Mostrar la interfaz cuando el emulador está detenido.
        self.interface:draw(self.core)
    end
end

function Frontend:mousepressed(x, y, button)
    if not self.initialized then return end

    -- No enviar clics a la interfaz durante la emulación.
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

return Frontend
