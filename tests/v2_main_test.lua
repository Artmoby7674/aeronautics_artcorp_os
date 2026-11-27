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
-- peripheral assignments the setup wizard would have written (else it comes
-- up on the terminal): every role keeps the config's names (the simulator's
-- relays); the one-time tour already seen
local WIRED = { "return {\n  config_version = \"1.2\",\n" }
for k, v in pairs(cfg.peripherals) do WIRED[#WIRED + 1] = string.format("  [%q] = %q,\n", k, v) end
WIRED = table.concat(WIRED) .. "}\n"
files["config/assignments_atlas.lua"] = WIRED
files["v2/data/tour_done"] = "1"
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
check("autopilot hop: landed at the waypoint (< 15 m)", sim.pos.y < 64.5 and miss < 15, string.format("y=%.1f miss=%.1f", sim.pos.y, miss))
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

-- back on the template's names for the runs below
files["v2/data/slot"] = "atlas"
files["config/assignments_atlas.lua"] = WIRED

-- ---------------------------------------------------------------- airborne start
-- A restart in the air (error, chunk reload) must take control at once:
-- clutch held, props driven, altitude kept. No splash, no cut props.
for _, m in ipairs({ "main", "config", "nav", "link", "rec", "draw", "ui", "font", "flight", "ctl", "est", "atmos", "ap", "shipdisk", "remote" }) do
    package.loaded[m] = nil
end
w:airborne(120, 0)
files["v2/data/state"] = "return { where = \"air\", gear = false }" -- it was flying
-- tour never seen: it must not cover the controls in the air (the summon
-- run below taps through the screen with it still pending)
files["v2/data/tour_done"] = nil
-- learned values saved by v2.9 (no format tag): the wound-up roll trim and
-- the mid-swing direction answer must not come back
files["v2/data/learned.lua"] = "return { hover = 6.0, ri = 1.8, pi_ = 0.5, rear_pk = -0.4, roll_sign = -1, roll_known = 1, yaw_brake = 0.7 }"
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
local L = load(files["v2/data/learned.lua"] or "return {}")()
check("old learned values: format tagged on save", L.fmt == 3, L.fmt)
check("old learned values: roll trim not reloaded", math.abs(L.ri or 0) < 0.5, L.ri)
check("old learned values: direction check starts over", (L.roll_known or 0) == 0 and L.roll_sign == 1,
    tostring(L.roll_known) .. "/" .. tostring(L.roll_sign))
check("old learned values: yaw braking kept", math.abs((L.yaw_brake or 0) - 0.7) < 0.2, L.yaw_brake)

-- ---------------------------------------------------------------- ArtCorp summon
-- A ship under an ArtCorp summon lock: the pilot taps every way out
-- (E-STOP, POWER OFF, CANCEL A/P). None may stop it flying to the CEO.
for _, m in ipairs({ "main", "config", "nav", "link", "rec", "draw", "ui", "font", "flight", "ctl", "est", "atmos", "ap", "shipdisk", "remote" }) do
    package.loaded[m] = nil
end
w:airborne(150, 0)
local tx, tz = math.floor(sim.pos.x + 300), math.floor(sim.pos.z - 300)
files["v2/data/state"] = "return { where = \"air\", gear = false }"
files["v2/data/artcorp_lock.lua"] = string.format(
    "return { mode = \"summon\", reason = \"summon\", x = %d, z = %d, by = 11 }", tx, tz)
local function dist() return math.sqrt((sim.pos.x - tx) ^ 2 + (sim.pos.z - tz) ^ 2) end
local UI3 = require("ui") -- the fresh UI module main will use: hook it for hit lookup
local render3 = UI3.render
UI3.render = function(self, m) UI3._last = self return render3(self, m) end
local function tapAction(action)
    for _, h in ipairs(UI3._last and UI3._last.hits or {}) do
        if h.action == action then return touchCell(h.x + 5, h.y + 5) end
    end
    states.missing_hit = (states.missing_hit or "") .. action .. " "
end
mon.errors = {}
timers, script, si = {}, {}, 1
t0 = sim.t
states.d0 = dist()
at(t0 + 3, function() return tapAction("tab:ctrl") end)
at(t0 + 5, function() return tapAction("ctl:estop") end)
at(t0 + 7, function() return tapAction("ctl:power") end)
at(t0 + 8, function() return tapAction("ctl:power") end) -- the "tap again" confirm
at(t0 + 10, function() return tapAction("tab:auto") end)
at(t0 + 12, function() return tapAction("ap:cancel") end)
-- loading world data from a disk in the air: refused (it restarts the OS)
at(t0 + 14, function() return tapAction("tab:ship") end)
at(t0 + 15, function() return tapAction("ship:diskload") end)
at(t0 + 60, function() states.d60 = dist() end)
-- then the remote: RELEASE, DISPATCH to waypoint 1, SCAN
local sent3 = {}
local rednet_saved = _G.rednet
_G.rednet = { open = function() end, broadcast = function() end,
    send = function(to, m) sent3[#sent3 + 1] = m return true end }
local function rn(m) m.proto = "artcorp" return { "rednet_message", 11, m, "artcorp" } end
at(t0 + 61, function() return rn({ op = "cmd", cmd = "unlock" }) end)
at(t0 + 62, function() states.lock_after_release = files["v2/data/artcorp_lock.lua"] end)
at(t0 + 63, function() return rn({ op = "cmd", cmd = "goto", idx = 1 }) end)
at(t0 + 65, function() return rn({ op = "cmd", cmd = "goto", idx = 99 }) end)
at(t0 + 67, function() return rn({ op = "scan" }) end)
at(t0 + 68, function() return rn({ op = "wps" }) end)
at(t0 + 70, function() return { "terminate" } end)
printed = {}
_G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
local ok3, err3 = pcall(require("main").run, { runs = 3 })
_G.print = real_print
_G.rednet = rednet_saved
local acks, here = {}, nil
for _, m in ipairs(sent3) do
    if m.op == "ack" then acks[#acks + 1] = m end
    if m.op == "here" then here = m end
    if m.op == "wps" then states.wps_reply = m end
end
check("remote: release acked", acks[1] and acks[1].cmd == "unlock" and acks[1].ok == true)
check("remote: release removed the lock file", states.lock_after_release == nil)
check("remote: dispatch acked", acks[2] and acks[2].cmd == "goto" and acks[2].ok == true)
check("remote: bad dispatch refused with a reason", acks[3] and acks[3].ok == false and acks[3].why == "NO SUCH WAYPOINT",
    acks[3] and tostring(acks[3].why))
check("remote: scan reply lists the waypoints", here and type(here.wps) == "table" and here.wps[1] ~= nil)
local wr = states.wps_reply
check("remote: full waypoint list answered", wr and type(wr.list) == "table" and #wr.list >= 1
    and wr.list[1].i == 1 and wr.list[1].name ~= nil and wr.list[1].x ~= nil and wr.list[1].z ~= nil,
    wr and wr.list and #wr.list)
check("remote: scan tells how many waypoints", here and here.nwps == (wr and wr.list and #wr.list), here and here.nwps)
check("remote: scan reply shows the dispatch route", here and here.ap and here.ap.name ~= nil,
    here and here.ap and here.ap.name)
local refused = 0
for _, l in ipairs(printed) do if l:find("LOCKED BY ARTCORP") then refused = refused + 1 end end
print(string.format("summon lock: %.0f m -> %.0f m from the CEO, %d taps refused, missing hits: %s",
    states.d0 or -1, states.d60 or -1, refused, tostring(states.missing_hit)))
check("summon lock: ran", ok3, err3)
local landFirst = false
for _, l in ipairs(printed) do if l:find("LAND FIRST: LOADING RESTARTS THE OS") then landFirst = true end end
check("disk: LOAD refused in the air", landFirst)
check("summon lock: the pilot's taps were refused", refused >= 3, refused)
check("tour: never opened in the air", UI3._last and UI3._last.tour == nil and files["v2/data/tour_done"] == nil)
check("summon lock: still flying to the CEO", (states.d60 or 1e9) < (states.d0 or 0) - 100,
    string.format("%.0f -> %.0f", states.d0 or -1, states.d60 or -1))

-- ---------------------------------------------------------------- first launch
-- No peripheral assignments: the original OS's setup wizard runs on the
-- computer's terminal (all modems unplugged, then one device at a time),
-- writes config/assignments_atlas.lua with the names THIS world gave the
-- relays and the monitor, and the flight OS starts straight after on them.
local MODS = { "main", "config", "nav", "link", "rec", "draw", "ui", "font", "flight", "ctl", "est", "atmos", "ap",
    "shipdisk", "remote", "wizard" }
for _, m in ipairs(MODS) do package.loaded[m] = nil end
w = World.new() -- back on the ground, engines off
sim = w.sim
-- the names this world gave each device (placement order) -> the sim's own
local ORDER = { "input_1", "input_2", "aux_relay", "engine_relay", "output_FL", "output_FR", "output_RL", "output_RR",
    "output_REAR", "main_monitor" }
local alias, net = {}, { back = "modem" } -- the computer's own modem stays: never a device
for i, k in ipairs(ORDER) do
    local n = k == "main_monitor" and "monitor_4" or ("redstone_relay_" .. (20 + i))
    alias[n] = cfg.peripherals[k]
end
local saved_names, saved_type, saved_wrap = peripheral.getNames, peripheral.getType, peripheral.wrap
peripheral.getNames = function()
    local out = {}
    for n in pairs(net) do out[#out + 1] = n end
    return out
end
peripheral.getType = function(n) return net[n] end
peripheral.wrap = function(name)
    if not net[name] or name == "back" then return nil end
    if net[name] == "monitor" then return mon end
    return sim:relay(alias[name])
end
files["config/assignments_atlas.lua"] = nil
files["v2/data/state"], files["v2/data/tour_done"], files["v2/data/artcorp_lock.lua"] = nil, nil, nil
local saved_colors = rawget(_G, "colors")
_G.colors = { white = 1, lightBlue = 8, yellow = 16, lime = 32, lightGray = 256, cyan = 512, blue = 2048,
    red = 16384, black = 32768 }
do
    local Tm = dofile("tests/v2/term.lua").new()
    local saved_term, saved_keys = _G.term, _G.keys
    _G.term = Tm.api
    -- before the OS's loops start there is no coroutine to yield from: the
    -- wizard's events come straight off the script
    local raw = os.pullEventRaw
    os.pullEventRaw = function(filter)
        if coroutine.isyieldable() then return coroutine.yield(filter) end
        return nextEvent()
    end
    local wz = {}
    mon.errors = {}
    timers, script, si = {}, {}, 1
    t0 = sim.t
    at(t0 + 0.5, function() wz.intro = Tm.text() return { "key", 28 } end)
    for i, k in ipairs(ORDER) do
        local n = k == "main_monitor" and "monitor_4" or ("redstone_relay_" .. (20 + i))
        at(t0 + 1 + i * 0.5, function()
            net[n] = k == "main_monitor" and "monitor" or "redstone_relay"
            return { "peripheral", n }
        end)
    end
    at(t0 + 7, function() wz.printer = Tm.text() return { "key", 31 } end) -- S: no printer
    -- 3 s later the OS is up: the tour (never seen) is on the start screen
    at(t0 + 15, function()
        wz.term_after = Tm.text()
        wz.tour = require("ui")._last and require("ui")._last.tour ~= nil
        return { "terminate" }
    end)
    _G.keys = { s = 31, getName = function(c) return c == 31 and "s" or nil end }
    local UIw = require("ui")
    local rw = UIw.render
    UIw.render = function(self, m) UIw._last = self return rw(self, m) end
    printed = {}
    _G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
    local okW, errW = pcall(require("main").run, { runs = 5 })
    _G.print = real_print
    os.pullEventRaw, _G.term, _G.keys = raw, saved_term, saved_keys
    check("wizard first: ran", okW, errW)
    check("wizard first: on the terminal, all modems out first", wz.intro and wz.intro:find("Disconnect ALL modems", 1, true) ~= nil, wz.intro)
    check("wizard first: printer offered after the 10 roles", wz.printer and wz.printer:find("Press S to skip", 1, true) ~= nil, wz.printer)
    local A = load(files["config/assignments_atlas.lua"] or "return nil")()
    check("wizard first: assignments written", type(A) == "table" and A.config_version == "1.2")
    check("wizard first: world names, in order", A and A.input_1 == "redstone_relay_21" and A.output_REAR == "redstone_relay_29"
        and A.main_monitor == "monitor_4" and A.printer == nil)
    local log = files["v2/data/log.txt"] or ""
    check("wizard first: OS started on them, nothing missing", log:find("missing peripherals", 1, true) == nil
        and log:find("screen monitor_4: 348x216 px", 1, true) ~= nil, log:sub(-600))
    check("wizard first: OS drew its first frame", log:find("frame 1 drawn", 1, true) ~= nil)
    check("wizard first: then the tour", wz.tour == true)
    check("wizard first: no draw errors", #mon.errors == 0, mon.errors[1])
end
-- a second start with that file: no wizard, straight to the OS
for _, m in ipairs(MODS) do package.loaded[m] = nil end
do
    local asked = false
    local Tm = dofile("tests/v2/term.lua").new()
    local saved_term = _G.term
    _G.term = Tm.api
    timers, script, si = {}, {}, 1
    t0 = sim.t
    at(t0 + 3, function() asked = Tm.text():find("PERIPHERAL SETUP", 1, true) ~= nil return { "terminate" } end)
    printed = {}
    _G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
    local okR, errR = pcall(require("main").run, { runs = 6 })
    _G.print = real_print
    _G.term = saved_term
    check("second start: ran", okR, errR)
    check("second start: no wizard", not asked)
end
peripheral.getNames, peripheral.getType, peripheral.wrap = saved_names, saved_type, saved_wrap
_G.colors = saved_colors

_G.loadfile, _G.dofile, _G.fs = saved.loadfile, saved.dofile, saved.fs
print(string.format("v2_main_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_main_test FAILED", 0) end
