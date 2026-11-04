local Controller = {}
Controller.__index = Controller

function Controller.new()
    return setmetatable({
        buttons = {},
        connected = false
    }, Controller)
end

function Controller:press(button)
    self.buttons[button] = true
end

function Controller:release(button)
    self.buttons[button] = false
end

function Controller:isPressed(button)
    return self.buttons[button] == true
end

function Controller:reset()
    self.buttons = {}
end

return Controller