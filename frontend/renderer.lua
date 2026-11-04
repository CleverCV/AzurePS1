-- frontend/renderer.lua
-- AzurePS1 - PS1 GPU Renderer
-- Compatible con LÖVE2D / LuaJIT

local Renderer = {}
Renderer.__index = Renderer

function Renderer.new()
    local self = setmetatable({}, Renderer)

    -- Configuración de pantalla
    self.width = 640
    self.height = 480

    self.enabled = true
    self.scale_mode = "stretch"

    -- Filtros: nearest evita que los píxeles se vean borrosos
    self.filter = "nearest"

    -- Shaders desactivados inicialmente para evitar pantallas negras
    self.shaders = {}
    self.activeShader = nil

    -- Información de depuración
    self.lastError = nil
    self.lastImageWidth = 0
    self.lastImageHeight = 0
    self.framesRendered = 0

    return self
end

-- =========================================================
-- CONFIGURACIÓN
-- =========================================================

function Renderer:setEnabled(enabled)
    self.enabled = enabled == true
end

function Renderer:setScaleMode(mode)
    if mode == "stretch" or mode == "fit" or mode == "integer" then
        self.scale_mode = mode
    end
end

function Renderer:setFilter(filter)
    if filter == "nearest" or filter == "linear" then
        self.filter = filter
    end
end

function Renderer:setShader(name)
    if name == nil or name == "none" then
        self.activeShader = nil
        return true
    end

    if self.shaders[name] then
        self.activeShader = name
        return true
    end

    return false
end

function Renderer:loadShaders()
    local shaderFiles = {
        "psx",
        "crt",
        "texture",
        "dithering",
        "passthrough"
    }

    self.shaders = {}

    for _, name in ipairs(shaderFiles) do
        local path = "shaders/" .. name .. ".glsl"

        local success, shader = pcall(
            love.graphics.newShader,
            path
        )

        if success and shader then
            self.shaders[name] = shader
            print("[RENDERER] Shader cargado: " .. name)
        else
            print("[RENDERER] No se pudo cargar " .. name .. ": " .. tostring(shader))
        end
    end
end

-- =========================================================
-- OBTENER IMAGEN DE LA GPU
-- =========================================================

function Renderer:getGPUImage(gpu)
    if not gpu then
        self.lastError = "GPU no disponible"
        return nil
    end

    if type(gpu.getImage) ~= "function" then
        self.lastError = "La GPU no tiene getImage()"
        return nil
    end

    local success, image = pcall(function()
        return gpu:getImage()
    end)

    if not success then
        self.lastError = tostring(image)
        print("[RENDERER] Error obteniendo imagen: " .. self.lastError)
        return nil
    end

    if not image then
        self.lastError = "La GPU devolvió una imagen nil"
        return nil
    end

    if type(image.getWidth) ~= "function"
        or type(image.getHeight) ~= "function" then
        self.lastError = "El objeto devuelto no es una imagen válida"
        return nil
    end

    self.lastError = nil
    return image
end

-- =========================================================
-- ESCALADO
-- =========================================================

function Renderer:getScale(imageWidth, imageHeight, screenWidth, screenHeight)
    local scaleX = screenWidth / imageWidth
    local scaleY = screenHeight / imageHeight

    if self.scale_mode == "stretch" then
        return scaleX, scaleY, 0, 0
    end

    if self.scale_mode == "fit" then
        local scale = math.min(scaleX, scaleY)

        local drawWidth = imageWidth * scale
        local drawHeight = imageHeight * scale

        local offsetX = (screenWidth - drawWidth) / 2
        local offsetY = (screenHeight - drawHeight) / 2

        return scale, scale, offsetX, offsetY
    end

    if self.scale_mode == "integer" then
        local scale = math.floor(math.min(scaleX, scaleY))

        if scale < 1 then
            scale = 1
        end

        local drawWidth = imageWidth * scale
        local drawHeight = imageHeight * scale

        local offsetX = (screenWidth - drawWidth) / 2
        local offsetY = (screenHeight - drawHeight) / 2

        return scale, scale, offsetX, offsetY
    end

    return scaleX, scaleY, 0, 0
end

-- =========================================================
-- SHADERS
-- =========================================================

function Renderer:sendShaderUniforms(shader)
    if not shader then
        return
    end

    local screenWidth = love.graphics.getWidth()
    local screenHeight = love.graphics.getHeight()

    pcall(function()
        if shader:hasUniform("screenSize") then
            shader:send("screenSize", {
                screenWidth,
                screenHeight
            })
        end
    end)

    pcall(function()
        if shader:hasUniform("time") then
            shader:send("time", love.timer.getTime())
        end
    end)
end

-- =========================================================
-- DIBUJAR GPU
-- =========================================================

function Renderer:draw(gpu)
    if not self.enabled then
        return
    end

    love.graphics.clear(0, 0, 0, 1)

    local image = self:getGPUImage(gpu)

    if not image then
        return
    end

    local imageWidth = image:getWidth()
    local imageHeight = image:getHeight()

    if imageWidth <= 0 or imageHeight <= 0 then
        self.lastError = "Dimensiones de imagen inválidas"
        return
    end

    self.lastImageWidth = imageWidth
    self.lastImageHeight = imageHeight

    local screenWidth = love.graphics.getWidth()
    local screenHeight = love.graphics.getHeight()

    if screenWidth <= 0 or screenHeight <= 0 then
        return
    end

    local scaleX, scaleY, offsetX, offsetY =
        self:getScale(
            imageWidth,
            imageHeight,
            screenWidth,
            screenHeight
        )

    -- Guardar el estado gráfico para no afectar la interfaz
    love.graphics.push("all")

    -- Reiniciar transformaciones y recortes anteriores
    love.graphics.origin()
    love.graphics.setScissor()

    -- Filtro de imagen
    image:setFilter(self.filter, self.filter)

    -- Color blanco para no oscurecer la imagen
    love.graphics.setColor(1, 1, 1, 1)

    -- Shader opcional
    local shader = nil

    if self.activeShader then
        shader = self.shaders[self.activeShader]
    end

    if shader then
        self:sendShaderUniforms(shader)
        love.graphics.setShader(shader)
    else
        love.graphics.setShader()
    end

    -- Dibujar la imagen de la GPU
    love.graphics.draw(
        image,
        offsetX,
        offsetY,
        0,
        scaleX,
        scaleY
    )

    -- Restaurar estado
    love.graphics.setShader()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.pop()

    self.framesRendered = self.framesRendered + 1
end

-- =========================================================
-- INFORMACIÓN DE DEPURACIÓN
-- =========================================================

function Renderer:getInfo()
    return {
        enabled = self.enabled,
        scale_mode = self.scale_mode,
        filter = self.filter,
        activeShader = self.activeShader,
        imageWidth = self.lastImageWidth,
        imageHeight = self.lastImageHeight,
        framesRendered = self.framesRendered,
        lastError = self.lastError
    }
end

function Renderer:reset()
    self.lastError = nil
    self.lastImageWidth = 0
    self.lastImageHeight = 0
    self.framesRendered = 0
end

return Renderer