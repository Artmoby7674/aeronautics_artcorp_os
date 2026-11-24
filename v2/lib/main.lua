-- v2 main loop: power/boot sequence, 20 Hz control, UI, touch, network.
local U = require("util")
local Config = require("config")
local HW = require("hw")
local Flight = require("flight")
local AP = require("ap")
local Nav = require("nav")
local Link = require("link")
local Rec = require("rec")
local D = require("draw")
local UI = require("ui")
local V = require("version")

local Main = {}

local ROOT = "v2"
local DT = 0.05

local app = {
    power = "off", boot_t = 0, msg = nil, msg_t = 0, msg_color = nil,
    confirm = nil, confirm_t = 0, loop = { ms = nil, worst = 0 },
    errors = {}, missing = {}, last_ap = nil, keys = {}, prev = {},
}

local function say(text, color)
    app.msg, app.msg_t, app.msg_color = text, os.clock(), color
    print("[" .. string.format("%6.1f", os.clock()) .. "] " .. text)
end

-- ------------------------------------------------------------ air/ground state
-- Written whenever it changes, so a restart knows whether the OS was flying
-- (take control at once) or the ship was on the ground (start screen).
local STATE_PATH = ROOT .. "/data/state"

local function readState()
    local t = U.loadTable(STATE_PATH)
    return t or { where = "ground", gear = true }
end

local function writeState(where, gear)
    if app.state_where == where and app.state_gear == gear then return end
    app.state_where, app.state_gear = where, gear
    U.saveTable(STATE_PATH, { where = where, gear = gear })
end

-- ------------------------------------------------------------ learned values

local LEARN_PATH = ROOT .. "/data/learned.lua"
local LEARN_KEYS = { "hover", "pi_", "ri", "yi", "rear_pk", "rear_yk", "yaw_brake",
    "roll_sign", "pitch_sign", "roll_known", "pitch_known" }

-- Bumped when what the stabiliser learns changes meaning. Values saved by
-- an older format keep only what is plain physics (hover throttle, yaw
-- braking); trims, feedforwards and the direction check start over.
-- 2 (v3.0): trims learned under the v2.9 roll swing were wound up to the
-- limit, its direction check measured mid-swing, and the rear feedforwards
-- now follow the thrust direction (reverse = negative).
-- 3 (v2.22): yaw direction flipped: the yaw integrators were learned
-- backwards.
local LEARN_FMT = 3
local LEARN_KEEP = { hover = true, yaw_brake = true }

local function loadLearned(ctl)
    local t = U.loadTable(LEARN_PATH)
    if not t then return end
    local old = t.fmt ~= LEARN_FMT
    if old then U.log("learned values from an older version: kept hover and yaw braking, the rest starts over") end
    for _, k in ipairs(LEARN_KEYS) do
        if type(t[k]) == "number" and (not old or LEARN_KEEP[k]) then ctl[k] = t[k] end
    end
end

local function saveLearned(ctl)
    local t = { fmt = LEARN_FMT }
    for _, k in ipairs(LEARN_KEYS) do t[k] = ctl[k] end
    U.saveTable(LEARN_PATH, t)
end

-- ------------------------------------------------------------ power

local function engineTimes()
    local e = app.cfg.ship.engine or {}
    local start = HW.feature("engine_auto_start") and (e.start_seconds or 3) or 0
    local clutch = start + (e.clutch_delay or 1)
    return start, clutch, math.max(e.boot_seconds or 5, clutch + 0.5)
end

local function beginBoot()
    if app.power ~= "off" then return end
    app.power, app.boot_t = "booting", 0
    say("STARTING ENGINES")
    U.log("engine start")
end

local function powerOff(why)
    local fl = app.fl
    if fl.ap then fl.ap:cancel("POWER OFF") fl.ap = nil end
    HW.cutAll()
    HW.setClutch(false)
    HW.setStarter(false)
    app.power = "off"
    fl.phase = "parked"
    writeState("ground", fl.gear_down)
    saveLearned(fl.ctl)
    app.ui:invalidate()
    say("POWER OFF" .. (why and (" (" .. why .. ")") or ""))
    U.log("power off: %s", tostring(why))
end

