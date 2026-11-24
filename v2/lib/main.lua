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

-- ------------------------------------------------------------ learned values

local LEARN_PATH = ROOT .. "/data/learned.lua"
local LEARN_KEYS = { "hover", "pi_", "ri", "yi", "rear_pk", "rear_yk", "yaw_brake" }

local function loadLearned(ctl)
    local t = U.loadTable(LEARN_PATH)
    if not t then return end
    for _, k in ipairs(LEARN_KEYS) do
        if type(t[k]) == "number" then ctl[k] = t[k] end
    end
end

local function saveLearned(ctl)
    local t = {}
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
        app.fl:boot()
        app.ui:invalidate()
        say(app.fl.phase == "parked" and "READY ON THE GROUND (SPACE = TAKE OFF)" or "READY, HOLDING POSITION", D.C.good)
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
        return say("POSITION HOLD " .. (fl.t.hover.brake and "ON" or "OFF"))
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

local function controlTick()
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
        bootTick(DT)
        return
    end

    HW.setClutch(true) -- held while the OS is on: this is what couples the props
    HW.setStarter(false)
    app.fl:update(DT, app.keys)
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

    print("ArtCorp Flight OS v2 - ship " .. cfg.name .. " (slot " .. cfg.slot .. ")")
    U.log("---- start (run %s) ship %s slot %s", tostring(opts.runs or 1), cfg.name, cfg.slot)
    if opts.recovered then U.log("restarted after: %s", tostring(opts.recovered)) end
    HW.init(cfg.ship)
    app.missing = HW.connect()
    if #app.missing > 0 then
        print("missing: " .. table.concat(app.missing, ", "))
        U.log("missing peripherals: %s", table.concat(app.missing, ", "))
    end
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
    local thr = (cfg.ship.proximity or {}).landed_threshold or 15
    local raw = HW.ship()
    local prox0 = HW.proximity()
    U.log("start: telemetry %s, ground sensor %d", raw.ok and "ok" or tostring(raw.err), prox0)
    -- airborne = the sensor sees nothing or the ground is several blocks
    -- down; a parked ship whose sensor reads 13-14 is still on the ground
    if raw.ok and prox0 <= thr - 3 then
        app.power = "on"
        app.fl:boot()
        HW.setClutch(true)
        say("AIRBORNE START: CONTROL RESUMED", D.C.warn)
        U.log("airborne start: control resumed")
    end
    if opts.recovered then
        app.errors[#app.errors + 1] = "RESTARTED AFTER: " .. tostring(opts.recovered)
        say("OS RESTARTED AFTER AN ERROR (SEE ALERT)", D.C.bad)
    end
    print("Ctrl+T (hold) on this computer stops the OS.")

    local control = os.startTimer(DT)
    local frame = os.startTimer(0.2)
    local last_tick = os.clock()
    local running = true
    while running do
        local ev = { os.pullEventRaw() }
        local e = ev[1]
        if e == "timer" and ev[2] == control then
            local now = os.clock()
            local period = now - last_tick
            last_tick = now
            app.loop.ms = U.lowpass(app.loop.ms, period * 1000, period, 1)
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
            control = os.startTimer(DT) -- always re-armed: an error never stops control
        elseif e == "timer" and ev[2] == frame then
            app.disk = fs.getFreeSpace("/")
            Link.tick(os.clock())
            if D.ok then
                local ok, err2 = xpcall(function() app.ui:render(model()) end, trace)
                if not ok then
                    local first = tostring(err2):match("^[^\n]*")
                    print("[UI] " .. first)
                    if app.last_ui_err ~= first then
                        app.last_ui_err = first
                        U.log("screen error: %s", err2)
                    end
                    app.ui:invalidate()
                elseif not app.ui_ok_logged then
                    app.ui_ok_logged = true
                    U.log("first frame drawn (%s)", app.power)
                end
            end
            frame = os.startTimer(1 / math.max(cfg.tune.ui.fps, 1))
        elseif e == "monitor_touch" then
            local px, py = (ev[3] - 1) * 6 + 3, (ev[4] - 1) * 9 + 4
            local a
            if ev[2] ~= app.mon_name then
                a = nil
            elseif D.ok then
                a = app.ui:touch(px, py)
            end
            local what = a or (ev[2] ~= app.mon_name and ("other monitor " .. tostring(ev[2]))
                or (D.ok and "nothing there" or "no graphics"))
            print(string.format("touch %d,%d -> %s", ev[3], ev[4], what))
            U.log("touch %s %d,%d -> %s", tostring(ev[2]), ev[3], ev[4], what)
            local ok2, err2 = xpcall(function() act(a) end, trace)
            if not ok2 then print("[ACTION] " .. tostring(err2)) U.log("action error: %s", err2) end
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
            U.log("%s %s", e, tostring(ev[2]))
            if e == "peripheral" and (not D.ok or peripheral.getType(ev[2]) == "monitor") then
                local mon2 = findMonitor()
                if mon2 and initScreen(mon2) then app.ui:invalidate() end
            end
        elseif e == "key" then
            local k = keys.getName(ev[2]) or ""
            if k == "up" then app.ui:cycleTab(-1) elseif k == "down" then app.ui:cycleTab(1) end
        elseif e == "terminate" then
            running = false
        end
    end
    saveLearned(app.fl.ctl)
    D.shutdown()
    U.log("stopped (terminate)")
    print("Flight OS stopped. Outputs keep their last values; reboot to start it again.")
end

return Main
