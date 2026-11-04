local CDROM = {}
CDROM.__index = CDROM

function CDROM.new()
    local self = setmetatable({}, CDROM)

    self.disc_path = nil
    self.disc_loaded = false

    self.sector_size = 2352
    self.sector = 0

    self.command_queue = {}
    self.response_queue = {}

    return self
end

function CDROM:loadDisc(path)
    local file, err = io.open(path, "rb")

    if not file then
        return false, err
    end

    file:close()

    self.disc_path = path
    self.disc_loaded = true
    self.sector = 0

    return true
end

function CDROM:readSector(sector)
    if not self.disc_loaded then
        return nil, "No disc loaded"
    end

    local file, err = io.open(self.disc_path, "rb")

    if not file then
        return nil, err
    end

    file:seek("set", sector * self.sector_size)

    local data = file:read(self.sector_size)

    file:close()

    return data
end

function CDROM:eject()
    self.disc_path = nil
    self.disc_loaded = false
end

function CDROM:update(dt)
    -- CD-ROM command timing and sector processing.
end

return CDROM