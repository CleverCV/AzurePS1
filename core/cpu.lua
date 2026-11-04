
local bit = require("bit")

local CPU = {}
CPU.__index = CPU

local TWO32 = 4294967296

local function signed16(value)
    if value >= 0x8000 then
        return value - 0x10000
    end

    return value
end

local function u32(value)
    return bit.tobit(value)
end

local function unsigned(value)
    local result = bit.band(value, 0xFFFFFFFF)

    if result < 0 then
        result = result + TWO32
    end

    return result
end

local function signed(value)
    return bit.tobit(value)
end

local function multiplyUnsigned(a, b)
    a = unsigned(a)
    b = unsigned(b)

    local a0 = a % 65536
    local a1 = math.floor(a / 65536)

    local b0 = b % 65536
    local b1 = math.floor(b / 65536)

    local p0 = a0 * b0
    local p1 = a0 * b1
    local p2 = a1 * b0
    local p3 = a1 * b1

    local middle =
        math.floor(p0 / 65536)
        + (p1 % 65536)
        + (p2 % 65536)

    local low =
        (p0 % 65536)
        + (middle % 65536) * 65536

    local high =
        p3
        + math.floor(p1 / 65536)
        + math.floor(p2 / 65536)
        + math.floor(middle / 65536)

    return u32(low), u32(high)
end

function CPU.new(memory, interrupts)
    local self = setmetatable({}, CPU)

    self.memory = memory
    self.interrupts = interrupts

    self.registers = {}
    self.cop0 = {}

    for i = 0, 31 do
        self.registers[i] = 0
        self.cop0[i] = 0
    end

    self.pc = 0xBFC00000

    self.hi = 0
    self.lo = 0

    self.cycles = 0
    self.pending_branch = nil

    self.halted = false
    self.running = false

    self:reset()

    return self
end

function CPU:reset()
    for i = 0, 31 do
        self.registers[i] = 0
        self.cop0[i] = 0
    end

    self.pc = 0xBFC00000

    self.hi = 0
    self.lo = 0

    self.cycles = 0
    self.pending_branch = nil

    self.halted = false
    self.running = false

    -- Estado inicial aproximado del COP0 de la PS1.
    self.cop0[12] = u32(0x10900000)
    self.cop0[15] = 0x00000002
end

function CPU:exception(code, in_delay_slot)
    local cause = bit.lshift(code, 2)

    if in_delay_slot then
        cause = bit.bor(cause, 0x80000000)
        self.cop0[14] = u32(self.pc - 4)
    else
        self.cop0[14] = u32(self.pc)
    end

    self.cop0[13] = u32(cause)

    local status = self.cop0[12]

    self.cop0[12] = u32(
        bit.bor(
            bit.band(status, 0xFFFFFFC0),
            bit.band(bit.lshift(status, 2), 0x3F)
        )
    )

    self.pc = u32(0x80000080)
    self.pending_branch = nil
end

