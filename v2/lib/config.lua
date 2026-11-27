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

-- ------------------------------------------------------------ slot manager
-- A slot is config/<slot>.lua plus (once wired) config/assignments_<slot>.lua.

-- The slots with whether the wizard has wired each one (cheap: no loading).
function Config.slotList()
    local out = {}
    for _, s in ipairs(Config.slots()) do
        out[#out + 1] = { id = s, wired = fs.exists("config/assignments_" .. s .. ".lua") }
    end
    return out
end

-- A typed name -> slot id (lower case, like the original's slots), or nil
-- and why. Side-file prefixes are refused: such a slot would never be listed.
function Config.slotId(name)
    name = tostring(name or "")
    if name == "" or #name > 16 then return nil, "NAME: 1-16 CHARACTERS" end
    if not name:match("^[%w_%-]+$") then return nil, "NAME: LETTERS, DIGITS, _ AND - ONLY" end
    local id = name:lower()
    if not isSlotFile(id .. ".lua") then return nil, "NAME RESERVED: " .. name:upper() end
    for _, s in ipairs(Config.slots()) do
        if s:lower() == id then return nil, "SLOT " .. name:upper() .. " EXISTS" end
    end
    return id
end

-- First free SHIP2, SHIP3, ... for a NEW without a keyboard.
function Config.freeSlotName()
    local n = 2
    while not Config.slotId("SHIP" .. n) do n = n + 1 end
    return "SHIP" .. n
end

local function readFile(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local d = f.readAll()
    f.close()
    return d
end

local function writeFile(path, data)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(data)
    f.close()
    return true
end

-- Copies slot `from` (wiring + assignments) to a new slot named `name`. The
-- copy's ship name becomes `name`, or the top bar couldn't tell them apart.
-- bare = true: the wiring only (a new ship made from the template).
function Config.copySlot(from, name, bare)
    local id, why = Config.slotId(name)
    if not id then return nil, why end
    local ship = readFile("config/" .. from .. ".lua")
    if not ship then return nil, "CAN'T READ " .. from:upper() end
    ship = ship:gsub("(\n%s*name%s*=%s*)\"[^\"\n]*\"", "%1" .. string.format("%q", name), 1)
    if not writeFile("config/" .. id .. ".lua", ship) then return nil, "DISK FULL?" end
    local assign = not bare and readFile("config/assignments_" .. from .. ".lua")
    if assign and not writeFile("config/assignments_" .. id .. ".lua", assign) then
        fs.delete("config/" .. id .. ".lua") -- no half-made slot
        return nil, "DISK FULL?"
    end
    return id
end

-- The first setup's slot name: SHIP, else SHIP2, SHIP3, ...
function Config.firstSlotName()
    if Config.slotId("SHIP") then return "SHIP" end
    return Config.freeSlotName()
end

-- config/assignments_<slot>.lua in the original wizard's format: role ->
-- real peripheral name, plus the config version it was wired for.
function Config.writeAssignments(slot, assign, version)
    local keys = {}
    for k in pairs(assign) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = { "return {\n" }
    if version then out[#out + 1] = "  config_version = " .. string.format("%q", tostring(version)) .. ",\n" end
    for _, k in ipairs(keys) do
        out[#out + 1] = "  [" .. string.format("%q", k) .. "] = " .. string.format("%q", tostring(assign[k])) .. ",\n"
    end
    out[#out + 1] = "}\n"
    return writeFile("config/assignments_" .. slot .. ".lua", table.concat(out))
end

-- ------------------------------------------------------------ text patching
-- The setup learns faces by watching the ship (onboard.lua) and writes them
-- into the slot's copy of the template text, so the file keeps its layout
-- and comments. An edit is { path, key, value }: path names nested table
-- fields ({ "output_map", "FL" }), key is set to the string value (or nil).

-- The index of the "}" closing the "{" at i (skips strings and comments).
local function closeBrace(src, i)
    local depth, n = 0, #src
    while i <= n do
        local c = src:sub(i, i)
        if c == "-" and src:sub(i + 1, i + 1) == "-" then
            i = (src:find("\n", i, true) or n)
        elseif c == "\"" or c == "'" then
            local j = i + 1
            while j <= n and src:sub(j, j) ~= c do
                if src:sub(j, j) == "\\" then j = j + 1 end
                j = j + 1
            end
            i = j
        elseif c == "{" then depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then return i end
        end
        i = i + 1
    end
end

-- The first "name = {" in src[s..e] -> the positions of its braces.
local function findBlock(src, s, e, name)
    local i = s
    while true do
        local a, b = src:find("[^%w_]" .. name .. "%s*=%s*{", i)
        if not a or b > e then return nil end
        local close = closeBrace(src, b)
        if close and close <= e then return b, close end
        i = b + 1
    end
end

function Config.patch(src, edits)
    for _, ed in ipairs(edits) do
        local s, e = 1, #src
        for _, name in ipairs(ed[1]) do
            s, e = findBlock(src, s, e, name)
            if not s then return nil, "NO " .. table.concat(ed[1], "."):upper() .. " IN THE TEMPLATE" end
        end
        local val = ed[3] == nil and "nil" or string.format("%q", ed[3])
        local body = src:sub(s + 1, e - 1)
        local a, b = body:find("[^%w_]" .. ed[2] .. "%s*=%s*[\"'][^\"'\n]*[\"']")
        if not a then a, b = body:find("[^%w_]" .. ed[2] .. "%s*=%s*nil") end
        if a then
            local lhs = body:sub(a, b):match("^(.-=%s*)")
            body = body:sub(1, a - 1) .. lhs .. val .. body:sub(b + 1)
        elseif ed[3] ~= nil then
            body = " " .. ed[2] .. " = " .. val .. "," .. body
        end
        src = src:sub(1, s) .. body .. src:sub(e)
    end
    -- the result must load and say what was asked
    local fn, err = load(src, "=patch", "t", {})
    if not fn then return nil, tostring(err) end
    local ok, t = pcall(fn)
    if not ok or type(t) ~= "table" then return nil, "PATCHED CONFIG DOES NOT LOAD" end
    for _, ed in ipairs(edits) do
        local node = t
        for _, name in ipairs(ed[1]) do node = type(node) == "table" and node[name] or nil end
        if type(node) ~= "table" or node[ed[2]] ~= ed[3] then
            return nil, "PATCH MISSED " .. table.concat(ed[1], "."):upper() .. "." .. ed[2]:upper()
        end
    end
    return src
end

-- Applies edits to config/<slot>.lua in place.
function Config.patchSlot(slot, edits)
    local path = "config/" .. slot .. ".lua"
    local src = readFile(path)
    if not src then return nil, "CAN'T READ " .. slot:upper() end
    local out, err = Config.patch(src, edits)
    if not out then return nil, err end
    if not writeFile(path, out) then return nil, "DISK FULL?" end
    return true
end

function Config.deleteSlot(slot)
    fs.delete("config/" .. slot .. ".lua")
    if fs.exists("config/assignments_" .. slot .. ".lua") then
        fs.delete("config/assignments_" .. slot .. ".lua")
    end
    return not fs.exists("config/" .. slot .. ".lua")
end

-- Remembered by pickSlot on the next start.
function Config.useSlot(root, slot)
    if not fs.exists(root .. "/data") then fs.makeDir(root .. "/data") end
    return writeFile(root .. "/data/slot", slot)
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
