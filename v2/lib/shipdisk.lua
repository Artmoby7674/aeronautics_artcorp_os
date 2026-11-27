-- v2 world backup on a floppy: SAVE DISK / LOAD DISK on the SHIP tab.
--
-- Any ComputerCraft disk drive on the ship's network (or touching the
-- computer) is used. Only WORLD data is carried: what the ship learned in
-- this world/server, copied into <disk>/artcorp_world/ with the same paths
-- as on the computer:
--   v2/data/waypoints.lua    saved places
--   v2/data/atmos.lua        the air measured in flight
--   v2/data/learned.lua      learned trims and hover thrust
-- plus manifest.lua (OS version, file list). The wiring never goes on the
-- disk: config/<slot>.lua comes from the repo and config/assignments_*.lua
-- holds THIS computer's peripheral names (the setup wizard writes them).
-- LOAD copies the world files back; the files it replaces are kept first in
-- v2/data/before_disk/ so a wrong disk can be undone by hand. A floppy saved
-- by an older OS (artcorp_ship/, with the wiring on it) still loads: only its
-- world files are taken.
local U = require("util")

local SD = {}

local DIR = "artcorp_world"
local OLD_DIR = "artcorp_ship" -- v2.28 - v2.38 saves
local KEEP = "v2/data/before_disk"

local WORLD = {
    "v2/data/waypoints.lua",
    "v2/data/atmos.lua",
    "v2/data/learned.lua",
}
SD.WORLD = WORLD
local IS_WORLD = {}
for _, f in ipairs(WORLD) do IS_WORLD[f] = true end

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

-- Save the world data onto the floppy. Returns number of files, or nil + reason.
function SD.save(info)
    local mnt, why = SD.mount()
    if not mnt then return nil, why end
    local base = fs.combine(mnt, DIR)
    local list, size = {}, 0
    for _, f in ipairs(WORLD) do
        if fs.exists(f) and not fs.isDir(f) then
            list[#list + 1] = f
            size = size + fs.getSize(f)
        end
    end
    if #list == 0 then return nil, "NOTHING TO SAVE YET" end
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
            kind = "world", ship = info and info.ship, os = info and info.os,
            day = os.day and os.day() or 0, files = list,
        })
    end)
    if not ok then return nil, "SAVE FAILED: " .. tostring(err):upper():sub(1, 40) end
    U.log("disk: saved %d world files to %s", #list, base)
    return #list
end

-- What is on the floppy: the manifest (its files cut down to the world
-- files), its folder on the disk; or nil + reason.
function SD.peek()
    local mnt, why = SD.mount()
    if not mnt then return nil, why end
    for _, dir in ipairs({ DIR, OLD_DIR }) do
        local base = fs.combine(mnt, dir)
        local m = U.loadTable(fs.combine(base, "manifest.lua"))
        if type(m) == "table" and type(m.files) == "table" then
            local list = {}
            for _, f in ipairs(m.files) do
                if IS_WORLD[f] then list[#list + 1] = f end
            end
            if #list > 0 then
                m.files = list
                return m, base
            end
        end
    end
    return nil, "NO WORLD DATA ON THIS DISK"
end

-- Load the world data from the floppy over this computer's files. Returns
-- the manifest, or nil + reason. The caller restarts the OS afterwards.
function SD.load()
    local m, base = SD.peek()
    if not m then return nil, base end
    for _, f in ipairs(m.files) do
        if not fs.exists(fs.combine(base, f)) then return nil, "DISK SAVE IS INCOMPLETE" end
    end
    local ok, err = pcall(function()
        if fs.exists(KEEP) then fs.delete(KEEP) end
        for _, f in ipairs(m.files) do
            if fs.exists(f) then copy(f, fs.combine(KEEP, f)) end
            copy(fs.combine(base, f), f)
        end
    end)
    if not ok then return nil, "LOAD FAILED: " .. tostring(err):upper():sub(1, 40) end
    U.log("disk: loaded %d world files from %s; replaced files kept in %s", #m.files, base, KEEP)
    return m
end

return SD
