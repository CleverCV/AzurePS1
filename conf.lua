
function love.conf(t)
    t.identity = "AzurePS1"
    t.version = "11.5"

    t.window.title = "AzurePS1 - PlayStation 1 Emulator"
    t.window.width = 1280
    t.window.height = 720
    t.window.resizable = true
    t.window.vsync = 1
    t.window.msaa = 0
    t.window.fullscreen = false

    t.modules.joystick = true
    t.modules.audio = true
    t.modules.graphics = true
end
