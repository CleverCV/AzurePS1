
local bit = require("bit")

local CPU = {}
CPU.__index = CPU

local function u32(v)
    return bit.tobit(v)
end

local function unsigned(v)
    return v < 0 and v + 4294967296 or v
end

local function sx8(v)
    v = bit.band(v, 0xFF)
    return v >= 128 and v - 256 or v
end

local function sx16(v)
    v = bit.band(v, 0xFFFF)
    return v >= 0x8000 and v - 0x10000 or v
end

local function addOverflow(a, b)
    local r = a + b
    return r < -2147483648 or r > 2147483647
end

local function subOverflow(a, b)
    local r = a - b
    return r < -2147483648 or r > 2147483647
end

local function mulUnsigned(a, b)
    local ua, ub = unsigned(a), unsigned(b)
    local a0, a1 = ua % 65536, math.floor(ua / 65536)
    local b0, b1 = ub % 65536, math.floor(ub / 65536)

    local p0 = a0 * b0
    local p1 = a0 * b1
    local p2 = a1 * b0
    local p3 = a1 * b1

    local middle = math.floor(p0 / 65536) +
        (p1 % 65536) + (p2 % 65536)

    local lo = (p0 % 65536) +
        (middle % 65536) * 65536

    local hi = p3 + math.floor(p1 / 65536) +
        math.floor(p2 / 65536) +
        math.floor(middle / 65536)

    return u32(lo), u32(hi)
end

function CPU.new(memory, interrupts, gte)
    local self = setmetatable({}, CPU)

    self.memory = assert(memory, "CPU requires memory")
    self.interrupts = interrupts
    self.gte = gte

    self.registers = {}
    self.cop0 = {}

    self:reset()
    return self
end

function CPU:setGTE(gte)
    self.gte = gte
end

function CPU:reset()
    for i = 0, 31 do
        self.registers[i] = 0
        self.cop0[i] = 0
    end

    self.pc = u32(0xBFC00000)
    self.hi = 0
    self.lo = 0

    -- Estado inicial del R3000A de PlayStation.
    self.cop0[12] = u32(0x10900000)
    self.cop0[15] = 2

    self.cycles = 0
    self.pending_branch = nil
    self.load_delay = nil
    self.in_delay_slot = false
    self.branch_pc = nil
    self.halted = false
    self.running = false
    self.last_error = nil
end

function CPU:readReg(index)
    if index == 0 then return 0 end
    return self.registers[index] or 0
end

function CPU:writeReg(index, value)
    if index ~= 0 then
        self.registers[index] = u32(value)
    end
end

function CPU:exception(code, badAddress, inDelaySlot, branchPC)
    local cause = bit.lshift(code, 2)

    if inDelaySlot then
        cause = bit.bor(cause, 0x80000000)
        self.cop0[14] = u32(branchPC or (self.pc - 4))
    else
        self.cop0[14] = u32(self.pc)
    end

    self.cop0[13] = u32(cause)

    if badAddress ~= nil then
        self.cop0[8] = u32(badAddress)
    end

    local status = self.cop0[12] or 0
    self.cop0[12] = u32(bit.bor(
        bit.band(status, 0xFFFFFFC0),
        bit.band(bit.lshift(status, 2), 0x3F)
    ))

    self.pc = u32(0x80000080)
    self.pending_branch = nil
    self.load_delay = nil
end

function CPU:interruptPending()
    local status = self.cop0[12] or 0
    local cause = self.cop0[13] or 0

    if bit.band(status, 1) == 0 then
        return false
    end

    local pending = bit.band(
        bit.rshift(status, 8),
        bit.rshift(cause, 8)
    )

    if self.interrupts and self.interrupts.isPending
    and self.interrupts:isPending() then
        pending = bit.bor(pending, 1)
    end

    return pending ~= 0
end

function CPU:readMemory(address, size, signedRead)
    address = u32(address)

    if size == 2 and bit.band(address, 1) ~= 0 then
        self:exception(4, address, self.in_delay_slot, self.branch_pc)
        return nil
    end

    if size == 4 and bit.band(address, 3) ~= 0 then
        self:exception(4, address, self.in_delay_slot, self.branch_pc)
        return nil
    end

    local value

    if size == 1 then
        value = self.memory:read8(address)
        if signedRead then value = sx8(value) end
    elseif size == 2 then
        value = self.memory:read16(address)
        if signedRead then value = sx16(value) end
    else
        value = self.memory:read32(address)
    end

    return u32(value or 0)