local function bootTick(dt)
    app.boot_t = app.boot_t + dt
    local start, clutch, total = engineTimes()
    HW.cutAll()
    HW.setStarter(app.boot_t < start)
    HW.setClutch(app.boot_t >= clutch)
    if app.boot_t < start then app.boot_step = "STARTER"
    elseif app.boot_t < clutch then app.boot_step = "SPINNING UP"
    else app.boot_step = "CLUTCH IN" end
    app.boot_frac = app.boot_t / total
    if app.boot_t >= total then
        HW.setStarter(false)
        app.power = "on"
        app.fl:boot("ground")
        app.ui:invalidate()
        say("ENGINES RUNNING: TAKE OFF WHEN READY", D.C.good)
        U.log("engines running, parked")
    end
end

-- OFF button / LAND+OFF: airborne ships land first; a second press within
-- 3 s means "off now" (the ship will fall).
local function offRequest()
    local fl = app.fl
    if app.power ~= "on" then return end
    if fl.phase == "parked" or fl.phase == "estop" then return powerOff("button") end
    if app.off_armed and os.clock() - app.off_armed < 3 then
        app.off_armed = nil
        return powerOff("forced in flight")
    end
    app.off_armed = os.clock()
    fl:beginLanding({ shutdown = true })
    say("LANDING, THEN OFF (PRESS AGAIN = OFF NOW)", D.C.warn)
end

-- ------------------------------------------------------------ actions

local ZOOMS = { false, 100, 500, 2500, 10000 }

local function confirmed(id)
    if app.confirm == id and os.clock() - app.confirm_t < 4 then
        app.confirm = nil
        return true
    end
    app.confirm, app.confirm_t = id, os.clock()
    return false
end

local function saveHere(name)
    local s = app.fl.est.s
    if not s.valid then return say("NO TELEMETRY", D.C.bad) end
    local ok, w = Nav.add(name, s.x, s.z, s.heading)
    if ok then
        say("SAVED " .. w.name, D.C.good)
        app.ui.sel = #Nav.list
    else
        say("SAVE FAILED: " .. tostring(w), D.C.bad)
    end
end