function CPU:execute(instruction)
    local op = bit.band(bit.rshift(instruction, 26), 0x3F)

    local rs = bit.band(bit.rshift(instruction, 21), 31)
    local rt = bit.band(bit.rshift(instruction, 16), 31)
    local rd = bit.band(bit.rshift(instruction, 11), 31)

    local shamt = bit.band(bit.rshift(instruction, 6), 31)
    local funct = bit.band(instruction, 63)

    local imm = bit.band(instruction, 0xFFFF)
    local simm = signed16(imm)

    local a = self.registers[rs]
    local b = self.registers[rt]

    local next_branch = nil

    local function write(reg, value)
        if reg ~= 0 then
            self.registers[reg] = u32(value)
        end
    end

    local function branchIf(condition)
        if condition then
            next_branch = u32(self.pc + 4 + simm * 4)
        end
    end

    local function address()
        return u32(a + simm)
    end

    -- =========================================================
    -- SPECIAL
    -- =========================================================

    if op == 0x00 then

        if funct == 0x00 then
            -- SLL
            write(rd, bit.lshift(b, shamt))

        elseif funct == 0x02 then
            -- SRL
            write(rd, bit.rshift(b, shamt))

        elseif funct == 0x03 then
            -- SRA
            write(rd, bit.arshift(b, shamt))

        elseif funct == 0x04 then
            -- SLLV
            write(rd, bit.lshift(b, bit.band(a, 31)))

        elseif funct == 0x06 then
            -- SRLV
            write(rd, bit.rshift(b, bit.band(a, 31)))

        elseif funct == 0x07 then
            -- SRAV
            write(rd, bit.arshift(b, bit.band(a, 31)))

        elseif funct == 0x08 then
            -- JR
            next_branch = u32(a)

        elseif funct == 0x09 then
            -- JALR
            write(rd == 0 and 31 or rd, self.pc + 8)
            next_branch = u32(a)

        elseif funct == 0x0C then
            -- SYSCALL
            return nil, nil, 8

        elseif funct == 0x0D then
            -- BREAK
            return nil, nil, 9

        elseif funct == 0x0F then
            -- SYNC
            -- No requiere operación adicional en esta implementación.

        elseif funct == 0x10 then
            -- MFHI
            write(rd, self.hi)

        elseif funct == 0x11 then
            -- MTHI
            self.hi = u32(b)

        elseif funct == 0x12 then
            -- MFLO
            write(rd, self.lo)

        elseif funct == 0x13 then
            -- MTLO
            self.lo = u32(b)

        elseif funct == 0x18 then
            -- MULT
            local low, high = multiplyUnsigned(a, b)

            local ua = unsigned(a)
            local ub = unsigned(b)

            if a < 0 then
                high = u32(high - ub)
            end

            if b < 0 then
                high = u32(high - ua)
            end

            self.lo = low
            self.hi = high

        elseif funct == 0x19 then
            -- MULTU
            local low, high = multiplyUnsigned(a, b)

            self.lo = low
            self.hi = high

        elseif funct == 0x1A then
            -- DIV
            if b == 0 then
                self.lo = a < 0 and 1 or -1
                self.hi = u32(a)

            elseif a == -2147483648 and b == -1 then
                self.lo = -2147483648
                self.hi = 0

            else
                local quotient = math.modf(a / b)

                self.lo = u32(quotient)
                self.hi = u32(a - quotient * b)
            end

        elseif funct == 0x1B then
            -- DIVU
            local ua = unsigned(a)
            local ub = unsigned(b)

            if ub == 0 then
                self.lo = u32(0xFFFFFFFF)
                self.hi = u32(ua)
            else
                self.lo = u32(math.floor(ua / ub))
                self.hi = u32(ua % ub)
            end

        elseif funct == 0x20 or funct == 0x21 then
            -- ADD / ADDU
            write(rd, a + b)

        elseif funct == 0x22 or funct == 0x23 then
            -- SUB / SUBU
            write(rd, a - b)

        elseif funct == 0x24 then
            -- AND
            write(rd, bit.band(a, b))

        elseif funct == 0x25 then
            -- OR
            write(rd, bit.bor(a, b))

        elseif funct == 0x26 then
            -- XOR
            write(rd, bit.bxor(a, b))

        elseif funct == 0x27 then
            -- NOR
            write(rd, bit.bnot(bit.bor(a, b)))

        elseif funct == 0x2A then
            -- SLT
            write(rd, signed(a) < signed(b) and 1 or 0)

        elseif funct == 0x2B then
            -- SLTU
            write(rd, unsigned(a) < unsigned(b) and 1 or 0)

        else
            return nil, string.format(
                "Unsupported SPECIAL instruction: funct=0x%02X at PC=0x%08X",
                funct,
                self.pc
            )
        end

    -- =========================================================
    -- JUMPS AND BRANCHES
    -- =========================================================

    elseif op == 0x02 then
        -- J
        next_branch = u32(
            bit.bor(
                bit.band(self.pc + 4, 0xF0000000),
                bit.lshift(bit.band(instruction, 0x03FFFFFF), 2)
            )
        )

    elseif op == 0x03 then
        -- JAL
        write(31, self.pc + 8)

        next_branch = u32(
            bit.bor(
                bit.band(self.pc + 4, 0xF0000000),
                bit.lshift(bit.band(instruction, 0x03FFFFFF), 2)
            )
        )

    elseif op == 0x04 then
        -- BEQ
        branchIf(a == b)

    elseif op == 0x05 then
        -- BNE
        branchIf(a ~= b)

    elseif op == 0x06 then
        -- BLEZ
        branchIf(signed(a) <= 0)

    elseif op == 0x07 then
        -- BGTZ
        branchIf(signed(a) > 0)

    elseif op == 0x01 then
        -- REGIMM

        if rt == 0x00 then
            -- BLTZ
            branchIf(signed(a) < 0)

        elseif rt == 0x01 then
            -- BGEZ
            branchIf(signed(a) >= 0)

        elseif rt == 0x10 then
            -- BLTZAL
            if signed(a) < 0 then
                write(31, self.pc + 8)
                branchIf(true)
            end

        elseif rt == 0x11 then
            -- BGEZAL
            if signed(a) >= 0 then
                write(31, self.pc + 8)
                branchIf(true)
            end

        else
            return nil, string.format(
                "Unsupported REGIMM instruction at PC=0x%08X",
                self.pc
            )
        end

    -- =========================================================
    -- IMMEDIATE ARITHMETIC
    -- =========================================================

    elseif op == 0x08 or op == 0x09 then
        -- ADDI / ADDIU
        write(rt, a + simm)

    elseif op == 0x0A then
        -- SLTI
        write(rt, signed(a) < simm and 1 or 0)

    elseif op == 0x0B then
        -- SLTIU
        write(rt, unsigned(a) < unsigned(simm) and 1 or 0)

    elseif op == 0x0C then
        -- ANDI
        write(rt, bit.band(a, imm))

    elseif op == 0x0D then
        -- ORI
        write(rt, bit.bor(a, imm))

    elseif op == 0x0E then
        -- XORI
        write(rt, bit.bxor(a, imm))

    elseif op == 0x0F then
        -- LUI
        write(rt, bit.lshift(imm, 16))

    -- =========================================================
    -- COP0
    -- =========================================================

    elseif op == 0x10 then

        if rs == 0 then
            -- MFC0
            write(rt, self.cop0[rd])

        elseif rs == 2 then
            -- CFC0
            write(rt, self.cop0[rd])

        elseif rs == 4 then
            -- MTC0
            self.cop0[rd] = u32(b)

        elseif rs == 6 then
            -- CTC0
            self.cop0[rd] = u32(b)

        elseif rs == 8 then
            -- BC0F / BC0T
            local condition = bit.band(self.cop0[13], 1) ~= 0

            if rt == 0 and not condition then
                branchIf(true)
            elseif rt == 1 and condition then
                branchIf(true)
            end

        elseif rs == 16 then
            -- COP0 operations

            if funct == 0x01 then
                -- TLBR

            elseif funct == 0x02 then
                -- TLBWI

            elseif funct == 0x06 then
                -- TLBWR

            elseif funct == 0x08 then
                -- TLBP

            elseif funct == 0x10 then
                -- RFE
                local status = self.cop0[12]

                self.cop0[12] = u32(
                    bit.bor(
                        bit.band(status, 0xFFFFFFF0),
                        bit.rshift(bit.band(status, 0x3C), 2)
                    )
                )

            else
                return nil, string.format(
                    "Unsupported COP0 operation at PC=0x%08X",
                    self.pc
                )
            end

        else
            return nil, string.format(
                "Unsupported COP0 instruction at PC=0x%08X",
                self.pc
            )
        end

    -- =========================================================
    -- LOAD INSTRUCTIONS
    -- =========================================================

    elseif op == 0x20 then
        -- LB
        local value = self.memory:read8(address())

        if value >= 0x80 then
            value = value - 0x100
        end

        write(rt, value)

    elseif op == 0x21 then
        -- LH
        local value = self.memory:read16(address())

        if value >= 0x8000 then
            value = value - 0x10000
        end

        write(rt, value)

    elseif op == 0x22 then
        -- LWL
        local addr = address()
        local aligned = bit.band(addr, 0xFFFFFFFC)
        local offset = bit.band(addr, 3)

        local memoryValue = self.memory:read32(aligned)
        local oldValue = b

        if offset == 0 then
            write(rt, bit.bor(
                bit.band(oldValue, 0x00FFFFFF),
                bit.lshift(memoryValue, 24)
            ))

        elseif offset == 1 then
            write(rt, bit.bor(
                bit.band(oldValue, 0x0000FFFF),
                bit.lshift(memoryValue, 16)
            ))

        elseif offset == 2 then
            write(rt, bit.bor(
                bit.band(oldValue, 0x000000FF),
                bit.lshift(memoryValue, 8)
            ))

        else
            write(rt, memoryValue)
        end

    elseif op == 0x23 then
        -- LW
        write(rt, self.memory:read32(address()))

    elseif op == 0x24 then
        -- LBU
        write(rt, self.memory:read8(address()))

    elseif op == 0x25 then
        -- LHU
        write(rt, self.memory:read16(address()))

    elseif op == 0x26 then
        -- LWR
        local addr = address()
        local aligned = bit.band(addr, 0xFFFFFFFC)
        local offset = bit.band(addr, 3)

        local memoryValue = self.memory:read32(aligned)
        local oldValue = b

        if offset == 0 then
            write(rt, memoryValue)

        elseif offset == 1 then
            write(rt, bit.bor(
                bit.band(oldValue, 0xFF000000),
                bit.rshift(memoryValue, 8)
            ))

        elseif offset == 2 then
            write(rt, bit.bor(
                bit.band(oldValue, 0xFFFF0000),
                bit.rshift(memoryValue, 16)
            ))

        else
            write(rt, bit.bor(
                bit.band(oldValue, 0xFFFFFF00),
                bit.rshift(memoryValue, 24)
            ))
        end

    -- =========================================================
    -- STORE INSTRUCTIONS
    -- =========================================================

    elseif op == 0x28 then
        -- SB
        self.memory:write8(address(), b)

    elseif op == 0x29 then
        -- SH
        self.memory:write16(address(), b)

    elseif op == 0x2A then
        -- SWL
        local addr = address()
        local aligned = bit.band(addr, 0xFFFFFFFC)
        local offset = bit.band(addr, 3)

        local oldValue = self.memory:read32(aligned)
        local newValue

        if offset == 0 then
            newValue = bit.bor(
                bit.band(oldValue, 0xFFFFFF00),
                bit.rshift(b, 24)
            )

        elseif offset == 1 then
            newValue = bit.bor(
                bit.band(oldValue, 0xFFFF0000),
                bit.rshift(b, 16)
            )

        elseif offset == 2 then
            newValue = bit.bor(
                bit.band(oldValue, 0xFF000000),
                bit.rshift(b, 8)
            )

        else
            newValue = b
        end

        self.memory:write32(aligned, newValue)

    elseif op == 0x2B then
        -- SW
        self.memory:write32(address(), b)

    elseif op == 0x2E then
        -- SWR
        local addr = address()
        local aligned = bit.band(addr, 0xFFFFFFFC)
        local offset = bit.band(addr, 3)

        local oldValue = self.memory:read32(aligned)
        local newValue

        if offset == 0 then
            newValue = b

        elseif offset == 1 then
            newValue = bit.bor(
                bit.band(oldValue, 0x000000FF),
                bit.lshift(b, 8)
            )

        elseif offset == 2 then
            newValue = bit.bor(
                bit.band(oldValue, 0x0000FFFF),
                bit.lshift(b, 16)
            )

        else
            newValue = bit.bor(
                bit.band(oldValue, 0x00FFFFFF),
                bit.lshift(b, 24)
            )
        end

        self.memory:write32(aligned, newValue)

    else
        return nil, string.format(
            "Unsupported opcode: 0x%02X at PC=0x%08X",
            op,
            self.pc
        )
    end

    return next_branch
end

function CPU:step()
    if self.halted then
        return false, "CPU halted"
    end

    local pc = self.pc

    local instruction = self.memory:read32(pc)

    local previous_branch = self.pending_branch
    self.pending_branch = nil

    local branch, err, exceptionCode = self:execute(instruction)

    -- Excepciones solicitadas por instrucciones como SYSCALL y BREAK.
    if exceptionCode then
        self:exception(exceptionCode, previous_branch ~= nil)

        self.cycles = self.cycles + 1
        self.registers[0] = 0

        return true
    end

    -- Instrucción no implementada.
    if err then
        self.pc = pc
        self:exception(10, previous_branch ~= nil)

        self.cycles = self.cycles + 1

        return false, err
    end

    -- Ejecutar el delay slot antes de cambiar al destino.
    self.pc = previous_branch or u32(pc + 4)

    self.pending_branch = branch

    -- El registro cero siempre debe ser cero.
    self.registers[0] = 0

    self.cycles = self.cycles + 1

    return true
end

return CPU
