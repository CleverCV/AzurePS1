local Input = {}
Input.__index = Input

local keymap = {
    up = "up",
    down = "down",
    left = "left",
    right = "right",

    z = "cross",
    x = "circle",
    a = "square",
    s = "triangle",

    q = "l1",
    w = "r1",

    ["return"] = "start",
    ["backspace"] = "select"
}

function Input.new(controller)
    return setmetatable({
        controller = controller,
        keymap = keymap
    }, Input)
end

function Input:keypressed(key)
    local button = self.keymap[key]

    if button then
        self.controller:press(button)
    end
end

function Input:keyreleased(key)
    local button = self.keymap[key]

    if button then
        self.controller:release(button)
    end
end

return Input