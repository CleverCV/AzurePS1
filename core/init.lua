
local Memory = require("core.memory")
local BIOS = require("core.bios")
local CPU = require("core.cpu")
local Interrupts = require("core.interrupts")
local GPU = require("core.gpu")

local Core = {}
Core.__index = Core

Core.CPU_FREQUENCY = 33868800

function Core.new()
    local self = setmetatable({}, Core)

    -- Interrupt controller
    self.interrupts = Interrupts.new()

    -- Memory
    self.memory = Memory.new()

    -- GPU
    self.gpu = GPU.new(self.interrupts)

    -- Connect GPU to memory bus
    self.memory:setGPU(self.gpu)

    -- CPU
    self.cpu = CPU.new(
        self.memory,
        self.interrupts
    )

    -- Emulator state
    self.running = false
    self.bios_loaded = false

    self.elapsed_time = 0
    self.frame_cycles = 0

    self.instructions_per_frame = 1000

    print("[AzurePS1] Core initialized")
    print("[AzurePS1] Memory connected")
    print("[AzurePS1] GPU connected")
    print("[AzurePS1] CPU connected")

    return self
end

function Core:loadBIOS(path)
    local success, err = BIOS.initialize(
        self.memory,
        path
    )

    if not success then
        self.bios_loaded = false
        print("[BIOS ERROR] " .. tostring(err))
        return false, err
    end

    self.bios_loaded = true

    print("[AzurePS1] BIOS ready")

    return true
end

function Core:reset()
    if not self.bios_loaded then
        return false, "BIOS is not loaded"
    end

    self.interrupts:reset()
    self.gpu:reset()
    self.cpu:reset()

    self.cpu.pc = 0xBFC00000

    self.running = false
    self.elapsed_time = 0
    self.frame_cycles = 0

    print("[AzurePS1] System reset")

    return true
end

function Core:start()
    if not self.bios_loaded then
        return false, "BIOS is not loaded"
    end

    local success, err = self:reset()

    if not success then
        return false, err
    end

    self.running = true
    self.cpu.running = true

    print("[AzurePS1] Emulation started")

    print(string.format(
        "[CPU] PC: 0x%08X",
        self.cpu.pc
    ))

    return true
end

function Core:stop()
    self.running = false
    self.cpu.running = false

    print("[AzurePS1] Emulation stopped")
end

function Core:step()
    if not self.bios_loaded then
        return false, "BIOS is not loaded"
    end

    if not self.running then
        return false, "Emulator is stopped"
    end

    local success, err = self.cpu:step()

    if not success then
        self:stop()
        return false, err
    end

    self.gpu:update(1)

    self.frame_cycles = self.frame_cycles + 1

    return true
end

function Core:run(instruction_count)
    if not self.running then
        return false, "Emulator is stopped"
    end

    instruction_count = instruction_count or 1000

    for i = 1, instruction_count do
        local success, err = self:step()

        if not success then
            return false, err
        end
    end

    return true
end

function Core:update(dt)
    if not self.running then
        return
    end

    self.elapsed_time = self.elapsed_time + dt

    local instruction_budget = self.instructions_per_frame

    local success, err = self:run(instruction_budget)

    if not success then
        print("[CPU ERROR] " .. tostring(err))
    end
end

function Core:getCPUState()
    return {
        pc = self.cpu.pc,
        hi = self.cpu.hi,
        lo = self.cpu.lo,
        cycles = self.cpu.cycles,
        registers = self.cpu.registers,
        cop0 = self.cpu.cop0,
        running = self.running
    }
end

function Core:getGPUState()
    return {
        width = self.gpu.vram_width,
        height = self.gpu.vram_height,
        display_enabled = self.gpu.display_enabled,
        cycles = self.gpu.cycles,
        command_count = #self.gpu.command_buffer
    }
end

return Core
