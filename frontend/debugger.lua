local Debugger = {}
Debugger.__index = Debugger

function Debugger.new(core)
    return setmetatable({
        core = core,
        enabled = false,
        paused = true,
        logs = {}
    }, Debugger)
end

function Debugger:log(message)
    self.logs[#self.logs + 1] = tostring(message)

    if #self.logs > 100 then
        table.remove(self.logs, 1)
    end
end

function Debugger:toggle()
    self.enabled = not self.enabled
end

function Debugger:pause()
    self.paused = true
end

function Debugger:resume()
    self.paused = false
end

function Debugger:step()
    if self.core and self.core.running then
        self.core:step()
    end
end

function Debugger:getCPUState()
    if not self.core then
        return nil
    end

    return {
        pc = self.core.cpu.pc,
        cycles = self.core.cpu.cycles,
        registers = self.core.cpu.registers
    }
end

return Debugger