end

function CPU:writeMemory(address, value, size)
    address = u32(address)

    if size == 2 and bit.band(address, 1) ~= 0 then
        self:exception(5, address, self.in_delay_slot, self.branch_pc)
        return false
    end

    if size == 4 and bit.band(address, 3) ~= 0 then
        self:exception(5, address, self.in_delay_slot, self.branch_pc)
        return false
    end

    if size == 1 then
        self.memory:write8(address, value)
    elseif size == 2 then
        self.memory:write16(address, value)
    else
        self.memory:write32(address, value)
    end

    return true
end

function CPU:executeGTE(instruction)
    if not self.gte then
        return false
    end

    self.gte:execute(bit.band(instruction, 0x01FFFFFF))
    return true
end

function CPU:execute(instruction)
    local op = bit.band(bit.rshift(instruction, 26), 0x3F)
    local rs = bit.band(bit.rshift(instruction, 21), 31)
    local rt = bit.band(bit.rshift(instruction, 16), 31)
    local rd = bit.band(bit.rshift(instruction, 11), 31)
    local sh = bit.band(bit.rshift(instruction, 6), 31)
    local fn = bit.band(instruction, 63)
    local imm = bit.band(instruction, 0xFFFF)
    local simm = sx16(imm)

    local a = self:readReg(rs)
    local b = self:readReg(rt)
    local nextBranch = nil

    local function write(r, v)
        self:writeReg(r, v)
    end

    local function branch(condition)
        if condition then
            nextBranch = u32(self.pc + 4 + simm * 4)
        end
    end

    local function load(r, address, size, signedRead)
        local value = self:readMemory(address, size, signedRead)
        if value ~= nil then
            self.load_delay = {r, value}
        end
    end

    if op == 0 then
        if fn == 0x00 then
            write(rd, bit.lshift(b, sh))
        elseif fn == 0x02 then
            write(rd, bit.rshift(b, sh))
        elseif fn == 0x03 then
            write(rd, bit.arshift(b, sh))
        elseif fn == 0x04 then
            write(rd, bit.lshift(b, bit.band(a, 31)))
        elseif fn == 0x06 then
            write(rd, bit.rshift(b, bit.band(a, 31)))
        elseif fn == 0x07 then
            write(rd, bit.arshift(b, bit.band(a, 31)))
        elseif fn == 0x08 then
            nextBranch = u32(a)
        elseif fn == 0x09 then
            write(rd == 0 and 31 or rd, self.pc + 8)
            nextBranch = u32(a)
        elseif fn == 0x0C then
            return nil, 8
        elseif fn == 0x0D then
            return nil, 9
        elseif fn == 0x0F then
            -- SYNC: no requiere acción en este modelo.
        elseif fn == 0x10 then
            write(rd, self.hi)
        elseif fn == 0x11 then
            self.hi = u32(a)
        elseif fn == 0x12 then
            write(rd, self.lo)
        elseif fn == 0x13 then
            self.lo = u32(a)
        elseif fn == 0x18 then
            local lo, hi = mulUnsigned(a, b)
            if a < 0 then hi = u32(hi - unsigned(b)) end
            if b < 0 then hi = u32(hi - unsigned(a)) end
            self.lo, self.hi = lo, hi
        elseif fn == 0x19 then
            self.lo, self.hi = mulUnsigned(a, b)
        elseif fn == 0x1A then
            if b == 0 then
                self.lo = a < 0 and 1 or -1
                self.hi = a
            elseif a == -2147483648 and b == -1 then
                self.lo, self.hi = -2147483648, 0
            else
                local q = math.modf(a / b)
                self.lo = u32(q)
                self.hi = u32(a - q * b)
            end
        elseif fn == 0x1B then
            local ua, ub = unsigned(a), unsigned(b)
            if ub == 0 then
                self.lo, self.hi = -1, u32(ua)
            else
                self.lo = u32(math.floor(ua / ub))
                self.hi = u32(ua % ub)
            end
        elseif fn == 0x20 then
            if addOverflow(a, b) then return nil, 12 end
            write(rd, a + b)
        elseif fn == 0x21 then
            write(rd, a + b)
        elseif fn == 0x22 then
            if subOverflow(a, b) then return nil, 12 end
            write(rd, a - b)
        elseif fn == 0x23 then
            write(rd, a - b)
        elseif fn == 0x24 then
            write(rd, bit.band(a, b))
        elseif fn == 0x25 then
            write(rd, bit.bor(a, b))
        elseif fn == 0x26 then
            write(rd, bit.bxor(a, b))
        elseif fn == 0x27 then
            write(rd, bit.bnot(bit.bor(a, b)))
        elseif fn == 0x2A then
            write(rd, a < b and 1 or 0)
        elseif fn == 0x2B then
            write(rd, unsigned(a) < unsigned(b) and 1 or 0)
        else
            return nil, 10
        end

    elseif op == 1 then
        if rt == 0 then
            branch(a < 0)
        elseif rt == 1 then
            branch(a >= 0)
        elseif rt == 16 then
            write(31, self.pc + 8)
            branch(a < 0)
        elseif rt == 17 then
            write(31, self.pc + 8)
            branch(a >= 0)
        else
            return nil, 10
        end

    elseif op == 2 or op == 3 then
        if op == 3 then write(31, self.pc + 8) end

        nextBranch = u32(bit.bor(
            bit.band(self.pc + 4, 0xF0000000),
            bit.lshift(bit.band(instruction, 0x03FFFFFF), 2)
        ))

    elseif op == 4 then
        branch(a == b)
    elseif op == 5 then
        branch(a ~= b)
    elseif op == 6 then
        branch(a <= 0)
    elseif op == 7 then
        branch(a > 0)

    elseif op == 8 then
        if addOverflow(a, simm) then return nil, 12 end
        write(rt, a + simm)
    elseif op == 9 then
        write(rt, a + simm)
    elseif op == 10 then
        write(rt, a < simm and 1 or 0)
    elseif op == 11 then
        write(rt, unsigned(a) < unsigned(simm) and 1 or 0)
    elseif op == 12 then
        write(rt, bit.band(a, imm))
    elseif op == 13 then
        write(rt, bit.bor(a, imm))
    elseif op == 14 then
        write(rt, bit.bxor(a, imm))
    elseif op == 15 then
        write(rt, bit.lshift(imm, 16))

    elseif op == 16 then
        -- COP0.
        if rs == 0 then
            self.load_delay = {rt, self.cop0[rd] or 0}
        elseif rs == 2 then
            self.load_delay = {rt, self.cop0[rd] or 0}
        elseif rs == 4 then
            self.cop0[rd] = u32(b)
        elseif rs == 6 then
            self.cop0[rd] = u32(b)
        elseif rs == 8 then
            local cond = bit.band(self.cop0[13] or 0, 0x00800000) ~= 0
            if (rt == 0 and not cond) or (rt == 1 and cond) then
                branch(true)
            end
        elseif rs == 16 then
            if fn == 0x10 then
                local s = self.cop0[12] or 0
                self.cop0[12] = u32(bit.bor(
                    bit.band(s, 0xFFFFFFF0),
                    bit.rshift(bit.band(s, 0x3C), 2)
                ))
            elseif fn == 0x01 or fn == 0x02
            or fn == 0x06 or fn == 0x08 then
                -- TLB no está presente en PlayStation.
            else
                return nil, 10
            end
        else
            return nil, 10
        end

    elseif op == 17 then
        -- La PS1 no incorpora COP1/FPU.
        return nil, 11

    elseif op == 18 then
        -- COP2 / GTE.
        if rs == 0 then
            if not self.gte then return nil, 10 end
            self.load_delay = {rt, self.gte:readData(rd)}
        elseif rs == 2 then
            if not self.gte then return nil, 10 end
            self.load_delay = {rt, self.gte:readControl(rd)}
        elseif rs == 4 then
            if not self.gte then return nil, 10 end
            self.gte:writeData(rd, b)
        elseif rs == 6 then
            if not self.gte then return nil, 10 end
            self.gte:writeControl(rd, b)
        elseif rs == 8 then
            -- BC2F / BC2T.
            local condition = bit.band(
                self.gte and self.gte.flags or 0,
                0x80000000
            ) ~= 0

            if (rt == 0 and not condition)
            or (rt == 1 and condition) then
                branch(true)
            end
        elseif rs == 16 then
            if not self:executeGTE(instruction) then
                return nil, 10
            end
        else
            return nil, 10
        end

    elseif op == 32 then
        load(rt, a + simm, 1, true)
    elseif op == 33 then
        load(rt, a + simm, 2, true)
    elseif op == 34 then
        local address = u32(a + simm)
        local aligned = bit.band(address, 0xFFFFFFFC)
        local value = self:readMemory(aligned, 4, false)

        if value ~= nil then
            local shift = bit.band(address, 3) * 8
            local mask = bit.lshift(0x00FFFFFF, shift)
            write(rt, bit.bor(
                bit.band(b, mask),
                bit.lshift(value, 24 - shift)
            ))
        end
    elseif op == 35 then
        load(rt, a + simm, 4, false)
    elseif op == 36 then
        load(rt, a + simm, 1, false)
    elseif op == 37 then
        load(rt, a + simm, 2, false)
    elseif op == 38 then
        local address = u32(a + simm)
        local aligned = bit.band(address, 0xFFFFFFFC)
        local value = self:readMemory(aligned, 4, false)

        if value ~= nil then
            local shift = bit.band(address, 3) * 8
            local mask = bit.rshift(0xFFFFFF00, 24 - shift)
            write(rt, bit.bor(
                bit.band(b, mask),
                bit.rshift(value, shift)
            ))
        end

    elseif op == 40 then
        self:writeMemory(a + simm, b, 1)
    elseif op == 41 then
        self:writeMemory(a + simm, b, 2)
    elseif op == 42 then
        local address = u32(a + simm)
        local aligned = bit.band(address, 0xFFFFFFFC)
        local old = self:readMemory(aligned, 4, false)

        if old ~= nil then
            local shift = bit.band(address, 3) * 8
            local mask = bit.rshift(0xFFFFFF00, 24 - shift)
            local value = bit.bor(
                bit.band(old, mask),
                bit.lshift(b, 24 - shift)
            )
            self:writeMemory(aligned, value, 4)
        end
    elseif op == 43 then
        self:writeMemory(a + simm, b, 4)
    elseif op == 46 then
        local address = u32(a + simm)
        local aligned = bit.band(address, 0xFFFFFFFC)
        local old = self:readMemory(aligned, 4, false)

        if old ~= nil then
            local shift = bit.band(address, 3) * 8
            local mask = bit.lshift(0x00FFFFFF, shift)
            local value = bit.bor(
                bit.band(old, mask),
                bit.rshift(b, shift)
            )
            self:writeMemory(aligned, value, 4)
        end

    elseif op == 48 then
        -- LWC0 no está soportado por el hardware PS1.
        return nil, 10

    elseif op == 50 then
        -- LWC2: cargar palabra desde RAM a un registro de datos GTE.
        if not self.gte then return nil, 10 end
        local value = self:readMemory(a + simm, 4, false)
        if value ~= nil then
            self.gte:writeData(rt, value)
        end

    elseif op == 56 then
        return nil, 10

    elseif op == 58 then
        -- SWC2: guardar palabra desde GTE a RAM.
        if not self.gte then return nil, 10 end
        self:writeMemory(
            a + simm,
            self.gte:readData(rt),
            4
        )

    else
        return nil, 10
    end

    return nextBranch