local function act(a)
    if not a then return end
    local fl, ui = app.fl, app.ui
    if a == "boot" then return beginBoot() end
    if app.power ~= "on" then return end
    local tab = a:match("^tab:(.+)")
    if tab then return ui:setTab(tab) end

    local row = a:match("^wp:row:(%d+)")
    if row then
        local i = ui.scroll + tonumber(row) + 1
        if Nav.list[i] then ui.sel = i end
        return
    end
    if a == "wp:up" then ui.scroll = math.max(0, ui.scroll - 1) return end
    if a == "wp:down" then ui.scroll = math.min(math.max(#Nav.list - 6, 0), ui.scroll + 1) return end
    if a == "map:zoom" then
        local i = 1
        for k, z in ipairs(ZOOMS) do if (ui.zoom or false) == z then i = k end end
        ui.zoom = ZOOMS[i % #ZOOMS + 1] or nil
        return
    end
    if a == "wp:fly" then
        local w = Nav.list[ui.sel]
        if not w then return end
        if fl.phase == "estop" or fl.phase == "unflip" then return say("NOT NOW: " .. fl.phase:upper(), D.C.bad) end
        if fl.phase == "landing" then fl:cancelLanding("") end
        fl.ap = AP.new(fl, w)
        ui:setTab("auto")
        return say("A/P TO " .. w.name, D.C.ap)
    end
    if a == "wp:del" then
        local w = Nav.list[ui.sel]
        if not w then return end
        if not confirmed("wp:del") then return say("TAP DELETE AGAIN FOR " .. w.name, D.C.warn) end
        if Nav.remove(ui.sel) then say("DELETED " .. w.name) else say("DELETE FAILED", D.C.bad) end
        return
    end
    if a == "wp:save" then
        if Link.online() then
            local ok, why = Link.ask({ { "NAME", "name" } }, function(v, err)
                if v then saveHere(v[1]) else say("KEYBOARD: " .. tostring(err), D.C.warn) end
            end)
            if not ok then saveHere("WP" .. (#Nav.list + 1)) end
        else
            saveHere("WP" .. (#Nav.list + 1))
        end
        return
    end
    if a == "wp:new" then
        if Link.pending then Link.cancel("CANCELLED") return say("KEYBOARD CANCELLED") end
        local ok, why = Link.ask({ { "X", "number" }, { "Z", "number" }, { "HEADING", "number" }, { "NAME", "name" } },
            function(v, err)
                if not v then return say("KEYBOARD: " .. tostring(err), D.C.warn) end
                local okw, w = Nav.add(v[4], tonumber(v[1]), tonumber(v[2]), tonumber(v[3]))
                say(okw and ("ADDED " .. w.name) or ("ADD FAILED: " .. tostring(w)), okw and D.C.good or D.C.bad)
            end)
        if ok then say("TYPE ON THE KEYBOARD COMPUTER") else say(why, D.C.bad) end
        return
    end
    if a == "ap:cancel" then
        if fl.ap then fl.ap:cancel("CANCELLED") fl.ap = nil fl:holdHere() say("A/P CANCELLED") end
        if fl.phase == "landing" and fl.land and fl.land.from_ap then fl:cancelLanding("A/P CANCELLED") end
        return
    end
    if a == "ctl:land" then
        if fl.phase == "parked" then fl:takeoff() return end
        if fl.phase == "landing" then return fl:cancelLanding() end
        if fl.ap then fl.ap:cancel("AUTO-LAND") fl.ap = nil end
        local ok, why = fl:beginLanding({})
        if not ok then say(why, D.C.warn) end
        return
    end
    if a == "ctl:gear" then
        if (fl.prox or 0) > 0 and fl.gear_down then return say("GROUND CLOSE: GEAR STAYS DOWN", D.C.warn) end
        fl:setGear(not fl.gear_down)
        return say("GEAR " .. (fl.gear_down and "DOWN" or "UP"))
    end
    if a == "ctl:mode" then local ok, m = fl:toggleMode() return say(ok and ("MODE " .. m) or m) end
    if a == "ctl:estop" then
        fl:setEstop(fl.phase ~= "estop")
        return
    end
    if a == "ctl:hold" then
        fl.t.hover.brake = not fl.t.hover.brake
        return say("AUTO BRAKE " .. (fl.t.hover.brake and "ON" or "OFF"))
    end
    if a == "ctl:rec" then return say(Rec.toggle(os.clock()) and "RECORDING" or "RECORDING STOPPED") end
    if a == "ctl:print" then
        local ok, why = Rec.print(app.cfg.name)
        return say(ok and "PRINTED" or ("PRINT: " .. tostring(why)), ok and D.C.good or D.C.warn)
    end
    if a == "ctl:landoff" then return offRequest() end
    if a == "ctl:power" then
        if fl.phase ~= "parked" and fl.phase ~= "estop" then
            if not confirmed("ctl:power") then return say("AIRBORNE: TAP AGAIN TO CUT POWER", D.C.bad) end
        end
        return powerOff("button")
    end
    if a == "ship:reset" then
        local c = fl.ctl
        c.hover = fl.t.ship.hover_throttle
        c.pi_, c.ri, c.yi, c.rear_pk, c.rear_yk, c.yaw_brake = 0, 0, 0, 0, 0, nil
        c.roll_sign, c.pitch_sign, c.roll_known, c.pitch_known = 1, 1, 0, 0 -- re-checked at next take-off
        saveLearned(c)
        return say("LEARNED VALUES RESET")
    end
end

-- ------------------------------------------------------------ alerts

local function alerts()
    local fl, s, out, bad = app.fl, app.fl.est.s, {}, false
    local function add(level, text, hint)
        out[#out + 1] = { level = level, text = text, hint = hint }
        if level == "bad" then bad = true end
    end
    if fl.phase == "estop" then add("bad", "E-STOP: ALL LIFT CUT", "SPACE RESETS") end
    if fl.phase == "unflip" then add("bad", "UPSIDE DOWN: AUTO-UNFLIP", "HANDS OFF") end
    if not s.valid then add("bad", "NO SHIP TELEMETRY (CC:SABLE)", s.err and s.err:sub(1, 20)) end
    if #app.missing > 0 then add("bad", "MISSING: " .. table.concat(app.missing, " "):upper()) end
    if s.valid and (fl.prox or 0) > 0 and s.vs < -4 and fl.phase ~= "parked" then add("bad", "FAST DESCENT NEAR GROUND") end
    if fl.phase ~= "parked" and fl.ctl.margin < 1.5 then add("warn", "LOW LIFT MARGIN", string.format("%.1f/15", fl.ctl.margin)) end
    if (fl.rear_cap or 15) < 12 then add("warn", "REAR LIMITED: PITCH AUTHORITY", string.format("CAP %.0f", fl.rear_cap)) end
    if app.loop.ms and app.loop.ms > 65 then add("warn", "CONTROL LOOP SLOW", string.format("%.0f MS", app.loop.ms)) end
    if (app.disk or 1e9) < 50000 then add("warn", "DISK NEARLY FULL", string.format("%.0f KB", app.disk / 1024)) end
    if #app.errors > 0 then add("warn", "CODE ERROR: " .. app.errors[#app.errors]:sub(1, 34), "SHIP COMPUTER LOG") end
    if not Link.online() then add("info", "KEYBOARD COMPUTER OFFLINE", "OPTIONAL") end
    return out, bad
end

-- ------------------------------------------------------------ frame

local function model()
    local fl = app.fl
    if app.msg and os.clock() - app.msg_t > 6 then app.msg = nil end
    if app.confirm and os.clock() - app.confirm_t > 4 then app.confirm = nil end
    local list, bad = alerts()
    local ap
    if fl.ap then
        ap = fl.ap:status()
        ap.x, ap.z = fl.ap.wp.x, fl.ap.wp.z
    end
    return {
        power = app.power, boot_frac = app.boot_frac, boot_step = app.boot_step,
        name = app.cfg.name, fl = fl, s = fl.est.s, ap = ap,
        msg = app.msg, msg_color = app.msg_color, alerts = list, alerts_bad = bad,
        wps = Nav.list, kbd = Link.online(), kbd_prompt = Link.prompt(),
        rec = Rec.on, rec_t = Rec.duration(), rec_n = #Rec.samples,
        loop = app.loop, disk = app.disk, missing = app.missing,
        confirm = app.confirm, clutch = app.power == "on" and HW.feature("clutch"),
        last_ap = app.last_ap,
    }
end

-- ------------------------------------------------------------ loop

local function edge(k) return (app.keys[k] or 0) > 0 and not ((app.prev[k] or 0) > 0) end

-- Black box columns (v2/data/bb.txt, one line per control tick in flight).
-- t: clock s, dt: real tick s | alt vs | p r: pitch/roll deg, pr rr yr:
-- rates deg/s | hdg | u w: fwd/right speed | pP pD pI rP rD rI: pitch/roll
-- correction terms (prop units), dp dr: corrections sent | ysp: yaw rate
-- wanted (- = free), yu: yaw tilt demand | L*: prop levels written to the
-- relays | tilt | rear | ms: tick length, pose/vel/in/out: ms spent in those
-- calls (n = count) | ph/mode/ap/cal: phases | keys held
local BB_HEADER = "t dt ph mode ap cal alt vs p r pr rr hdg yr u w pP pD pI rP rD rI dp dr ysp yu"
    .. " LFL LFR LRL LRR tilt rear tick_ms pose_ms vel_ms in_ms/n out_ms/n keys"

local function f1(v) return v and string.format("%.1f", v) or "-" end
local function f2(v) return v and string.format("%.2f", v) or "-" end

local function blackBox(tick_ms)
    local fl = app.fl
    local s, c, o, st = fl.est.s, fl.ctl, fl.out or {}, HW.stats
    local a = c.dbg_att or {}
    local y = c.dbg_yaw
    local lv = fl.levels or {}
    local tl = o.tilt or {}
    local held = {}
    for k, v in pairs(app.keys or {}) do if (v or 0) > 0 and k ~= "PROX" then held[#held + 1] = k end end
    table.sort(held)
    U.bbHeader(BB_HEADER)
    U.bb(table.concat({
        string.format("%.2f", os.clock()), f2(app.dt), fl.phase, fl.mode,
        fl.ap and fl.ap.phase or "-", fl.calib and tostring(fl.calib.stage) or "-",
        f1(s.alt), f2(s.vs), f2(s.pitch), f2(s.roll), f1(s.pitch_rate), f1(s.roll_rate),
        f1(s.heading), f1(s.yaw_rate), f2(s.u), f2(s.w),
        f2(a.pP), f2(a.pD), f2(a.pI), f2(a.rP), f2(a.rD), f2(a.rI), f2(fl.last_dp), f2(fl.last_dr),
        y and f1(y.sp) or "-", y and f2(y.u) or "-",
        tostring(lv.FL or "-"), tostring(lv.FR or "-"), tostring(lv.RL or "-"), tostring(lv.RR or "-"),
        string.format("%d%d%d%d", tl.FL or 0, tl.FR or 0, tl.RL or 0, tl.RR or 0),
        string.format("%.0f%s", o.rear or 0, o.rear_rev and "R" or ""),
        string.format("%.0f", tick_ms), string.format("%.0f", st.pose_ms), string.format("%.0f", st.vel_ms),
        string.format("%.0f/%d", st.in_ms, st.in_n), string.format("%.0f/%d", st.out_ms, st.out_n),
        #held > 0 and table.concat(held, "+") or "-",
    }, " "), os.clock())
end

-- Every 10 s in flight: where the control loop's time goes (log.txt).
local function timingSummary(tick_ms)
    local tm = app.timing or { n = 0, dt = 0, dt_max = 0, tick = 0, pose = 0, vel = 0, inp = 0, out = 0, t0 = os.clock() }
    app.timing = tm
    local st = HW.stats
    tm.n = tm.n + 1
    tm.dt = tm.dt + (app.dt or DT)
    tm.dt_max = math.max(tm.dt_max, app.dt or DT)
    tm.tick, tm.pose, tm.vel = tm.tick + tick_ms, tm.pose + st.pose_ms, tm.vel + st.vel_ms
    tm.inp, tm.out = tm.inp + st.in_ms, tm.out + st.out_ms
    if os.clock() - tm.t0 >= 10 then
        local n = tm.n
        U.log("loop timing (%d ticks): tick every %.0f ms (max %.0f); per tick: %.0f ms working, of which pose %.0f, velocity %.0f, relay reads %.0f, relay writes %.0f",
            n, tm.dt / n * 1000, tm.dt_max * 1000, tm.tick / n, tm.pose / n, tm.vel / n, tm.inp / n, tm.out / n)
        app.timing = nil
    end
end

local function controlTick()
    local tick_t0 = HW.now_ms()
    HW.resetStats()
    app.prev, app.keys = app.keys, HW.inputs()
    if edge("UP") then app.ui:cycleTab(-1) end
    if edge("DOWN") then app.ui:cycleTab(1) end
    if edge("OFF") then offRequest() end

    if app.power == "off" then
        HW.cutAll()
        HW.setClutch(false)
        if edge("SPACE") then beginBoot() end
        return
    elseif app.power == "booting" then
        bootTick(app.dt or DT)
        return
    end

    HW.setClutch(true) -- held while the OS is on: this is what couples the props
    HW.setStarter(false)
    app.fl:update(app.dt or DT, app.keys)
    local ph = app.fl.phase
    writeState((ph == "flying" or ph == "landing" or ph == "unflip") and "air" or "ground", app.fl.gear_down)
    for _, e in ipairs(app.fl.events) do
        if e.kind == "landed" then
            if e.ap then app.last_ap = "LAST ROUTE: ARRIVED AT " .. e.ap end
            if e.shutdown then powerOff("landed") end
        end
    end
    app.fl.events = {}
    if app.fl.ap and app.fl.ap.done then
        app.last_ap = "LAST ROUTE: " .. app.fl.ap.done
        app.fl.ap = nil
    end
    if app.fl.msg then
        say(app.fl.msg.text)
        app.fl.msg = nil
    end
    Rec.tick(os.clock(), app.fl.est.s)
    if app.fl.phase == "parked" then U.bbFlush(os.clock()) end
    if app.fl.phase ~= "parked" then
        local tick_ms = HW.now_ms() - tick_t0
        pcall(blackBox, tick_ms)
        timingSummary(tick_ms)
    end
    -- flight data, once a second while not parked: what the stabiliser saw
    -- and did (dp/dr = pitch/roll correction, prop units)
    local fl = app.fl
    if fl.phase ~= "parked" then
        local now = os.clock()
        if not app.fdr_t or now - app.fdr_t >= 1 then
            app.fdr_t = now
            local s, o, c = fl.est.s, fl.out, fl.ctl
            U.flightLog(string.format(
                "%s %s alt=%.1f vs=%.1f p=%.1f r=%.1f pr=%.1f rr=%.1f hdg=%.0f yr=%.1f u=%.1f w=%.1f "
                .. "dp=%.2f dr=%.2f FL=%.1f FR=%.1f RL=%.1f RR=%.1f tilt=%d%d%d%d rear=%.0f%s sign=%d/%d%s",
                fl.phase, fl.mode, s.alt or 0, s.vs or 0, s.pitch or 0, s.roll or 0, s.pitch_rate or 0,
                s.roll_rate or 0, s.heading or 0, s.yaw_rate or 0, s.u or 0, s.w or 0,
                fl.last_dp or 0, fl.last_dr or 0, o.FL or 0, o.FR or 0, o.RL or 0, o.RR or 0,
                o.tilt and o.tilt.FL or 0, o.tilt and o.tilt.FR or 0, o.tilt and o.tilt.RL or 0,
                o.tilt and o.tilt.RR or 0, o.rear or 0, o.rear_rev and "R" or "",
                c.pitch_sign or 1, c.roll_sign or 1, fl.calib and (" cal:" .. tostring(fl.calib.stage)) or ""))
        end
    end
end

-- The cockpit screen: the configured monitor, unless another attached
-- monitor is bigger (a monitor wall that came apart leaves the configured
-- name on one small piece). Every monitor seen is written to the log.
local function findMonitor()
    local want = app.cfg.ship.peripherals.main_monitor
    local best, best_name, best_area = nil, nil, -1
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local m = peripheral.wrap(name)
            local ok, w, h = pcall(m.getSize)
            local area = ok and (w * h) or 0
            U.log("monitor %s: %sx%s cells%s", name, tostring(w), tostring(h),
                name == want and " (configured)" or "")
            if area > best_area or (area == best_area and name == want) then
                best, best_name, best_area = m, name, area
            end
        end
    end
    if not best and want then best, best_name = peripheral.wrap(want), want end
    if best_name and best_name ~= want then
        U.log("using %s instead of configured %s (bigger)", best_name, tostring(want))
    end
    app.mon_name = best_name
    return best
end

local function initScreen(mon)
    local ok, why = D.init(mon, app.cfg.tune.ui.palette)
    if ok then
        U.log("screen %s: %dx%d px, graphics %s, palette %s", tostring(app.mon_name), D.W, D.H,
            tostring(D.path), D.palette_ok and "v2" or "stock")
        if D.W < 300 or D.H < 180 then
            U.log("screen too small for the layout (need ~348x216 px)")
            say("SCREEN TOO SMALL: CHECK THE MONITOR BLOCKS", D.C.bad)
        end
    else
        U.log("screen %s: %s", tostring(app.mon_name), tostring(why))
    end
    print("monitor: " .. (ok and string.format("%dx%d px, %s", D.W, D.H, D.path) or tostring(why)))
    return ok
end

local function trace(err)
    return tostring(err) .. "\n" .. (debug and debug.traceback and debug.traceback("", 2) or "")
end

function Main.run(opts)
    opts = opts or {}
    local cfg, err = Config.load(ROOT)
    if not cfg then error(err, 0) end
    app.cfg = cfg
    if not fs.exists(ROOT .. "/data") then fs.makeDir(ROOT .. "/data") end
    local f = fs.open(ROOT .. "/data/slot", "w")
    if f then f.write(cfg.slot) f.close() end

    if term.setTextColor then pcall(term.setTextColor, colors.cyan) end
    print("ArtCorp Flight OS " .. V.label)
    if term.setTextColor then pcall(term.setTextColor, colors.white) end
    print("  last fix: " .. V.note)
    print("  ship " .. cfg.name .. " (slot " .. cfg.slot .. ")")
    U.log("---- start (run %s) %s [%s] ship %s slot %s", tostring(opts.runs or 1), V.label, V.note,
        cfg.name, cfg.slot)
    if opts.recovered then U.log("restarted after: %s", tostring(opts.recovered)) end
    HW.init(cfg.ship)
    app.missing = HW.connect()
    if #app.missing > 0 then
        print("missing: " .. table.concat(app.missing, ", "))
        U.log("missing peripherals: %s", table.concat(app.missing, ", "))
        for key, name in pairs(cfg.ship.peripherals) do
            for _, m in ipairs(app.missing) do
                if m == key then U.log("  %s wants '%s'", key, tostring(name)) end
            end
        end
    end
    local seen = {}
    for _, n in ipairs(peripheral.getNames()) do seen[#seen + 1] = n .. "=" .. tostring(peripheral.getType(n)) end
    table.sort(seen)
    U.log("peripherals on the network: %s", #seen > 0 and table.concat(seen, ", ") or "none")
    -- Wiring check: what each relay face is RECEIVING right now (finds the
    -- face a sensor or a pilot key actually arrives on).
    local SIDES = { "top", "bottom", "left", "right", "front", "back" }
    for key, name in pairs(cfg.ship.peripherals) do
        local dev = HW.device(key)
        if dev and type(dev.getAnalogInput) == "function" then
            local parts = {}
            for _, side in ipairs(SIDES) do
                local ok, v = pcall(dev.getAnalogInput, side)
                parts[#parts + 1] = side .. "=" .. (ok and tostring(v) or "?")
            end
            U.log("relay %s (%s) inputs: %s", key, tostring(name), table.concat(parts, " "))
        end
    end
    local pc = cfg.ship.proximity or {}
    U.log("ground sensor is read from %s face '%s'", tostring(pc.input_key), tostring(pc.side))
    app.fl = Flight.new(cfg.tune, HW, cfg.ship)
    loadLearned(app.fl.ctl)
    Nav.init(ROOT, cfg.slot)
    Link.open()
    app.ui = UI.new()
    local mon = findMonitor()
    if mon then
        initScreen(mon)
    else
        print("no monitor found: running headless")
        U.log("no monitor found")
    end
    -- Already in the air (restart after an error, chunk reload, reboot):
    -- take control at once instead of sitting on the splash with the props
    -- cut. On the ground the pilot starts the engines from the screen.
    -- Was the OS flying when it last stopped (error restart, chunk reload,
    -- reboot in the air)? Then take control at once instead of sitting on the
    -- start screen with the props cut. Otherwise the pilot starts the engines.
    local raw = HW.ship()
    local last = readState()
    app.state_where, app.state_gear = last.where, last.gear
    U.log("start: telemetry %s, ground sensor %d, last state %s", raw.ok and "ok" or tostring(raw.err),
        HW.proximity(), tostring(last.where))
    if raw.ok and last.where == "air" then
        app.power = "on"
        app.fl:boot("air", last.gear)
        HW.setClutch(true)
        say("AIRBORNE START: CONTROL RESUMED", D.C.warn)
        U.log("airborne start: control resumed")
    end
    if opts.recovered then
        app.errors[#app.errors + 1] = "RESTARTED AFTER: " .. tostring(opts.recovered)
        say("OS RESTARTED AFTER AN ERROR (SEE ALERT)", D.C.bad)
    end
    print("Ctrl+T (hold) on this computer stops the OS.")

    -- Three loops, each waiting only for its own events (parallel API).
    -- Monitor/relay/telemetry calls make CC suspend the calling loop until
    -- the call completes, and events arriving meanwhile are dropped FOR THAT
    -- LOOP. With one loop, the screen's refresh timer was regularly lost
    -- during a control tick and the screen never drew again; with separate
    -- loops every loop still receives its own timers.
    local running = true
    local actions = {} -- touches queued for the control loop

    local function controlLoop()
        local timer = os.startTimer(DT)
        local last_tick = os.clock()
        while running do
            local e, id = os.pullEventRaw("timer")
            if e == "timer" and id == timer then
                local now = os.clock()
                local period = now - last_tick
                last_tick = now
                app.loop.ms = U.lowpass(app.loop.ms, period * 1000, period, 1)
                -- The REAL time since the last tick. Every peripheral call can
                -- make this loop wait for the game, so a tick takes 0.2 s or
                -- more on the ship, not the 0.05 s the timer asks for. v2.9 and
                -- v2.20 assumed 0.05 s: turn rates came out ~4x too big and
                -- every time constant ran ~4x slow.
                app.dt = U.clamp(period, DT, 0.5)
                while #actions > 0 do
                    local a = table.remove(actions, 1)
                    local ok2, err2 = xpcall(function() act(a) end, trace)
                    if not ok2 then print("[ACTION] " .. tostring(err2)) U.log("action error: %s", err2) end
                end
                local ok, err2 = xpcall(controlTick, trace)
                if not ok then
                    local first = tostring(err2):match("^[^\n]*")
                    if app.errors[#app.errors] ~= first then
                        app.errors[#app.errors + 1] = first
                        if #app.errors > 5 then table.remove(app.errors, 1) end
                        print("[ERROR] " .. first)
                        U.log("control error: %s", err2)
                    end
                end
                timer = os.startTimer(DT) -- always re-armed: an error never stops control
            end
        end
    end

    local function wait(secs)
        local t = os.startTimer(secs)
        repeat local e, id = os.pullEventRaw("timer") until id == t or not running
    end

    local function screenLoop()
        local frames = 0
        while running do
            app.disk = fs.getFreeSpace("/")
            pcall(Link.tick, os.clock())
            if D.ok then
                local t0 = os.clock()
                local ok, err2 = xpcall(function() app.ui:render(model()) end, trace)
                if not ok then
                    local first = tostring(err2):match("^[^\n]*")
                    print("[UI] " .. first)
                    if app.last_ui_err ~= first then
                        app.last_ui_err = first
                        U.log("screen error: %s", err2)
                    end
                    app.ui:invalidate()
                else
                    frames = frames + 1
                    if frames == 1 or frames == 50 then
                        U.log("frame %d drawn (%s) in %.2f s", frames, app.power, os.clock() - t0)
                    end
                end
            end
            wait(1 / math.max(cfg.tune.ui.fps, 1))
        end
    end

    local function eventLoop()
        while running do
            local ev = { os.pullEventRaw() }
            local e = ev[1]
            if e == "monitor_touch" then
                -- In CC:Graphics pixel mode taps arrive as PIXEL positions
                -- (the log showed 168,128 on a 57x24-cell screen); in text
                -- mode they are character cells.
                local px, py
                if D.ok then px, py = ev[3] - 1, ev[4] - 1
                else px, py = (ev[3] - 1) * 6 + 3, (ev[4] - 1) * 9 + 4 end
                local a
                if ev[2] == app.mon_name and D.ok then a = app.ui:touch(px, py) end
                local what = a or (ev[2] ~= app.mon_name and ("other monitor " .. tostring(ev[2]))
                    or (D.ok and "nothing there" or "no graphics"))
                print(string.format("touch %d,%d -> %s", ev[3], ev[4], what))
                U.log("touch %s %d,%d -> %s", tostring(ev[2]), ev[3], ev[4], what)
                if a then actions[#actions + 1] = a end
            elseif e == "monitor_resize" then
                -- monitors can be rebuilt (CC logs "Monitor is malformed, resetting")
                U.log("monitor_resize %s", tostring(ev[2]))
                local mon2 = findMonitor()
                if mon2 and initScreen(mon2) then app.ui:invalidate() end
            elseif e == "rednet_message" then
                pcall(Link.onRednet, ev[2], ev[3])
            elseif e == "modem_message" then
                pcall(Link.onModem, ev[3], ev[4], ev[5])
            elseif e == "peripheral" or e == "peripheral_detach" then
                app.missing = HW.connect()
                Link.opened = {}
                Link.open()
                U.log("%s %s (missing now: %s)", e, tostring(ev[2]),
                    #app.missing > 0 and table.concat(app.missing, ", ") or "none")
                if e == "peripheral" and (not D.ok or peripheral.getType(ev[2]) == "monitor") then
                    local mon2 = findMonitor()
                    if mon2 and initScreen(mon2) then app.ui:invalidate() end
                end
            elseif e == "key" then
                local k = keys.getName(ev[2]) or ""
                if k == "up" then app.ui:cycleTab(-1) elseif k == "down" then app.ui:cycleTab(1) end
            elseif e == "terminate" then
                running = false
                os.queueEvent("timer", -1) -- wake the other loops so they finish
            end
        end
    end

    parallel.waitForAny(eventLoop, controlLoop, screenLoop)
    saveLearned(app.fl.ctl)
    D.shutdown()
    U.bbFlush(os.clock())
    U.log("stopped (terminate)")
    print("Flight OS stopped. Outputs keep their last values; reboot to start it again.")
end

return Main
