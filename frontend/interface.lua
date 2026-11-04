
local Interface = {}
Interface.__index = Interface

local colors = {
    background = {0.035, 0.045, 0.075},
    panel = {0.065, 0.085, 0.13},
    blue = {0.20, 0.52, 1.0},
    text = {0.90, 0.93, 1.0},
    muted = {0.48, 0.55, 0.68},
    green = {0.25, 0.85, 0.55},
    red = {1.0, 0.30, 0.35},
    yellow = {1.0, 0.75, 0.25}
}

function Interface.new()
    local self = setmetatable({}, Interface)

    self.page = "home"
    self.selected_game = nil
    self.core = nil

    self.status = "Ready"
    self.status_color = colors.muted

    self.buttons = {
        {name = "Home", page = "home"},
        {name = "Games", page = "games"},
        {name = "BIOS", page = "bios"},
        {name = "Debugger", page = "debugger"},
        {name = "Settings", page = "settings"}
    }

    self.start_button = {
        x = 250,
        y = 495,
        width = 180,
        height = 48
    }

    return self
end

function Interface:setPage(page)
    self.page = page
end

function Interface:setStatus(message, color)
    self.status = tostring(message)
    self.status_color = color or colors.muted
end

function Interface:drawButton(x, y, width, height, label, active)
    local color = active and colors.blue or colors.panel

    love.graphics.setColor(color)
    love.graphics.rectangle(
        "fill",
        x, y, width, height, 7, 7
    )

    love.graphics.setColor(colors.text)
    love.graphics.printf(
        label,
        x,
        y + height / 2 - 8,
        width,
        "center"
    )
end

function Interface:drawSidebar()
    love.graphics.setColor(colors.panel)

    love.graphics.rectangle(
        "fill",
        0, 0,
        220,
        love.graphics.getHeight()
    )

    love.graphics.setColor(colors.blue)
    love.graphics.print("AzurePS1", 25, 28)

    love.graphics.setColor(colors.muted)
    love.graphics.print("PLAYSTATION EMULATOR", 25, 55)

    for i, button in ipairs(self.buttons) do
        self:drawButton(
            15,
            105 + (i - 1) * 55,
            190,
            43,
            button.name,
            self.page == button.page
        )
    end
end

function Interface:drawHome()
    love.graphics.setColor(colors.text)
    love.graphics.print("Welcome to AzurePS1", 250, 45)

    love.graphics.setColor(colors.muted)
    love.graphics.print("PlayStation 1 Emulator", 250, 75)

    local x, y = 250, 140

    love.graphics.setColor(colors.panel)
    love.graphics.rectangle(
        "fill", x, y, 650, 330, 12, 12
    )

    love.graphics.setColor(colors.blue)
    love.graphics.printf(
        "PSX DISPLAY",
        x, y + 20, 650,
        "center"
    )

    love.graphics.setColor(0.01, 0.01, 0.02)

    love.graphics.rectangle(
        "fill",
        x + 25, y + 60,
        600, 240,
        5, 5
    )

    love.graphics.setColor(colors.muted)

    love.graphics.printf(
        self.core and self.core.running
            and "PlayStation emulation running"
            or "No game running",
        x + 25, y + 165,
        600,
        "center"
    )

    local b = self.start_button
    local running = self.core and self.core.running

    local label = running and "STOP" or "START"
    local color = running and colors.red or colors.green

    love.graphics.setColor(color)

    love.graphics.rectangle(
        "fill",
        b.x, b.y,
        b.width, b.height,
        8, 8
    )

    love.graphics.setColor(colors.background)

    love.graphics.printf(
        label,
        b.x,
        b.y + 15,
        b.width,
        "center"
    )

    love.graphics.setColor(colors.muted)

    if self.core and self.core.bios_loaded then
        love.graphics.print("BIOS: READY", 450, 510)
    else
        love.graphics.print("BIOS: NOT LOADED", 450, 510)
    end

    love.graphics.setColor(self.status_color)

    love.graphics.print(
        "Status: " .. self.status,
        250, 565
    )
