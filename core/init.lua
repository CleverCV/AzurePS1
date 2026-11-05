
local Memory = require("core.memory")
local BIOS = require("core.bios")
local CPU = require("core.cpu")
local GTE = require("core.gte")
local Interrupts = require("core.interrupts")
local GPU = require("core.gpu")

local Core = {}
Core.__index = Core

Core.CPU_FREQUENCY = 33868800
Core.DEFAULT_INSTRUCTIONS_PER_FRAME = 25000
Core.EXCEPTION_VECTOR = 0x80000080

local function safeCall(object, method, ...)
    if not object or type(object[method]) ~= "function" then
        return true
    end

    return pcall(object[method], object, ...)
end

function Core.new()
    local self = setmetatable({}, Core)

    -- Sistema de interrupciones.
    self.interrupts = Interrupts.new()

    -- Memoria principal.
    self.memory = Memory.new()

    -- GPU.
    self.gpu = GPU.new(self.interrupts)

    if type(self.memory.setGPU) == "function" then
        self.memory:setGPU(self.gpu)
    end

    -- Conectar interrupciones al bus si la memoria lo soporta.
    if type(self.memory.setInterrupts) == "function" then
        self.memory:setInterrupts(self.interrupts)
    end

    -- Geometry Transformation Engine.
    self.gte = GTE.new()

    -- CPU MIPS R3000A.
    self.cpu = CPU.new(
        self.memory,
        self.interrupts,
        self.gte
    )

    if type(self.cpu.setGTE) == "function" then
        self.cpu:setGTE(self.gte)
    end

    -- Estado del sistema.
    self.running = false
    self.bios_loaded = false

    self.elapsed_time = 0
    self.frame_cycles = 0
    self.total_steps = 0

    self.instructions_per_frame =
        Core.DEFAULT_INSTRUCTIONS_PER_FRAME

    self.last_error = nil
    self.last_exception = nil

    self.exception_count = 0
    self.consecutive_exception_count = 0
    self.last_exception_pc = nil

    self.max_consecutive_exceptions = 100

    print("[AzurePS1] Core initialized")
    print("[AzurePS1] Memory connected")
    print("[AzurePS1] Interrupt controller connected")
    print("[AzurePS1] GPU connected")
    print("[AzurePS1] GTE connected")
    print("[AzurePS1] CPU connected")

    return self
end

function Core:loadBIOS(path)
    if self.running then
        self:stop()
    end

    local success, err = BIOS.initialize(
        self.memory,
        path
    )

    if not success then
        self.bios_loaded = false
        self.last_error = tostring(err)

        print("[BIOS ERROR] " .. self.last_error)

        return false, err
    end

    self.bios_loaded = true
    self.last_error = nil

    print("[AzurePS1] BIOS ready")
    print("[AzurePS1] BIOS mapped at 0x1FC00000")
    print("[AzurePS1] Reset vector: 0xBFC00000")

    return true
end

function Core:reset()
    if not self.bios_loaded then
        return false, "BIOS is not loaded"
    end

    self.running = false

    -- Reiniciar dispositivos en orden.
    local ok, err = safeCall(self.interrupts, "reset")
    if not ok then
        return false, "Interrupt reset failed: " .. tostring(err)
    end

    ok, err = safeCall(self.gpu, "reset")
    if not ok then
        return false, "GPU reset failed: " .. tostring(err)
    end

    ok, err = safeCall(self.gte, "reset")
    if not ok then
        return false, "GTE reset failed: " .. tostring(err)
    end

    ok, err = safeCall(self.cpu, "reset")
    if not ok then
        return false, "CPU reset failed: " .. tostring(err)
    end

    -- Estado inicial del procesador PS1.
    self.cpu.pc = 0xBFC00000
    self.cpu.halted = false
    self.cpu.running = false

    self.elapsed_time = 0
    self.frame_cycles = 0
    self.total_steps = 0

    self.last_error = nil
    self.last_exception = nil

    self.exception_count = 0
    self.consecutive_exception_count = 0
    self.last_exception_pc = nil

    print("[AzurePS1] System reset")
    print("[CPU] PC = 0xBFC00000")

    return true
end

