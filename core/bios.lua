
local BIOS = {}

BIOS.SIZE = 512 * 1024
BIOS.DEFAULT_PATH = "bios/SCPH1001.BIN"

function BIOS.load(path)
    path = path or BIOS.DEFAULT_PATH

    local file, err = io.open(path, "rb")

    if not file then
        return nil, "BIOS not found: " .. tostring(err)
    end

    local data = file:read("*all")
    file:close()

    if not data then
        return nil, "Failed to read BIOS"
    end

    if #data ~= BIOS.SIZE then
        return nil, "Invalid BIOS: expected 512 KiB"
    end

    return data
end

function BIOS.initialize(memory, path)
    local data, err = BIOS.load(path)

    if not data then
        return false, err
    end

    local success, loadError = memory:loadBIOS(data)

    if not success then
        return false, loadError
    end

    print("[BIOS] Loaded successfully")
    print("[BIOS] Size: " .. #data .. " bytes")

    return true
end

return BIOS