end

function Interface:drawGames()
    love.graphics.setColor(colors.text)
    love.graphics.print("Game Library", 250, 45)

    love.graphics.setColor(colors.muted)
    love.graphics.print(
        "Your PlayStation games will appear here.",
        250, 85
    )
end

function Interface:drawBIOS()
    love.graphics.setColor(colors.text)
    love.graphics.print("BIOS Manager", 250, 45)

    love.graphics.setColor(colors.muted)
    love.graphics.print(
        "BIOS files are loaded from the bios/ directory.",
        250, 85
    )

    if self.core and self.core.bios_loaded then
        love.graphics.setColor(colors.green)
        love.graphics.print(
            "SCPH1001.BIN - LOADED",
            250, 130
        )
    else
        love.graphics.setColor(colors.red)
        love.graphics.print(
            "BIOS NOT LOADED",
            250, 130
        )
    end
end

function Interface:drawDebugger(core)
    love.graphics.setColor(colors.text)
    love.graphics.print("CPU Debugger", 250, 45)

    if not core then return end

    love.graphics.setColor(colors.muted)

    love.graphics.print(
        string.format("PC: %08X", core.cpu.pc),
        250, 100
    )

    love.graphics.print(
        "Cycles: " .. tostring(core.cpu.cycles),
        250, 130
    )

    for i = 0, 31 do
        local x = 250 + (i % 4) * 175
        local y = 180 + math.floor(i / 4) * 35

        love.graphics.setColor(colors.text)

        love.graphics.print(
            string.format(
                "R%-2d: %08X",
                i,
                core.cpu.registers[i]
            ),
            x, y
        )
    end
end

function Interface:drawSettings()
    love.graphics.setColor(colors.text)
    love.graphics.print("Settings", 250, 45)

    love.graphics.setColor(colors.muted)
    love.graphics.print(
        "AzurePS1 configuration",
        250, 85
    )
end

function Interface:draw(core)
    if core then
        self.core = core
    end

    love.graphics.setColor(colors.background)

    love.graphics.rectangle(
        "fill",
        0, 0,
        love.graphics.getWidth(),
        love.graphics.getHeight()
    )

    self:drawSidebar()

    if self.page == "home" then
        self:drawHome()
    elseif self.page == "games" then
        self:drawGames()
    elseif self.page == "bios" then
        self:drawBIOS()
    elseif self.page == "debugger" then
        self:drawDebugger(self.core)
    elseif self.page == "settings" then
        self:drawSettings()
    end

    love.graphics.setColor(1, 1, 1, 1)
end

function Interface:mousepressed(x, y, button, core)
    if button ~= 1 then return end

    core = core or self.core

    -- START / STOP
    if self.page == "home" then
        local b = self.start_button

        if x >= b.x and x <= b.x + b.width
        and y >= b.y and y <= b.y + b.height then

            print("[UI] START button pressed")

            if not core then
                self:setStatus(
                    "Core unavailable",
                    colors.red
                )
                return
            end

            if core.running then
                core:stop()

                self:setStatus(
                    "Emulation stopped",
                    colors.red
                )

                return
            end

            if not core.bios_loaded then
                self:setStatus(
                    "BIOS not loaded",
                    colors.red
                )
                return
            end

            local success, err = core:start()

            if success then
                self:setStatus(
                    "BIOS boot started",
                    colors.green
                )

                print("[UI] BIOS boot started")
            else
                self:setStatus(
                    err or "Unable to start",
                    colors.red
                )

                print("[START ERROR] " .. tostring(err))
            end

            return
        end
    end

    -- Sidebar navigation
    for i, item in ipairs(self.buttons) do
        local by = 105 + (i - 1) * 55

        if x >= 15 and x <= 205
        and y >= by and y <= by + 43 then

            self.page = item.page
            return
        end
    end
end

return Interface
