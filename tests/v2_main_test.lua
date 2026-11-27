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
-- a wired slot (else the first-launch setup comes up) whose roles keep the
-- template's names (the simulator's relays); the one-time tour already seen
local WIRED = "return { config_version = \"1.2\" }"
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

-- ---------------------------------------------------------------- save slots
-- Parked on the ground after the hop: SHIP > SLOTS. NEW copies the running
-- slot (keyboard offline: auto-named), the running slot can't be deleted,
-- another one can (two taps), USE switches (two taps) and restarts.
for _, m in ipairs({ "main", "config", "nav", "link", "rec", "draw", "ui", "font", "flight", "ctl", "est", "atmos", "ap", "shipdisk", "remote" }) do
    package.loaded[m] = nil
end
files["config/assignments_atlas.lua"] = "return { config_version = 3 }" -- copied along, wires nothing
files["config/spare.lua"] = files["config/atlas.lua"]
files["config/assignments_spare.lua"] = "return { config_version = 3 }"
do
    local UIs = require("ui")
    local renderS = UIs.render
    UIs.render = function(self, m) UIs._last = self return renderS(self, m) end
    local function tap(action)
        return function()
            for _, h in ipairs(UIs._last and UIs._last.hits or {}) do
                if h.action == action then return touchCell(h.x + 5, h.y + 5) end
            end
            states.slot_missing = (states.slot_missing or "") .. action .. " "
        end
    end
    local saved_reboot = os.reboot
    os.reboot = function() states.rebooted = sim.t end
    mon.errors = {}
    timers, script, si = {}, {}, 1
    local t0 = sim.t
    at(t0 + 0.5, function() return touchCell(Dref.W / 2, 128) end) -- START
    at(t0 + 8, tap("tab:ship"))
    at(t0 + 9, tap("ship:slots"))
    at(t0 + 9.5, function() states.slot_tab = UIs._last.tab end)
    at(t0 + 10, tap("slot:new"))
    at(t0 + 11, tap("slot:row:0")) -- atlas, the running one
    at(t0 + 12, tap("slot:del"))
    at(t0 + 13, tap("slot:row:2")) -- spare
    at(t0 + 14, tap("slot:del"))
    at(t0 + 14.5, function() states.spare_after_one_tap = files["config/spare.lua"] ~= nil end)
    at(t0 + 15, tap("slot:del"))
    at(t0 + 16, tap("slot:row:1")) -- ship2
    at(t0 + 17, tap("slot:use"))
    at(t0 + 17.5, function() states.slot_after_one_tap = files["v2/data/slot"] end)
    at(t0 + 18, tap("slot:use"))
    at(t0 + 21, function() return { "terminate" } end)
    printed = {}
    _G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
    local okS, errS = pcall(require("main").run, { runs = 4 })
    _G.print = real_print
    os.reboot = saved_reboot
    local function said(text)
        for _, l in ipairs(printed) do if l:find(text, 1, true) then return true end end
        return false
    end
    check("slots: ran", okS, errS)
    check("slots: every button found", states.slot_missing == nil, states.slot_missing)
    check("slots: SLOTS opens the sub-screen", states.slot_tab == "slots", states.slot_tab)
    check("slots: NEW copied the wiring", (files["config/ship2.lua"] or ""):find("name = \"SHIP2\"", 1, true) ~= nil)
    check("slots: NEW copied the assignments", files["config/assignments_ship2.lua"] == files["config/assignments_atlas.lua"])
    check("slots: NEW said so", said("NEW SLOT SHIP2"))
    check("slots: running slot not deleted", files["config/atlas.lua"] ~= nil and said("CAN'T DELETE THE RUNNING SLOT"))
    check("slots: DELETE asks first", states.spare_after_one_tap == true and said("TAP DELETE AGAIN"))
    check("slots: DELETE removed both files", files["config/spare.lua"] == nil and files["config/assignments_spare.lua"] == nil)
    check("slots: USE asks first", states.slot_after_one_tap == "atlas", states.slot_after_one_tap)
    check("slots: USE remembered the slot", files["v2/data/slot"] == "ship2", files["v2/data/slot"])
    check("slots: USE restarted the OS", states.rebooted ~= nil and states.rebooted >= t0 + 18, states.rebooted)
    check("slots: no draw errors", #mon.errors == 0, mon.errors[1])
    -- names: letters, digits, _ and - only; no side-file prefixes, no twins
    local Cf = require("config")
    check("slot name: bad characters refused", Cf.slotId("my ship") == nil and Cf.slotId("a.b") == nil)
    check("slot name: side-file prefix refused", Cf.slotId("wp_x") == nil)
    check("slot name: existing refused (any case)", Cf.slotId("ATLAS") == nil)
    check("slot name: good one lower-cased", Cf.slotId("Cargo_2-b") == "cargo_2-b")
    check("slot name: next free auto name", Cf.freeSlotName() == "SHIP3", Cf.freeSlotName())
end
-- back to atlas for the runs below (ship2 stays: the summon run uses it)
files["v2/data/slot"] = "atlas"
files["config/assignments_atlas.lua"] = WIRED
files["config/assignments_ship2.lua"] = nil

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
-- switching slots in the air: refused (it would restart the OS mid-flight)
at(t0 + 14, function() return tapAction("tab:ship") end)
at(t0 + 15, function() return tapAction("ship:slots") end)
at(t0 + 16, function() return tapAction("slot:row:1") end) -- ship2
at(t0 + 17, function() return tapAction("slot:use") end)
at(t0 + 18, function() return tapAction("slot:use") end)
at(t0 + 19, function() return tapAction("slot:back") end)
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
for _, l in ipairs(printed) do if l:find("LAND FIRST: SWITCHING") then landFirst = true end end
check("slots: USE refused in the air", landFirst and files["v2/data/slot"] == "atlas", files["v2/data/slot"])
check("summon lock: the pilot's taps were refused", refused >= 3, refused)
check("tour: never opened in the air", UI3._last and UI3._last.tour == nil and files["v2/data/tour_done"] == nil)
check("summon lock: still flying to the CEO", (states.d60 or 1e9) < (states.d0 or 0) - 100,
    string.format("%.0f -> %.0f", states.d0 or -1, states.d60 or -1))

-- ---------------------------------------------------------------- first launch
-- No wired ship on the computer: the setup comes up on the monitor instead
-- of the OS stopping on "no ship config". A network of the template's relays
-- (plus a spare) and the cockpit monitor, as peripheral.getNames lists them.
local MODS = { "main", "config", "nav", "link", "rec", "draw", "ui", "font", "flight", "ctl", "est", "atmos", "ap",
    "shipdisk", "remote", "onboard" }
local function fresh() for _, m in ipairs(MODS) do package.loaded[m] = nil end end
local NET = { "relay_spare" }
for _, n in pairs(cfg.peripherals) do NET[#NET + 1] = n end
local saved_names, saved_type = peripheral.getNames, peripheral.getType
peripheral.getNames = function() return NET end
peripheral.getType = function(n)
    if n == cfg.peripherals.main_monitor then return "monitor" end
    return "redstone_relay"
end
-- back on the ground, engines off, nothing wired
w = World.new()
sim = w.sim
peripheral.getNames = function() return NET end
peripheral.getType = function(n)
    if n == cfg.peripherals.main_monitor then return "monitor" end
    return "redstone_relay"
end
peripheral.wrap = function(name)
    if name == cfg.peripherals.main_monitor then return mon end
    return sim:relay(name)
end
for p in pairs(files) do
    if p:match("^config/") and p ~= "config/atlas.lua" and p ~= "config/wp_atlas.lua" then files[p] = nil end
end
files["config/assignments_atlas.lua"] = nil
files["v2/data/slot"], files["v2/data/state"], files["v2/data/tour_done"] = nil, nil, nil
files["v2/data/artcorp_lock.lua"] = nil

local function hooked()
    local UIx = require("ui")
    local r = UIx.render
    UIx.render = function(self, m) UIx._last = self return r(self, m) end
    return UIx
end
local function runMain(o)
    printed = {}
    _G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
    local ok, res = pcall(require("main").run, o or { runs = 5 })
    _G.print = real_print
    return ok, res
end
local function saidIt(text)
    for _, l in ipairs(printed) do if l:find(text, 1, true) then return true end end
    return false
end

-- 1. not even a template: the welcome screen, SET UP says why, no crash
fresh()
local atlas_src = files["config/atlas.lua"]
files["config/atlas.lua"] = nil
do
    local UIo = hooked()
    mon.errors = {}
    timers, script, si = {}, {}, 1
    t0 = sim.t
    at(t0 + 0.5, function()
        states.ob0_screen = UIo._last and UIo._last.screen
        states.ob0_welcome = require("onboard")._st.screen
        for _, h in ipairs(UIo._last.hits) do if h.action == "ob:setup" then return touchCell(h.x + 5, h.y + 5) end end
    end)
    at(t0 + 1, function() return { "terminate" } end)
    local okN, resN = runMain()
    check("no config at all: no crash", okN, resN)
    check("no config at all: setup on the monitor", states.ob0_screen == "onboard" and states.ob0_welcome == "welcome",
        tostring(states.ob0_screen) .. "/" .. tostring(states.ob0_welcome))
    check("no config at all: SET UP says the template is missing", saidIt("NO TEMPLATE"))
    check("no config at all: terminate stops it", resN == "stop", resN)
end
files["config/atlas.lua"] = atlas_src

-- 2. SET UP THIS SHIP: engines, the keyboard relays (DETECT, a used relay,
-- BACK, scrolling), then the computer fires every relay face and a "player"
-- who only looks at the ship answers what moved; the buttons; the guide;
-- then the OS with the tour.
--
-- The player: a fake ship computes what can be SEEN from the relay outputs
-- and its true wiring (truth: a config table) on every write: prop tilts,
-- props / rear turning (only with the clutch in; slow-down links, 0 = full),
-- rear reverse while it turns, gear. It also keeps the safety numbers.
local PROPS4 = { "FL", "FR", "RL", "RR" }
local function shipModel(truth, R)
    local function out(role, face)
        if not face then return 0 end
        local r = R(truth.peripherals[role])
        return r and (r.out[face] or 0) or 0
    end
    return function()
        local S = { tilt = {}, spin = {}, lift = 0 }
        local e = truth.engine
        S.clutch = out(e.relay_key, e.clutch_side) > 0
        for _, p in ipairs(PROPS4) do
            local m = truth.output_map[p]
            local f, b = out(m.relay, m.tilt_fwd) > 0, out(m.relay, m.tilt_bwd) > 0
            S.tilt[p] = f and 1 or (b and -1 or 0)
            S.spin[p] = S.clutch and (15 - out(m.relay, m.speed)) or 0
            S.lift = S.lift + S.spin[p]
        end
        local m = truth.output_map.REAR
        S.rear = S.clutch and math.max(15 - out(m.relay, m.fw), 15 - out(m.relay, m.bw)) or 0
        S.rev = out(m.relay, m.rev) > 0
        S.gear = out(truth.gear_output.relay, truth.gear_output.side) > 0
        return S
    end
end

local function observer(Ob, stateFn)
    local obs = { seen = {}, max_full = 0, max_lift_known = 0, max_lift = 0, writes = 0 }
    function obs.update()
        obs.writes = obs.writes + 1
        local st = Ob._st
        local S = stateFn()
        local t = os.clock()
        if st and st.fire_id ~= obs.id then obs.id, obs.S0, obs.seen = st.fire_id, obs.last or S, {} end
        local S0, sn = obs.S0 or S, obs.seen
        for p, v in pairs(S.tilt) do if v ~= S0.tilt[p] and v ~= 0 then sn.tilt = sn.tilt or {} sn.tilt[p] = v end end
        for p, v in pairs(S.spin) do if v ~= S0.spin[p] then sn.spin = sn.spin or {} sn.spin[p] = true end end
        if S.gear ~= S0.gear then sn.gear = true end
        if S.rear ~= S0.rear then
            sn.rear = true
            if S.rear > 0 then sn.rear_dir = S.rev and "bw" or "fw" end
        end
        if obs.last and S.rear > 0 and obs.last.rear > 0 and S.rev ~= obs.last.rev then sn.rev = true end
        if S.clutch and not S0.clutch then sn.clutch_in = true end
        obs.max_lift = math.max(obs.max_lift, S.lift)
        local k = Ob._know and Ob._know()
        obs.clutch_known = k ~= nil and k.face.ENGINE ~= nil -- (an undone clutch answer is unknown again)
        if obs.clutch_known then obs.max_lift_known = math.max(obs.max_lift_known, S.lift) end
        if S.lift >= 24 then obs.full_t = obs.full_t or t
        elseif obs.full_t then obs.max_full = math.max(obs.max_full, t - obs.full_t) obs.full_t = nil end
        obs.last = S
    end
    -- what a player watching the ship would tap
    function obs.answer(stage)
        if obs.id ~= Ob._st.fire_id then return "NOTHING" end
        local sn = obs.seen
        if stage <= 1 then
            if sn.clutch_in and (sn.spin or sn.rear) then return "ENGINE" end
            for _, p in ipairs(PROPS4) do
                local v = sn.tilt and sn.tilt[p]
                if v then return p, v > 0 and "tilt_fwd" or "tilt_bwd" end
            end
            if sn.gear then return "GEAR" end
        elseif stage == 2 then
            for _, p in ipairs(PROPS4) do if sn.spin and sn.spin[p] then return p, "speed" end end
            if sn.rear then return "REAR", sn.rear_dir or "fw" end
        elseif sn.rev then
            return "REAR", "rev"
        end
        return "NOTHING"
    end
    function obs.watch(r)
        if r._watched then return end
        local f = r.setAnalogOutput
        r.setAnalogOutput = function(side, v) f(side, v) obs.update() end
        r._watched = true
        obs.last = stateFn() -- what the ship looks like before the first write
    end
    return obs
end

-- one step per driver tick: each returns done (move on), event
local function Seq(list)
    local i = 1
    return function()
        local f = list[i]
        if not f then return nil end
        local done, ev = f()
        if done then i = i + 1 end
        return ev
    end
end
local function once(fn) return function() return true, fn() end end
local function sleepFor(s)
    local t
    return function()
        t = t or sim.t
        if sim.t - t >= s - 1e-6 then t = nil return true end
        return false
    end
end

local function players(Ob, truth, R, tapUI, obs, o)
    local P = {}
    function P.screen(name) return function() return Ob._st.screen == name end end
    -- keyboard relays: press one of the role's keys, DETECT, NEXT
    function P.keys()
        local held
        return function()
            local st = Ob._st
            if st.screen ~= "role" then
                if held then held.r.inp[held.f] = 0 held = nil end
                return true
            end
            local want = truth.peripherals[st.role.key]
            local c = st.sel and st.cands[st.sel]
            if c and c.name == want then
                if held then held.r.inp[held.f] = 0 held = nil end
                return false, tapUI("ob:next")
            end
            if not st.detect then
                if held then held.r.inp[held.f] = 0 held = nil end
                return false, tapUI("ob:test")
            end
            if not held then -- a press after DETECT starts listening
                local r = R(want)
                held = { r = r, f = st.role.faces[1] }
                r.inp[held.f] = 15
            end
            return false
        end
    end
    -- the firing: watch, then tap the part (and what it did)
    function P.fire()
        local pending
        return function()
            local st = Ob._st
            if st.screen ~= "fire" then return true end
            if pending then
                local s = pending
                pending = nil
                return false, tapUI("ob:what:" .. s)
            end
            if o.undo_done and o.undo_ok == nil then
                o.undo_ok = #st.answers == 2 and st.cur.relay == o.undo_last.relay and st.cur.face == o.undo_last.face
            end
            if st.firing then return false end
            local pid, slot = obs.answer(st.phase)
            if o.again and not o.again_key and pid ~= "NOTHING" then
                o.again_key = st.cur.relay .. ":" .. st.cur.face
                o.again_before = st.fires[o.again_key]
                return false, tapUI("ob:again")
            end
            if o.again_key and o.again_after == nil then o.again_after = st.fires[o.again_key] end
            if o.undo and not o.undo_done and #st.answers == 3 then
                o.undo_done, o.undo_last = true, st.answers[3]
                return false, tapUI("ob:back")
            end
            o.answers = (o.answers or 0) + 1
            if pid == "NOTHING" then o.nothing = (o.nothing or 0) + 1 end
            pending = slot
            return false, tapUI("ob:part:" .. pid)
        end
    end
    -- buttons: press the true face; the ground sensor reads by itself
    function P.press()
        local held
        local function release() if held then held.r.inp[held.f] = 0 held = nil end end
        return function()
            local st = Ob._st
            if st.screen ~= "press" then release() return true end
            local it = st.pitems[st.pi]
            if held and held.id ~= it.id then release() return false end
            if st.press.found then
                o.pressed = (o.pressed or "") .. it.key .. "=" .. st.press.found .. " "
                release()
                return false, tapUI("ob:next")
            end
            if not it.auto and not held then
                local r = R(truth.peripherals[it.role])
                held = { r = r, f = truth.input_map[it.role][it.key], id = it.id }
                r.inp[held.f] = 15
            end
            return false
        end
    end
    return P
end

-- the faces a written slot ended up with, against the truth
local function sameWiring(ship, truth)
    local bad = {}
    for _, p in ipairs(PROPS4) do
        for _, k in ipairs({ "tilt_fwd", "tilt_bwd", "speed" }) do
            if ship.output_map[p][k] ~= truth.output_map[p][k] then bad[#bad + 1] = p .. "." .. k end
        end
    end
    local a, b = ship.output_map.REAR, truth.output_map.REAR
    local set = { [a.fw or "?"] = true, [a.bw or "?"] = true }
    if not (set[b.fw] and set[b.bw]) then bad[#bad + 1] = "REAR.fw/bw" end -- both speed links: either way round
    if a.rev ~= b.rev then bad[#bad + 1] = "REAR.rev" end
    if ship.gear_output.side ~= truth.gear_output.side then bad[#bad + 1] = "gear" end
    if ship.engine.clutch_side ~= truth.engine.clutch_side then bad[#bad + 1] = "clutch" end
    if ship.engine.start_side ~= truth.engine.start_side then bad[#bad + 1] = "starter" end
    if ship.proximity.side ~= truth.proximity.side then bad[#bad + 1] = "proximity" end
    for _, role in ipairs({ "engine_relay", "aux_relay" }) do
        for k, f in pairs(truth.input_map[role]) do
            if ship.input_map[role][k] ~= f then bad[#bad + 1] = role .. "." .. k end
        end
    end
    return #bad == 0, table.concat(bad, " ")
end

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepCopy(v) end
    return o
end

local function tapper(UIo, monName)
    return function(action)
        local u = UIo._last or {}
        for _, h in ipairs(u.tour and u.tour.hits or u.hits or {}) do -- the tour's own buttons while it is up
            if h.action == action then
                local ev = touchCell(h.x + 5, h.y + 5)
                ev[2] = monName or ev[2]
                return ev
            end
        end
        states.ob_missing = (states.ob_missing or "") .. action .. " "
    end
end

fresh()
do
    local UIo = hooked()
    local Ob = require("onboard")
    local tapUI = tapper(UIo)
    local function tap(action) return once(function() return tapUI(action) end) end
    local function pick(name)
        return once(function()
            local st = Ob._st
            for i, c in ipairs(st.cands or {}) do
                if c.name == name then
                    if i > (st.scroll or 0) + 6 or i <= (st.scroll or 0) then st.scroll = math.max(0, i - 6) end
                    return tapUI("ob:row:" .. (i - st.scroll - 1))
                end
            end
            states.ob_missing = (states.ob_missing or "") .. name .. " "
        end)
    end
    local function selName()
        local st = Ob._st
        local c = st.sel and st.cands[st.sel]
        return c and c.name
    end
    -- the simulator's relays ARE the ship: the clutch couples the props
    local R = function(n) return sim:relay(n) end
    local obs = observer(Ob, shipModel(cfg, R))
    for _, n in ipairs(NET) do if n ~= cfg.peripherals.main_monitor then obs.watch(sim:relay(n)) end end
    local ec = cfg.engine
    local rawOut = sim.readOutputs
    sim.readOutputs = function(s)
        local o = rawOut(s)
        if (sim:relay(cfg.peripherals[ec.relay_key]).out[ec.clutch_side] or 0) <= 0 then
            for _, p in ipairs(PROPS4) do o[p] = 0 end
            o.rear = 0
        end
        return o
    end
    local o = { again = true }
    local P = players(Ob, cfg, R, tapUI, obs, o)
    local saved_reboot = os.reboot
    os.reboot = function() states.ob_rebooted = true end
    mon.errors = {}
    timers, script, si = {}, {}, 1
    t0 = sim.t
    local y0 = sim.pos.y
    local drive = Seq({
        tap("ob:setup"),
        P.screen("engines"),
        once(function() states.ob_engines = Ob._st.screen return tapUI("ob:engines") end),
        P.screen("role"),
        once(function()
            states.role1 = Ob._st.role and Ob._st.role.key
            return tapUI("ob:test") -- DETECT
        end),
        sleepFor(0.3),
        once(function() sim:press("W", true) end),
        sleepFor(0.8),
        once(function() sim:press("W", false) states.detected = selName() end),
        tap("ob:next"),
        pick(cfg.peripherals.input_1), -- already input_1's
        once(function() states.used_sel = selName() end),
        tap("ob:back"),
        once(function() states.back_role, states.back_sel = Ob._st.role.key, selName() end),
        tap("ob:next"),
        tap("ob:down"),
        sleepFor(0.3),
        once(function() states.scrolled = Ob._st.scroll end),
        pick(cfg.peripherals.input_2),
        tap("ob:next"),
        P.screen("fire"),
        once(function() states.fire_first = Ob._st.cur and Ob._st.cur.relay end),
        P.fire(),
        once(function()
            local st = Ob._st
            states.review, states.can_next = st.screen, st.can_next
            states.known_n, states.known_total = st.known_n, st.known_total
            states.unseen = ""
            for _, r in ipairs(st.rows or {}) do
                for _, f in ipairs(r.faces) do if not f.seen then states.unseen = states.unseen .. r.label .. "." .. f.lbl .. " " end end
            end
            states.before_finish = files["config/assignments_ship.lua"]
            states.relays_rest = sim:relay(cfg.peripherals[ec.relay_key]).out[ec.clutch_side]
            return tapUI("ob:next")
        end),
        P.press(),
        P.screen("guide"),
        once(function() states.guide = Ob._st.screen return tapUI("ob:gnext") end),
        tap("ob:gnext"), tap("ob:gnext"),
        once(function() states.guide_last = Ob._st.gi return tapUI("ob:gnext") end), -- LET'S FLY
        -- the OS proper: engines off, so the tour comes up at once
        sleepFor(1.5),
        once(function()
            local u = UIo._last
            states.tour_i = u.tour and u.tour.i
            states.tour_hits = u.tour and #u.tour.hits
            return touchCell(Dref.W / 2, 128) -- START, under the tour
        end),
        sleepFor(1.5),
        once(function()
            states.tour_start_blocked = (sim:relay(cfg.peripherals[ec.relay_key]).out[ec.start_side] or 0) == 0
            return tapUI("tour:next")
        end),
        sleepFor(0.5),
        once(function() states.tour_i2 = UIo._last.tour and UIo._last.tour.i return tapUI("tour:next") end),
        sleepFor(0.5),
        once(function() states.tour_i3 = UIo._last.tour and UIo._last.tour.i return tapUI("tour:skip") end),
        sleepFor(0.5),
        once(function()
            states.tour_after_skip = UIo._last.tour
            states.tour_flag = files["v2/data/tour_done"]
            return touchCell(Dref.W / 2, 128) -- START, now for real
        end),
        sleepFor(1.5),
        once(function()
            states.started_after_tour = sim:relay(cfg.peripherals[ec.relay_key]).out[ec.start_side]
            return { "terminate" }
        end),
    })
    local hmax = 0
    for k = 1, 4000 do
        at(t0 + k * 0.25, function()
            if Ob._st and Ob._st.screen ~= "guide" and states.guide == nil then hmax = math.max(hmax, sim.pos.y - y0) end
            return drive()
        end)
    end
    at(t0 + 1000.5, function() states.ob_timeout = true return { "terminate" } end)
    local okS, resS = runMain()
    os.reboot = saved_reboot
    sim.readOutputs = rawOut
    print(string.format("setup firing: %d answers (%d NOTHING), longest full lift %.2f s, max lift once clutch known %d, rose %.2f m",
        o.answers or 0, o.nothing or 0, obs.max_full, obs.max_lift_known, hmax))
    check("setup: ran", okS, resS)
    check("setup: every button found", states.ob_missing == nil, states.ob_missing)
    check("setup: engines first", states.ob_engines == "engines", states.ob_engines)
    check("setup: then the first keyboard relay", states.role1 == "input_1", states.role1)
    check("setup: DETECT picks the relay that sees the key", states.detected == cfg.peripherals.input_1, states.detected)
    check("setup: a relay can't take two roles", states.used_sel == nil and saidIt("IS ALREADY"), states.used_sel)
    check("setup: BACK keeps the earlier pick", states.back_role == "input_1" and states.back_sel == cfg.peripherals.input_1,
        tostring(states.back_role) .. "/" .. tostring(states.back_sel))
    check("setup: list scrolls", states.scrolled == 1, states.scrolled)
    check("setup: firing never touches the keyboard relays",
        next(sim:relay(cfg.peripherals.input_1).out) == nil and next(sim:relay(cfg.peripherals.input_2).out) == nil)
    check("fire: every part and face found", states.review == "review" and states.can_next
        and states.known_n == states.known_total and states.known_total == 17,
        tostring(states.known_n) .. "/" .. tostring(states.known_total) .. " unseen " .. tostring(states.unseen))
    check("fire: FIRE AGAIN fires the same face again", o.again_before == 1 and o.again_after == 2,
        tostring(o.again_before) .. "->" .. tostring(o.again_after))
    check("fire: NOTHING answered for faces that move nothing", (o.nothing or 0) > 0, o.nothing)
    check("fire: clutch left out after the firing", (states.relays_rest or 0) == 0, states.relays_rest)
    check("safety: full lift only in blind pulses", obs.max_full <= Ob.PULSE_BLIND + 0.06, obs.max_full)
    check("safety: once the clutch is known, at most one slow prop", obs.max_lift_known <= 15 - Ob.SPIN, obs.max_lift_known)
    check("safety: the ship stayed on the ground", hmax < 1.5, string.format("rose %.2f", hmax))
    check("buttons: each found on its face", o.pressed and o.pressed:find("OFF=left", 1, true) and o.pressed:find("PROX=right", 1, true),
        o.pressed)
    check("setup: nothing written before the end", states.before_finish == nil and states.ob_rebooted == nil)
    local A = files["config/assignments_ship.lua"] and load(files["config/assignments_ship.lua"])()
    local okA = A ~= nil
    for key, name in pairs(cfg.peripherals) do
        if not A or A[key] ~= name then okA = false end
    end
    check("setup: assignments file has every role", okA, files["config/assignments_ship.lua"])
    check("setup: assignments tagged with the config version", A and A.config_version == "1.2", A and A.config_version)
    check("setup: new slot from the template", (files["config/ship.lua"] or ""):find("name = \"SHIP\"", 1, true) ~= nil)
    check("setup: comments kept", (files["config/ship.lua"] or ""):find("Slow-down link", 1, true) ~= nil)
    check("setup: slot remembered", files["v2/data/slot"] == "ship", files["v2/data/slot"])
    local Cf = require("config")
    local lc, lerr = Cf.load("v2")
    check("setup: Config.load accepts it", lc and lc.slot == "ship" and lc.ship.peripherals.output_FL == cfg.peripherals.output_FL, lerr)
    local same, diff = false, "no config"
    if lc then same, diff = sameWiring(lc.ship, cfg) end
    check("setup: faces seen = the template's (template-wired ship)", same, diff)
    check("setup: guide follows", states.guide == "guide" and states.guide_last == #Ob.GUIDE, tostring(states.guide))
    check("tour: comes up after setup", states.tour_i == 1, states.tour_i)
    check("tour: only NEXT and SKIP take taps", states.tour_hits == 2, states.tour_hits)
    check("tour: taps under it are blocked", states.tour_start_blocked == true)
    check("tour: NEXT advances", states.tour_i2 == 2 and states.tour_i3 == 3,
        tostring(states.tour_i2) .. "/" .. tostring(states.tour_i3))
    check("tour: SKIP ends it", states.tour_after_skip == nil)
    check("tour: SKIP remembers it", states.tour_flag ~= nil)
    check("tour: the screen works again after it", states.started_after_tour == 15, states.started_after_tour)
    check("setup: no draw errors", #mon.errors == 0, mon.errors[1])
    check("setup: no screen errors (setup, tour)", not saidIt("[UI]") and not saidIt("[ERROR]") and not saidIt("[ACTION]"))
end

-- 2b. A ship wired NOTHING like the template: other relay names, every
-- prop / rear / gear / clutch / button on other faces, the gear already
-- down, a spare relay. The setup must learn all of it from the answers
-- (with an undo on the way) and write a config that loads and matches.
fresh()
for p in pairs(files) do
    if p:match("^config/") and p ~= "config/atlas.lua" and p ~= "config/wp_atlas.lua" then files[p] = nil end
end
files["v2/data/slot"], files["v2/data/tour_done"] = nil, nil
do
    local truth = deepCopy(cfg)
    truth.peripherals = { input_1 = "redstone_relay_4", input_2 = "redstone_relay_9", aux_relay = "redstone_relay_1",
        engine_relay = "redstone_relay_7", output_FL = "redstone_relay_2", output_FR = "redstone_relay_8",
        output_RL = "redstone_relay_0", output_RR = "redstone_relay_5", output_REAR = "redstone_relay_3",
        main_monitor = "monitor_3" }
    local om = truth.output_map
    om.FL.tilt_fwd, om.FL.tilt_bwd, om.FL.speed = "left", "right", "top"
    om.FR.tilt_fwd, om.FR.tilt_bwd, om.FR.speed = "back", "front", "bottom"
    om.RL.tilt_fwd, om.RL.tilt_bwd, om.RL.speed = "top", "bottom", "front"
    om.RR.tilt_fwd, om.RR.tilt_bwd, om.RR.speed = "right", "left", "back"
    om.REAR.fw, om.REAR.bw, om.REAR.rev = "left", "right", "bottom"
    truth.gear_output.side = "back"
    truth.engine.clutch_side, truth.engine.start_side = "front", "back"
    truth.input_map.engine_relay = { UP = "top", DOWN = "bottom", OFF = "back" }
    truth.input_map.aux_relay = { SHIFT = "top", PROX = "left" }
    truth.proximity.side = "left"
    local relays = {}
    local function R(n)
        if not relays[n] then
            local r = { out = {}, inp = {} }
            function r.setAnalogOutput(side, v) r.out[side] = v end
            function r.getAnalogOutput(side) return r.out[side] or 0 end
            function r.getAnalogInput(side) return r.inp[side] or 0 end
            relays[n] = r
        end
        return relays[n]
    end
    local net = { "redstone_relay_6", "monitor_3" }
    for k, n in pairs(truth.peripherals) do if k ~= "main_monitor" then net[#net + 1] = n end end
    peripheral.getNames = function() return net end
    peripheral.getType = function(n) return n == "monitor_3" and "monitor" or "redstone_relay" end
    peripheral.wrap = function(n) if n == "monitor_3" then return mon end return R(n) end
    R(truth.peripherals.aux_relay).out.back = 15 -- the gear is down already
    R(truth.peripherals.aux_relay).inp.left = 15 -- landed: the ground sensor reads 15

    local UIo = hooked()
    local Ob = require("onboard")
    local tapUI = tapper(UIo, "monitor_3")
    local obs = observer(Ob, shipModel(truth, R))
    for _, n in ipairs(net) do if n ~= "monitor_3" then obs.watch(R(n)) end end
    local o = { undo = true }
    local P = players(Ob, truth, R, tapUI, obs, o)
    states.ob_missing = nil
    mon.errors = {}
    timers, script, si = {}, {}, 1
    t0 = sim.t
    local drive = Seq({
        once(function() return tapUI("ob:setup") end),
        P.screen("engines"),
        once(function() return tapUI("ob:engines") end),
        P.screen("role"),
        P.keys(),
        P.screen("fire"),
        P.fire(),
        once(function()
            local st = Ob._st
            states.w_review, states.w_can = st.screen, st.can_next
            states.w_known = (st.known_n or 0) .. "/" .. (st.known_total or 0)
            return tapUI("ob:next")
        end),
        P.press(),
        P.screen("guide"),
        once(function() states.w_guide = true return { "terminate" } end),
    })
    for k = 1, 4000 do at(t0 + k * 0.25, drive) end
    at(t0 + 1000.5, function() states.w_timeout = true return { "terminate" } end)
    local okW, resW = runMain()
    print(string.format("rewired firing: %d answers (%d NOTHING), longest full lift %.2f s, max lift once clutch known %d",
        o.answers or 0, o.nothing or 0, obs.max_full, obs.max_lift_known))
    check("rewired: ran", okW, resW)
    check("rewired: every button found", states.ob_missing == nil, states.ob_missing)
    check("rewired: every part and face found", states.w_review == "review" and states.w_can and states.w_known == "17/17",
        tostring(states.w_known))
    check("rewired: BACK undoes the last answer and fires that face again", o.undo_ok == true, tostring(o.undo_ok))
    check("rewired: NOTHING answered for the spare relay and unused faces", (o.nothing or 0) >= 6, o.nothing)
    check("rewired: safety, full lift only in blind pulses", obs.max_full <= Ob.PULSE_BLIND + 0.06, obs.max_full)
    check("rewired: safety, once the clutch is known at most one slow prop", obs.max_lift_known <= 15 - Ob.SPIN,
        obs.max_lift_known)
    check("rewired: reached the guide", states.w_guide == true)
    local A = files["config/assignments_ship.lua"] and load(files["config/assignments_ship.lua"])()
    local okA = A ~= nil
    for key, name in pairs(truth.peripherals) do if not A or A[key] ~= name then okA = false end end
    check("rewired: assignments name the true relays", okA, files["config/assignments_ship.lua"])
    local Cf = require("config")
    local lc, lerr = Cf.load("v2")
    check("rewired: written config loads", lc ~= nil and lc.slot == "ship", lerr)
    local same, diff = false, "no config"
    if lc then same, diff = sameWiring(lc.ship, truth) end
    check("rewired: config has the faces the ship showed", same, diff)
    check("rewired: everything put back (clutch out, gear as it was)",
        (R(truth.peripherals.engine_relay).out.front or 0) == 0 and R(truth.peripherals.aux_relay).out.back == 15)
    check("rewired: no draw errors", #mon.errors == 0, mon.errors[1])
    check("rewired: no screen errors", not saidIt("[UI]") and not saidIt("ERROR"))
end
peripheral.wrap = function(name)
    if name == cfg.peripherals.main_monitor then return mon end
    return sim:relay(name)
end
peripheral.getNames = function() return NET end
peripheral.getType = function(n)
    if n == cfg.peripherals.main_monitor then return "monitor" end
    return "redstone_relay"
end

-- 3. IMPORT FROM DISK: two taps, ShipDisk.load, restart; no setup, no guide
fresh()
for p in pairs(files) do
    if p:match("^config/") and p ~= "config/atlas.lua" and p ~= "config/wp_atlas.lua" then files[p] = nil end
end
files["v2/data/slot"], files["v2/data/tour_done"] = nil, nil
do
    local disk = { loads = 0 }
    package.loaded.shipdisk = {
        peek = function() return { ship = "Cargo", slot = "cargo", files = {} } end,
        load = function()
            disk.loads = disk.loads + 1
            files["config/cargo.lua"] = files["config/atlas.lua"]
            files["config/assignments_cargo.lua"] = WIRED
            files["v2/data/slot"] = "cargo"
            return { ship = "Cargo", slot = "cargo" }
        end,
    }
    local UIo = hooked()
    local Ob = require("onboard")
    local function tap(action)
        return function()
            for _, h in ipairs(UIo._last and UIo._last.hits or {}) do
                if h.action == action then return touchCell(h.x + 5, h.y + 5) end
            end
            states.imp_missing = action
        end
    end
    local saved_reboot = os.reboot
    os.reboot = function() disk.rebooted = sim.t end
    mon.errors = {}
    timers, script, si = {}, {}, 1
    t0 = sim.t
    at(t0 + 0.5, tap("ob:import"))
    at(t0 + 1, function() disk.after_one = disk.loads end)
    at(t0 + 1.5, tap("ob:import"))
    at(t0 + 2, function() disk.screen = Ob._st.screen end)
    at(t0 + 10, function() return { "terminate" } end)
    local okI, resI = runMain()
    os.reboot = saved_reboot
    check("import: ran", okI, resI)
    check("import: buttons found", states.imp_missing == nil, states.imp_missing)
    check("import: first tap only asks", disk.after_one == 0 and saidIt("TAP IMPORT AGAIN TO LOAD CARGO"))
    check("import: second tap loads the disk", disk.loads == 1, disk.loads)
    check("import: restarts on it", disk.rebooted ~= nil and resI == "reboot", tostring(resI))
    check("import: no setup or guide", disk.screen == "busy" and files["config/ship.lua"] == nil, disk.screen)
    check("import: no draw errors", #mon.errors == 0, mon.errors[1])
end
package.loaded.shipdisk = nil
peripheral.getNames, peripheral.getType = saved_names, saved_type


_G.loadfile, _G.dofile, _G.fs = saved.loadfile, saved.dofile, saved.fs
print(string.format("v2_main_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_main_test FAILED", 0) end
