
local Core = require("core.init")
local Frontend = require("frontend.init")

local app = {
    core = nil,
    frontend = nil,
    status = "Initializing AzurePS1...",
    error = nil,
    gpu_test = false
}

function love.load()
    love.window.setTitle("AzurePS1 - PlayStation Emulator")

    love.window.setMode(1280, 720, {
        resizable = true,
        minwidth = 850,
        minheight = 500,
        vsync = 1,
        fullscreen = false
    })

    love.graphics.setDefaultFilter("nearest", "nearest")

    print("================================")
    print("          AzurePS1")
    print("    PlayStation 1 Emulator")
    print("================================")

    local coreSuccess, coreResult = pcall(Core.new)

    if not coreSuccess then
        app.error = tostring(coreResult)
        app.status = "Core initialization failed"
        print("[CORE ERROR] " .. app.error)
        return
    end

    app.core = coreResult

    local frontendSuccess, frontendResult = pcall(
        Frontend.new,
        app.core
    )

    if not frontendSuccess then
        app.error = tostring(frontendResult)
        app.status = "Frontend initialization failed"
        print("[FRONTEND ERROR] " .. app.error)
        return
    end

    app.frontend = frontendResult

    local success, err = app.core:loadBIOS(
        "bios/SCPH1001.BIN"
    )

    if success then
        app.status = "BIOS loaded successfully"
        print("[AzurePS1] BIOS loaded")
    else
        app.status = "BIOS loading failed"
        app.error = tostring(err)
        print("[BIOS ERROR] " .. app.error)
    end

    app.frontend:setPage("home")
end

function love.update(dt)
    if app.core and not app.gpu_test then
        app.core:update(dt)
    end

    if app.frontend then
        app.frontend:update(dt)
    end
end

function love.draw()
    if app.frontend then
        app.frontend:draw()
    else
        love.graphics.clear(0, 0, 0, 1)
    end

    -- GPU test overrides the normal frontend display.
    if app.gpu_test and app.core and app.core.gpu then
        love.graphics.clear(0.02, 0.02, 0.04, 1)

        local renderer = app.frontend and app.frontend.renderer

        if renderer then
            renderer:draw(app.core.gpu)
        else
            local image = app.core.gpu:getImage()

            if image then
                local sw = love.graphics.getWidth() / image:getWidth()
                local sh = love.graphics.getHeight() / image:getHeight()
                local scale = math.min(sw, sh)

                love.graphics.setColor(1, 1, 1, 1)

                love.graphics.draw(
                    image,
                    (love.graphics.getWidth() - image:getWidth() * scale) / 2,
                    (love.graphics.getHeight() - image:getHeight() * scale) / 2,
                    0,
                    scale,
                    scale
                )
            end
        end

        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.print("AZUREPS1 GPU DEBUG TEST | F2: Exit", 15, 15)
    end

    if not (app.core and app.core.running) and not app.gpu_test then
        love.graphics.setColor(0.48, 0.55, 0.68, 1)

        love.graphics.print(
            "AzurePS1 | " .. app.status,
            235,
            love.graphics.getHeight() - 25
        )

        if app.error then
            love.graphics.setColor(1, 0.3, 0.35, 1)

            love.graphics.print(
                app.error,
                235,
                love.graphics.getHeight() - 45
            )
        end
    end

    love.graphics.setColor(1, 1, 1, 1)
end

function love.mousepressed(x, y, button)
    if not app.frontend or app.gpu_test then return end

    app.frontend:mousepressed(x, y, button)
end

function love.keypressed(key)
    if key == "escape" then
        if app.gpu_test then
            app.gpu_test = false
            return
        end

        if app.core and app.core.running then
            app.core:stop()
            return
        end

        love.event.quit()
        return
    end

    if key == "f2" then
        if app.core and app.core.gpu then
            if not app.gpu_test then
                app.core.gpu:debugDrawTest()
                app.gpu_test = true
                print("[AzurePS1] GPU test enabled")
            else
                app.gpu_test = false
                print("[AzurePS1] GPU test disabled")
            end
        end

        return
    end

    if key == "f11" then
        local fullscreen = love.window.getFullscreen()
        love.window.setFullscreen(not fullscreen, "desktop")
        return
    end

    if app.frontend and not app.gpu_test then
        app.frontend:keypressed(key)
    end
end

function love.quit()
    if app.core and app.core.running then
        app.core:stop()
    end

    print("[AzurePS1] Shutdown")
end