function Core:start()
    if not self.bios_loaded then
        return false, "BIOS is not loaded"
    end

    if self.running then
        return true
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

    if self.cpu then
        self.cpu.running = false
    end

    print("[AzurePS1] Emulation stopped")
end

function Core:getFaultPC()
    if self.cpu and self.cpu.cop0 then
        return self.cpu.cop0[14] or self.cpu.pc
    end

    return self.cpu and self.cpu.pc or 0
end

function Core:handleCPUException(message)
    local faultPC = self:getFaultPC()

    self.exception_count =
        self.exception_count + 1

    if self.last_exception_pc == faultPC then
        self.consecutive_exception_count =
            self.consecutive_exception_count + 1
    else
        self.consecutive_exception_count = 1
        self.last_exception_pc = faultPC
    end

    self.last_exception = {
        pc = faultPC,
        message = tostring(message),
        count = self.consecutive_exception_count
    }

    -- Una excepción MIPS válida debe transferir el control
    -- al vector de excepción, no apagar el emulador.
    if self.cpu.pc == Core.EXCEPTION_VECTOR then
        if self.consecutive_exception_count >
            self.max_consecutive_exceptions then

            self.last_error =
                "Repeated CPU exception at PC 0x" ..
                string.format("%08X", faultPC)

            print("[CPU FATAL] " .. self.last_error)

            self:stop()
            return false, self.last_error
        end

        if self.consecutive_exception_count == 1 then
            print(string.format(
                "[CPU EXCEPTION] PC=0x%08X: %s",
                faultPC,
                tostring(message)
            ))
        end

        return true
    end

    self.last_error = tostring(message)

    print(string.format(
        "[CPU ERROR] PC=0x%08X: %s",
        faultPC,
        self.last_error
    ))

    self:stop()

    return false, self.last_error
end

function Core:step()
    if not self.bios_loaded then
        return false, "BIOS is not loaded"
    end

    if not self.running then
        return false, "Emulator is stopped"
    end

    if self.cpu.halted then
        self.last_error = "CPU halted"
        self:stop()

        return false, self.last_error
    end

    local oldPC = self.cpu.pc

    -- Proteger el bucle principal ante errores Lua.
    local callOK, success, err = pcall(
        self.cpu.step,
        self.cpu
    )

    if not callOK then
        self.last_error = tostring(success)

        print(string.format(
            "[CPU RUNTIME ERROR] PC=0x%08X: %s",
            oldPC,
            self.last_error
        ))

        self:stop()

        return false, self.last_error
    end

    if not success then
        local exceptionOK, exceptionError =
            self:handleCPUException(err or "Unknown CPU exception")

        if not exceptionOK then
            return false, exceptionError
        end
    else
        self.consecutive_exception_count = 0
        self.last_exception_pc = nil
    end

    -- Actualizar GPU.
    local gpuOK, gpuError = safeCall(
        self.gpu,
        "update",
        1
    )

    if not gpuOK then
        self.last_error = tostring(gpuError)

        print("[GPU ERROR] " .. self.last_error)

        self:stop()

        return false, self.last_error
    end

    self.frame_cycles = self.frame_cycles + 1
    self.total_steps = self.total_steps + 1

    return true
end

function Core:run(instruction_count)
    if not self.running then
        return false, "Emulator is stopped"
    end

    instruction_count = math.max(
        1,
        math.floor(
            instruction_count or
            self.instructions_per_frame
        )
    )

    for _ = 1, instruction_count do
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

    if type(dt) ~= "number" or dt < 0 then
        return
    end

    self.elapsed_time = self.elapsed_time + dt

    local budget = self.instructions_per_frame

    local success, err = self:run(budget)

    if not success and err then
        print("[CORE ERROR] " .. tostring(err))
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

        running = self.running,
        halted = self.cpu.halted,

        exception_count = self.exception_count,
        last_exception = self.last_exception
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

function Core:getGTEState()
    return {
        cycles = self.gte.cycles,
        data = self.gte.data,
        control = self.gte.control
    }
end

function Core:getMemoryState()
    return {
        bios_loaded = self.memory.bios_loaded,
        ram_size = 2 * 1024 * 1024,
        bios_size = 512 * 1024
    }
end

return Core
