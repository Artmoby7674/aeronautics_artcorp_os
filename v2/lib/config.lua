-- v2 configuration: the ship's existing wiring + v2 tuning.
--
-- Wiring comes from the same files the original OS used:
--   config/<slot>.lua              relay roles/faces, features, limits (from
--                                  the repo: config/atlas.lua)
--   config/assignments_<slot>.lua  real peripheral names on THIS computer's
--                                  network, from the setup wizard (wizard.lua)
local U = require("util")

local Config = {}

local SIDE_FILES = { "^assignments_", "^pid_", "^wp_", "^kbd_" }

local function isSlotFile(name)
    if not name:match("%.lua$") then return false end
    for _, p in ipairs(SIDE_FILES) do
        if name:match(p) then return false end
    end
    return true
end

function Config.slots()
    local out = {}
    if not fs.isDir("config") then return out end
    for _, f in ipairs(fs.list("config")) do
        if isSlotFile(f) then out[#out + 1] = f:gsub("%.lua$", "") end
    end
    table.sort(out)
    return out
end

local function loadLuaTable(path)
    if not fs.exists(path) then return nil end
    local fn, err = loadfile(path)
    if not fn then return nil, err end
    local ok, t = pcall(fn)
    if ok and type(t) == "table" then return t end
    return nil, t
end

-- Picks the slot: v2/data/slot remembers the last one; otherwise the only
-- one, or the first that has wizard assignments.
function Config.pickSlot(root)
    local slots = Config.slots()
    local remembered
    if fs.exists(root .. "/data/slot") then
        local f = fs.open(root .. "/data/slot", "r")
        if f then remembered = f.readAll():gsub("%s", "") f.close() end
    end
    for _, s in ipairs(slots) do
        if s == remembered then return s end
    end
    for _, s in ipairs(slots) do
        if fs.exists("config/assignments_" .. s .. ".lua") then return s end
    end
    return slots[1]
end

function Config.load(root, slot)
    slot = slot or Config.pickSlot(root)
    if not slot then return nil, "no ship config in config/ (reinstall: config/atlas.lua is missing)" end
    local ship, err = loadLuaTable("config/" .. slot .. ".lua")
    if not ship then return nil, "config/" .. slot .. ".lua: " .. tostring(err) end

    local assign = loadLuaTable("config/assignments_" .. slot .. ".lua") or {}
    ship.peripherals = ship.peripherals or {}
    -- the printer is found by type when printing (rec.lua) and kbd_computer
    -- is a rednet id: neither is a peripheral the OS must have
    for k, v in pairs(assign) do
        if type(v) == "string" and k ~= "config_version" and k ~= "ship_id"
            and k ~= "printer" and k ~= "kbd_computer" then
            ship.peripherals[k] = v
        end
    end

    local tune = dofile(root .. "/tune.lua")
    local loc = loadLuaTable(root .. "/data/tune_local.lua")
    if loc then U.merge(tune, loc) end
    Config.build(ship, tune)
    return { slot = slot, ship = ship, tune = tune, name = ship.name or slot }
end

-- ------------------------------------------------------------ assignments
-- config/assignments_<slot>.lua: role -> real peripheral name, written by
-- the setup wizard (wizard.lua) in the original OS's format.

local function writeFile(path, data)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(data)
    f.close()
    return true
end

function Config.assignmentsPath(slot) return "config/assignments_" .. slot .. ".lua" end

-- The slot's ship config as written (no tuning merged), or nil + why.
function Config.readShip(slot)
    return loadLuaTable("config/" .. slot .. ".lua")
end

-- The saved assignments table, or nil + why.
function Config.readAssignments(slot)
    return loadLuaTable(Config.assignmentsPath(slot))
end

-- Same layout as the original wizard: config_version, ship_id, then one
-- ["role"] = "name" line per peripheral (sorted, so a rewrite is stable).
function Config.writeAssignments(slot, data)
    local out = { "return {\n" }
    if data.config_version then
        out[#out + 1] = "  config_version = " .. string.format("%q", tostring(data.config_version)) .. ",\n"
    end
    if data.ship_id then
        out[#out + 1] = "  ship_id = " .. string.format("%q", tostring(data.ship_id)) .. ",\n"
    end
    local keys = {}
    for k in pairs(data) do
        if k ~= "config_version" and k ~= "ship_id" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        out[#out + 1] = "  [" .. string.format("%q", k) .. "] = " .. string.format("%q", tostring(data[k])) .. ",\n"
    end
    out[#out + 1] = "}\n"
    if not fs.exists("config") then fs.makeDir("config") end
    return writeFile(Config.assignmentsPath(slot), table.concat(out))
end

-- Derive the ship-specific numbers v2 takes from the ship config.
function Config.build(ship, tune)
    local lim = ship.limits or {}
    tune.ship = {
        hover_throttle = lim.hover_throttle or 6,
        max_altitude = lim.max_altitude or 2000,
        max_speed = lim.hover_max_speed or 15,
        creep = lim.landed_creep or tune.landing.creep,
        gravity = (ship.physics and ship.physics.gravity) or tune.physics.gravity,
    }
    tune.physics.gravity = tune.ship.gravity
    tune.vertical.sink_max = math.min(tune.vertical.sink_max, lim.max_descent_rate or 5)
    tune.vertical.climb_max = math.min(tune.vertical.climb_max, lim.max_climb_rate or 10)
    return tune
end

return Config
