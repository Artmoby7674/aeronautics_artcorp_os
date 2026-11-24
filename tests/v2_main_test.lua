-- v2 end-to-end: the REAL main loop (v2/lib/main.lua) driven by a scripted
-- CC event stream, on a virtual disk, flying the simulator. Covers boot
-- (starter, clutch), touch actions, takeoff, saving a waypoint, an autopilot
-- hop that lands and powers off, persistence of learned values, terminate.
package.path = "./tests/v2/?.lua;./v2/lib/ui/?.lua;" .. package.path
local World = dofile("tests/v2/world.lua")
local Mon = require("monitor")
for _, m in ipairs({ "main", "config", "nav", "link", "rec", "draw", "ui", "font" }) do package.loaded[m] = nil end

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1 else
        failed = failed + 1
        print("FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end

-- ---------------------------------------------------------------- world
local w = World.new()
local sim = w.sim
local cfg = w.ship
local mon = Mon.new()

-- ---------------------------------------------------------------- virtual disk
local files = {}
local function readReal(p) local f = io.open(p, "r") local d = f:read("a") f:close() return d end
files["config/atlas.lua"] = readReal("config/atlas.lua")
files["v2/tune.lua"] = readReal("v2/tune.lua")
files["config/wp_atlas.lua"] = "return { { name = \"reactor\", x = 40, z = -30, heading = 194.5 } }"
local dirs = { ["config"] = true, ["v2"] = true }

local saved = { loadfile = loadfile, dofile = dofile, fs = rawget(_G, "fs") }
local function vload(path, mode, env)
    local d = files[path]
    if not d then return nil, "no file " .. path end
    return load(d, "@" .. path, "t", env or _G)
end
_G.loadfile = vload
_G.dofile = function(path)
    local fn, err = vload(path)
    if not fn then return saved.dofile(path) end
    return fn()
end
_G.fs = {
    exists = function(p) return files[p] ~= nil or dirs[p] == true end,
    isDir = function(p) return dirs[p] == true end,
    makeDir = function(p) dirs[p] = true end,
    list = function(d)
        local out = {}
        for p in pairs(files) do
            local rest = p:match("^" .. d:gsub("%p", "%%%0") .. "/([^/]+)$")
            if rest then out[#out + 1] = rest end
        end
        return out
    end,
    delete = function(p) files[p] = nil end,
    move = function(a, b) files[b] = files[a] files[a] = nil end,
    getFreeSpace = function() return 600000 end,
    open = function(p, mode)
        if mode == "r" then
            if not files[p] then return nil end
            local d = files[p]
            return { readAll = function() return d end, close = function() end }
        end
        local buf = { mode == "a" and files[p] or nil }
        return {
            write = function(s) buf[#buf + 1] = s end,
            writeLine = function(s) buf[#buf + 1] = s .. "\n" end,
            close = function() files[p] = table.concat(buf) end,
        }
    end,
}

-- ---------------------------------------------------------------- CC stubs
local function ser(v, ind)
    ind = ind or ""
    if type(v) == "table" then
        local out = { "{\n" }
        for k, x in pairs(v) do
            local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
            out[#out + 1] = ind .. "  " .. key .. " = " .. ser(x, ind .. "  ") .. ",\n"
        end
        out[#out + 1] = ind .. "}"
        return table.concat(out)
    elseif type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end
_G.textutils = { serialize = ser, unserialize = function(s) return load("return " .. s)() end,
    formatTime = function(t) return string.format("%.2f", t) end }
os.time = os.time or function() return 0 end
fs.getSize = function(p) return #(files[p] or "") end
_G.rednet = { open = function() end, send = function() return true end, broadcast = function() end }
_G.keys = { getName = function() return nil end }
_G.term = { nativePaletteColour = function() return 0, 0, 0 end }
_G.printError = print
local printed = {}
local real_print = print
_G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end

local simwrap = peripheral.wrap
peripheral.wrap = function(name)
    if name == cfg.peripherals.main_monitor then return mon end
    return simwrap(name)
end
peripheral.getNames = function() return {} end
peripheral.find = function() return nil end

-- ---------------------------------------------------------------- event script
timers, next_id = {}, 0
os.startTimer = function(d)
    next_id = next_id + 1
    timers[next_id] = sim.t + d
    return next_id
end

script = {}   -- { t = time, fn = function() return event or nil end }
local function at(t, fn) script[#script + 1] = { t = t, fn = fn } end
-- CC:Graphics delivers taps as 1-based PIXEL positions in pixel mode
local function touchCell(px, py) return { "monitor_touch", "main_monitor", math.floor(px) + 1, math.floor(py) + 1 } end

local Main = require("main")
local UIref = require("ui")
local Dref = require("draw")
local states = {}

-- 0.5 s: tap START on the splash
at(0.5, function() return touchCell(Dref.W / 2, 128) end)
-- 1.5 s: starter should be on, clutch off
at(1.5, function()
    local e = cfg.engine
    local r = sim:relay(cfg.peripherals[e.relay_key])
    states.starter_mid = r.out[e.start_side]
    states.clutch_mid = r.out[e.clutch_side] or 0
end)
-- 6 s: powered on, parked -> press SPACE to take off
at(5.9, function()
    -- engines just started from the start screen: parked, no tilt, gear down
    local o = sim:readOutputs()
    states.boot_tilt = o.FL_tilt ~= 0 or o.FR_tilt ~= 0 or o.RL_tilt ~= 0 or o.RR_tilt ~= 0
end)
at(6, function()
    local e = cfg.engine
    local r = sim:relay(cfg.peripherals[e.relay_key])
    states.clutch_on = r.out[e.clutch_side]
    states.starter_after = r.out[e.start_side]
    sim:press("SPACE", true)
end)
at(6.2, function() sim:press("SPACE", false) end)
-- 20 s: go to NAV, the imported waypoint should be there; tap FLY
at(20, function() states.alt20 = sim.pos.y return touchCell(Dref.W / 6 * 1.5, Dref.H - 8) end)
at(20.5, function() states.tab = "nav" end)
at(21, function()
    -- FLY button is the first in the NAV button block
    for _, h in ipairs(UIref._last.hits) do
        if h.action == "wp:fly" then return touchCell(h.x + 5, h.y + 5) end
    end
end)
at(300, function() return { "terminate" } end)

si = 1
local pending = {}
local function nextEvent()
    while true do
        if #pending > 0 then return table.unpack(table.remove(pending, 1)) end
        -- next timer
        local tid, tt = nil, math.huge
        for id, t in pairs(timers) do if t < tt then tid, tt = id, t end end
        local s = script[si]
        if s and s.t <= tt then
            si = si + 1
            while sim.t < s.t do sim:step(0.05) end
            local ev = s.fn()
            if ev then return table.unpack(ev) end
        else
            timers[tid] = nil
            while sim.t + 1e-9 < tt do sim:step(0.05) end
            return "timer", tid
        end
    end
end

os.queueEvent = function(...) pending[#pending + 1] = { ... } end
os.pullEventRaw = function(filter) return coroutine.yield(filter) end
-- Like CC: telemetry is a main-thread call, so the calling coroutine is
-- suspended until "task_complete" and drops every other event meanwhile.
-- (This is what starved the old single-loop design of its screen timer.)
local task_n = 0
local rawPose = sublevel.getLogicalPose
sublevel.getLogicalPose = function()
    if coroutine.isyieldable() then
        task_n = task_n + 1
        local n = task_n
        os.queueEvent("task_complete", n)
        repeat local _, id = coroutine.yield("task_complete") until id == n
    end
    return rawPose()
end
-- CC's parallel API: every coroutine gets only the events matching its
-- filter (or all, with no filter); events arriving for a coroutine that is
-- waiting on something else are simply not delivered to it.
_G.parallel = {
    waitForAny = function(...)
        local cos, filters = {}, {}
        for i, fn in ipairs({ ... }) do
            cos[i] = coroutine.create(fn)
            local ok, f = coroutine.resume(cos[i])
            if not ok then error(f, 0) end
            filters[i] = f
            if coroutine.status(cos[i]) == "dead" then return i end
        end
        while true do
            local ev = { nextEvent() }
            for i, co in ipairs(cos) do
                if filters[i] == nil or filters[i] == ev[1] or ev[1] == "terminate" then
                    local ok, f = coroutine.resume(co, table.unpack(ev))
                    if not ok then error(f, 0) end
                    filters[i] = f
                    if coroutine.status(co) == "dead" then return i end
                end
            end
        end
    end,
}

-- capture the UI instance for hit lookup
local render = UIref.render
UIref.render = function(self, m) UIref._last = self return render(self, m) end

local ok, err = pcall(Main.run)
_G.print = real_print
if not ok then print("main crashed: " .. tostring(err)) end
check("main loop ran to terminate", ok, err)

check("boot: starter on during start", states.starter_mid == 15, states.starter_mid)
check("boot: clutch still out during start", states.clutch_mid == 0, states.clutch_mid)
check("boot: clutch engaged after boot", states.clutch_on == 15, states.clutch_on)
check("boot: starter released after boot", states.starter_after == 0, states.starter_after)
check("engine start: no prop tilt on the ground", states.boot_tilt == false, tostring(states.boot_tilt))
check("takeoff: climbed after SPACE", (states.alt20 or 0) > 68, states.alt20)
check("waypoints: imported from the old OS", files["v2/data/waypoints.lua"] and files["v2/data/waypoints.lua"]:find("REACTOR") ~= nil)
local miss = math.sqrt((sim.pos.x - 40) ^ 2 + (sim.pos.z + 30) ^ 2)
check("autopilot hop: landed at the waypoint (< 10 m)", sim.pos.y < 64.5 and miss < 10, string.format("y=%.1f miss=%.1f", sim.pos.y, miss))
local r = sim:relay(cfg.peripherals[cfg.engine.relay_key])
check("autopilot hop: powered off (clutch out)", (r.out[cfg.engine.clutch_side] or 0) == 0)
check("learned values saved", files["v2/data/learned.lua"] ~= nil)
check("slot remembered", files["v2/data/slot"] == "atlas", files["v2/data/slot"])
local errs = 0
for _, l in ipairs(printed) do if l:find("ERROR") or l:find("%[UI%]") then errs = errs + 1 print("  log: " .. l) end end
check("no runtime errors logged", errs == 0, errs)
check("no draw errors", #mon.errors == 0, mon.errors[1])
check("state: saved as ground after the landed power-off", (files["v2/data/state"] or ""):find("ground") ~= nil, files["v2/data/state"])
local log = files["v2/data/log.txt"] or ""
check("log: screen setup recorded", log:find("screen main_monitor: 348x216 px") ~= nil, log:sub(1, 300))
check("log: taps recorded", log:find("touch main_monitor") ~= nil)
check("log: first frame recorded", log:find("frame 1 drawn") ~= nil)
check("screen kept refreshing (frame 50 reached)", log:find("frame 50 drawn") ~= nil)

-- ---------------------------------------------------------------- airborne start
-- A restart in the air (error, chunk reload) must take control at once:
-- clutch held, props driven, altitude kept. No splash, no cut props.
for _, m in ipairs({ "main", "config", "nav", "link", "rec", "draw", "ui", "font", "flight", "ctl", "est", "ap" }) do
    package.loaded[m] = nil
end
w:airborne(120, 0)
files["v2/data/state"] = "return { where = \"air\", gear = false }" -- it was flying
mon.errors = {}
timers, script, si = {}, {}, 1
local t0 = sim.t
at(t0 + 8, function()
    states.air_alt = sim.pos.y
    local e = cfg.engine
    states.air_clutch = sim:relay(cfg.peripherals[e.relay_key]).out[e.clutch_side]
    states.air_props = sim:readOutputs().FL
    return { "terminate" }
end)
printed = {}
_G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
local ok2, err2 = pcall(require("main").run, { recovered = "test error", runs = 2 })
_G.print = real_print
check("airborne start: ran", ok2, err2)
check("airborne start: clutch held", states.air_clutch == 15, states.air_clutch)
check("airborne start: props driven", (states.air_props or 0) > 2, states.air_props)
check("airborne start: altitude kept", math.abs((states.air_alt or 0) - 120) < 3, states.air_alt)
local said = false
for _, l in ipairs(printed) do if l:find("RESTARTED AFTER AN ERROR") then said = true end end
check("airborne start: tells the pilot it restarted", said)

_G.loadfile, _G.dofile, _G.fs = saved.loadfile, saved.dofile, saved.fs
print(string.format("v2_main_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_main_test FAILED", 0) end
