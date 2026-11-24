-- v2 configuration: the ship's existing wiring + v2 tuning.
--
-- Wiring comes from the files the original OS already maintains:
--   config/<slot>.lua              relay names/sides, features, limits
--   config/assignments_<slot>.lua  real peripheral names from the wizard
-- so v2 needs no setup wizard of its own and can never disagree with the
-- original about which wire is which.
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
    if not slot then return nil, "no ship config in config/ (run the original setup once)" end
    local ship, err = loadLuaTable("config/" .. slot .. ".lua")
    if not ship then return nil, "config/" .. slot .. ".lua: " .. tostring(err) end

    local assign = loadLuaTable("config/assignments_" .. slot .. ".lua") or {}
    ship.peripherals = ship.peripherals or {}
    for k, v in pairs(assign) do
        if type(v) == "string" and k ~= "config_version" and k ~= "ship_id" then
            ship.peripherals[k] = v
        end
    end

    local tune = dofile(root .. "/tune.lua")
    local loc = loadLuaTable(root .. "/data/tune_local.lua")
    if loc then U.merge(tune, loc) end
    Config.build(ship, tune)
    return { slot = slot, ship = ship, tune = tune, name = ship.name or slot }
end

-- Derive the ship-specific numbers v2 takes from the ship config.
function Config.build(ship, tune)
    local lim = ship.limits or {}
    tune.ship = {
        hover_throttle = lim.hover_throttle or 6,
        max_altitude = lim.max_altitude or 450,
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
