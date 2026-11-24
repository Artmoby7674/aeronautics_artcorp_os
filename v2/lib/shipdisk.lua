-- v2 ship backup on a floppy: SAVE DISK / LOAD DISK on the SHIP tab.
--
-- Any ComputerCraft disk drive on the ship's network (or touching the
-- computer) is used. Everything that makes this ship THIS ship is copied
-- into <disk>/artcorp_ship/ with the same paths as on the computer:
--   config/<slot>.lua, config/assignments_<slot>.lua   wiring
--   v2/data/learned.lua, v2/data/atmos.lua             learned in flight
--   v2/data/waypoints.lua, v2/data/tune_local.lua      waypoints, own tuning
--   v2/data/slot                                       which ship it is
-- plus manifest.lua (ship, slot, OS version, file list).
-- LOAD copies them back; the files it replaces are kept first in
-- v2/data/before_disk/ so a wrong disk can be undone by hand.
local U = require("util")

local SD = {}

local DIR = "artcorp_ship"
local KEEP = "v2/data/before_disk"

local function files(slot)
    return {
        "config/" .. slot .. ".lua",
        "config/assignments_" .. slot .. ".lua",
        "v2/data/learned.lua",
        "v2/data/atmos.lua",
        "v2/data/waypoints.lua",
        "v2/data/tune_local.lua",
        "v2/data/slot",
    }
end

local function isDrive(name)
    if peripheral.hasType then
        local ok, yes = pcall(peripheral.hasType, name, "drive")
        if ok then return yes end
    end
    return peripheral.getType(name) == "drive"
end

-- The first disk drive with a floppy in it: mount path, or nil + reason.
function SD.mount()
    local drive, any = nil, false
    for _, name in ipairs(peripheral.getNames()) do
        if isDrive(name) then
            any = true
            if disk.isPresent(name) and disk.hasData(name) then
                drive = name
                break
            end
        end
    end
    if not any then return nil, "NO DISK DRIVE FOUND" end
    if not drive then return nil, "PUT A FLOPPY IN THE DRIVE" end
    local path = disk.getMountPath(drive)
    if not path then return nil, "DISK NOT READABLE" end
    return path, drive
end

local function copy(src, dst)
    if fs.exists(dst) then fs.delete(dst) end
    local dir = fs.getDir(dst)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    fs.copy(src, dst)
end

-- Save this ship onto the floppy. Returns number of files, or nil + reason.
function SD.save(slot, info)
    local mnt, why = SD.mount()
    if not mnt then return nil, why end
    local base = fs.combine(mnt, DIR)
    local list, size = {}, 0
    for _, f in ipairs(files(slot)) do
        if fs.exists(f) and not fs.isDir(f) then
            list[#list + 1] = f
            size = size + fs.getSize(f)
        end
    end
    -- room on the floppy (what is already ours there gets replaced)
    local mine = 0
    if fs.exists(base) then
        for _, f in ipairs(fs.list(base)) do
            local p = fs.combine(base, f)
            if not fs.isDir(p) then mine = mine + fs.getSize(p) end
        end
    end
    local free = fs.getFreeSpace(mnt)
    if free and free + mine < size + 2048 then
        return nil, string.format("DISK FULL (%d KB NEEDED)", math.ceil((size + 2048) / 1024))
    end
    local ok, err = pcall(function()
        if fs.exists(base) then fs.delete(base) end
        fs.makeDir(base)
        for _, f in ipairs(list) do copy(f, fs.combine(base, f)) end
        U.saveTable(fs.combine(base, "manifest.lua"), {
            slot = slot, ship = info and info.ship, os = info and info.os,
            day = os.day and os.day() or 0, files = list,
        })
    end)
    if not ok then return nil, "SAVE FAILED: " .. tostring(err):upper():sub(1, 40) end
    U.log("disk: saved %d files of ship %s (slot %s) to %s", #list, tostring(info and info.ship), slot, base)
    return #list
end

-- What is on the floppy (manifest table), or nil + reason.
function SD.peek()
    local mnt, why = SD.mount()
    if not mnt then return nil, why end
    local m = U.loadTable(fs.combine(mnt, DIR .. "/manifest.lua"))
    if type(m) ~= "table" or type(m.files) ~= "table" or not m.slot then
        return nil, "NO SHIP SAVED ON THIS DISK"
    end
    return m, mnt
end

-- Load the ship from the floppy over this computer's files. Returns the
-- manifest, or nil + reason. The caller restarts the OS afterwards.
function SD.load()
    local m, mnt = SD.peek()
    if not m then return nil, mnt end
    local base = fs.combine(mnt, DIR)
    for _, f in ipairs(m.files) do
        if type(f) ~= "string" or f:find("%.%.") or not fs.exists(fs.combine(base, f)) then
            return nil, "DISK SAVE IS INCOMPLETE"
        end
    end
    local ok, err = pcall(function()
        if fs.exists(KEEP) then fs.delete(KEEP) end
        for _, f in ipairs(m.files) do
            if fs.exists(f) then copy(f, fs.combine(KEEP, f)) end
            copy(fs.combine(base, f), f)
        end
    end)
    if not ok then return nil, "LOAD FAILED: " .. tostring(err):upper():sub(1, 40) end
    U.log("disk: loaded %d files of ship %s (slot %s); replaced files kept in %s",
        #m.files, tostring(m.ship), tostring(m.slot), KEEP)
    return m
end

return SD