end

function CPU:step()
    if self.halted then
        return false, "CPU halted"
    end

    local pc = self.pc
    local previousBranch = self.pending_branch
    local oldLoad = self.load_delay

    self.pending_branch = nil
    self.load_delay = nil

    self.in_delay_slot = previousBranch ~= nil
    self.branch_pc = previousBranch and previousBranch.branchPC or nil

    if self:interruptPending() then
        self:exception(0, nil, self.in_delay_slot, self.branch_pc)
        self.cycles = self.cycles + 1
        return true
    end

    local instruction = self:readMemory(pc, 4, false)

    if instruction == nil then
        self.cycles = self.cycles + 1
        return true
    end

    local nextBranch, exceptionCode = self:execute(instruction)

    if exceptionCode then
        self:exception(
            exceptionCode,
            nil,
            self.in_delay_slot,
            self.branch_pc
        )
        self.cycles = self.cycles + 1
        return true
    end

    -- Aplicar el load delay después de leer los operandos.
    if oldLoad and oldLoad[1] ~= 0 then
        self:writeReg(oldLoad[1], oldLoad[2])
    end

    -- Si execute/readMemory generó una excepción, no sobrescribir
    -- el vector 0x80000080 con el PC secuencial.
    if self.pc == pc then
        self.pc = previousBranch
            and previousBranch.target
            or u32(pc + 4)

        if nextBranch then
            self.pending_branch = {
                target = nextBranch,
                branchPC = pc
            }
        end
    end

    self.registers[0] = 0
    self.cycles = self.cycles + 1

    return true
end

return CPU
