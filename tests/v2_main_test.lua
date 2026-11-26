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

-- 2. SET UP THIS SHIP: every role picked from the network (DETECT, TEST,
-- BACK and a used relay on the way), the guide, then the OS with the tour
fresh()
do
    local UIo = hooked()
    local Ob = require("onboard")
    local function tapUI(action)
        local u = UIo._last or {}
        for _, h in ipairs(u.tour and u.tour.hits or u.hits or {}) do -- the tour's own buttons while it is up
            if h.action == action then return touchCell(h.x + 5, h.y + 5) end
        end
        states.ob_missing = (states.ob_missing or "") .. action .. " "
    end
    local function tap(action) return function() return tapUI(action) end end
    local function pick(name)
        return function()
            local st = Ob._st
            for i, c in ipairs(st.cands or {}) do
                if c.name == name then
                    if i > (st.scroll or 0) + 6 or i <= (st.scroll or 0) then st.scroll = math.max(0, i - 6) end
                    return tapUI("ob:row:" .. (i - st.scroll - 1))
                end
            end
            states.ob_missing = (states.ob_missing or "") .. name .. " "
        end
    end
    local function selName()
        local st = Ob._st
        local c = st.sel and st.cands[st.sel]
        return c and c.name
    end
    local saved_reboot = os.reboot
    os.reboot = function() states.ob_rebooted = true end
    mon.errors = {}
    timers, script, si = {}, {}, 1
    t0 = sim.t
    local t = t0 + 0.5
    local function nxt(dt) t = t + (dt or 0.5) return t end
    at(t, tap("ob:setup"))
    at(nxt(), function()
        states.role1 = Ob._st.role and Ob._st.role.key
        sim:press("W", true)
        return tapUI("ob:test") -- DETECT
    end)
    at(nxt(0.8), function() sim:press("W", false) states.detected = selName() end)
    at(nxt(), tap("ob:next"))
    at(nxt(), pick(cfg.peripherals.input_1)) -- already input_1's
    at(nxt(), function() states.used_sel = selName() end)
    at(nxt(), tap("ob:back"))
    at(nxt(), function() states.back_role, states.back_sel = Ob._st.role.key, selName() end)
    at(nxt(), tap("ob:next"))
    local order = { "input_2", "aux_relay", "engine_relay", "output_FL", "output_FR", "output_RL", "output_RR", "output_REAR" }
    for _, key in ipairs(order) do
        at(nxt(), function() states.roles = (states.roles or "") .. Ob._st.role.key .. " " end)
        if key == "output_REAR" then
            at(nxt(), tap("ob:down"))
            at(nxt(0.3), function() states.scrolled = Ob._st.scroll end)
        end
        at(nxt(), pick(cfg.peripherals[key]))
        if key == "output_FL" then
            local face = cfg.output_map.FL.tilt_fwd
            at(nxt(), tap("ob:test"))
            at(nxt(0.5), function() states.test_on = sim:relay(cfg.peripherals.output_FL).out[face] end)
            at(nxt(2.5), function() states.test_off = sim:relay(cfg.peripherals.output_FL).out[face] end)
        end
        at(nxt(), tap("ob:next"))
    end
    at(nxt(), function()
        states.last_role, states.mon_sel = Ob._st.role.key, selName()
        states.before_finish = files["config/assignments_ship.lua"]
        return tapUI("ob:next") -- FINISH
    end)
    at(nxt(), function() states.guide = Ob._st.screen end)
    for _ = 1, 3 do at(nxt(), tap("ob:gnext")) end
    at(nxt(), function() states.guide_last = Ob._st.gi return tapUI("ob:gnext") end) -- LET'S FLY
    -- the OS proper: engines off, so the tour comes up at once
    at(nxt(1.5), function()
        local u = UIo._last
        states.tour_i = u.tour and u.tour.i
        states.tour_hits = u.tour and #u.tour.hits
        return touchCell(Dref.W / 2, 128) -- START, under the tour
    end)
    at(nxt(1.5), function()
        local e = cfg.engine
        states.tour_start_blocked = (sim:relay(cfg.peripherals[e.relay_key]).out[e.start_side] or 0) == 0
        return tapUI("tour:next")
    end)
    at(nxt(), function() states.tour_i2 = UIo._last.tour and UIo._last.tour.i return tapUI("tour:next") end)
    at(nxt(), function() states.tour_i3 = UIo._last.tour and UIo._last.tour.i return tapUI("tour:skip") end)
    at(nxt(), function()
        states.tour_after_skip = UIo._last.tour
        states.tour_flag = files["v2/data/tour_done"]
        return touchCell(Dref.W / 2, 128) -- START, now for real
    end)
    at(nxt(1.5), function()
        local e = cfg.engine
        states.started_after_tour = sim:relay(cfg.peripherals[e.relay_key]).out[e.start_side]
        return { "terminate" }
    end)
    local okS, resS = runMain()
    os.reboot = saved_reboot
    check("setup: ran", okS, resS)
    check("setup: every button found", states.ob_missing == nil, states.ob_missing)
    check("setup: first role from the template", states.role1 == "input_1", states.role1)
    check("setup: DETECT picks the relay that sees the key", states.detected == cfg.peripherals.input_1, states.detected)
    check("setup: a relay can't take two roles", states.used_sel == nil and saidIt("IS ALREADY"), states.used_sel)
    check("setup: BACK keeps the earlier pick", states.back_role == "input_1" and states.back_sel == cfg.peripherals.input_1,
        tostring(states.back_role) .. "/" .. tostring(states.back_sel))
    check("setup: roles in wiring order", states.roles == table.concat(order, " ") .. " ", states.roles)
    check("setup: list scrolls", states.scrolled == 1, states.scrolled)
    check("setup: TEST flips the face", states.test_on == 15, states.test_on)
    check("setup: TEST puts it back", (states.test_off or 0) == 0, states.test_off)
    check("setup: cockpit monitor preselected", states.last_role == "main_monitor" and states.mon_sel == cfg.peripherals.main_monitor,
        tostring(states.last_role) .. "/" .. tostring(states.mon_sel))
    check("setup: nothing written before FINISH", states.before_finish == nil and states.ob_rebooted == nil)
    local A = files["config/assignments_ship.lua"] and load(files["config/assignments_ship.lua"])()
    local okA = A ~= nil
    for key, name in pairs(cfg.peripherals) do
        if not A or A[key] ~= name then okA = false end
    end
    check("setup: assignments file has every role", okA, files["config/assignments_ship.lua"])
    check("setup: assignments tagged with the config version", A and A.config_version == "1.2", A and A.config_version)
    check("setup: new slot from the template", (files["config/ship.lua"] or ""):find("name = \"SHIP\"", 1, true) ~= nil)
    check("setup: slot remembered", files["v2/data/slot"] == "ship", files["v2/data/slot"])
    local Cf = require("config")
    local lc, lerr = Cf.load("v2")
    check("setup: Config.load accepts it", lc and lc.slot == "ship" and lc.ship.peripherals.output_FL == cfg.peripherals.output_FL, lerr)
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
