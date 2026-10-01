-- Resolve lib modules even if package.path is incomplete
local function loadLib(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    local path = (name:gsub("%.", "/")) .. ".lua"
    local fn, err = loadfile(path)
    if fn then
        local ok2, res = pcall(fn)
        if ok2 then return res end
        error(res, 0)
    end
    error(mod, 0)
end

-- Timestamp prefix for log lines. Declared up front because the boot
-- sequence below calls OS.doAction("apcancel") during startup, which is
-- before the old declaration position was reached -> it resolved to a nil
-- global and threw "attempt to call a nil value (global 'ts')".
local function ts()
    return string.format("[%02.0f]", os.clock())
end

local Flight = loadLib("lib.flight")
local Hardware = loadLib("lib.hardware")
local Rec = loadLib("lib.record")
local Report = loadLib("lib.report")
local Kbd = loadLib("lib.kbd")
local WP = loadLib("lib.waypoints")

local OS = {}
local config = nil
local hw = nil
local flight = nil
local ship_info = nil

local running = false
local status_message = ""
local status_time = 0
local last_hud_update = 0
local hud_interval = 0.1

-- power: "off" = splash, "booting" = load bar + engine sequence, "on" = flight UI
local power_state = "off"
local boot_started = 0
local BOOT_DURATION = 5.0
local clutch_engaged = false

local function hasFeature(name)
    if hw and hw.hasFeature then return hw.hasFeature(name) end
    if config and config.features and config.features[name] ~= nil then
        return not not config.features[name]
    end
    return true
end

function OS.setShipInfo(info)
    ship_info = info
end

-- PID gain file for this ship (config/pid_<slot>.lua)
local function pidFilePath()
    local slot = (config and config.slot)
        or (ship_info and ship_info.profile)
        or "ship"
    return "config/pid_" .. slot .. ".lua"
end

local PID_NAMES = { "altitude", "pitch", "roll", "yaw" }

local function loadPidGains()
    local path = pidFilePath()
    if not fs.exists(path) then
        return false, path
    end
    local fn = loadfile(path)
    if not fn then return false, path end
    local ok, data = pcall(fn)
    if not ok or type(data) ~= "table" then return false, path end
    local any = false
    for _, name in ipairs(PID_NAMES) do
        local pid = flight.pid[name]
        local g = data[name]
        if pid and type(g) == "table" then
            pid:setGains(g.kp or pid.kp, g.ki or pid.ki, g.kd or pid.kd)
            any = true
        end
    end
    return any, path
end

function OS.start(cfg, hardware)
    config = cfg
    hw = hardware

    local eng = config.engine or {}
    BOOT_DURATION = eng.boot_seconds or 5.0

    print("Initializing flight controller...")
    flight = Flight.new(config, hw)
    flight.onGearAutoDeploy = function(prox)
        status_message = "PROX " .. tostring(prox) .. " - GEAR DOWN"
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] gear auto-deploy (prox=" .. tostring(prox) .. ")")
    end

    -- Load saved PID gains from config/pid_<slot>.lua if present
    -- (manual override file; without it the config.pid gains apply).
    local pid_loaded, pid_path = loadPidGains()

    local state = hw.getShipState()
    flight.targets.altitude = state.altitude
    flight:captureHeading()
    if state.sable_error then
        print("  WARNING ship state: " .. tostring(state.sable_error))
        print("  PID may be limited until CC:Sable pose is available.")
    end

    flight:setMode(Flight.MODE_HOVER)
    if not hasFeature("cruise_mode") then
        flight:setMode(Flight.MODE_HOVER)
    end
    flight.proximity = hw.getProximity() or 0
    flight.landed = flight.proximity >= ((config.proximity and config.proximity.landed_threshold) or 15)
    flight:cutPropsSoft()
    if flight.landed or flight.proximity > 0 then
        flight.gear_down = true
        hw.setGear(true)
        -- settle time like a normal deploy (boot-with-prox transient can
        -- otherwise read as landed on the very first update tick)
        flight.gear_settle = (config.proximity and config.proximity.gear_settle_ticks) or 20
        if flight.landed then
            flight.land_state = Flight.LAND_DONE
        else
            flight.land_state = Flight.LAND_IDLE
        end
    else
        flight.gear_down = false
        hw.setGear(false)
        flight.land_state = Flight.LAND_IDLE
    end

    -- Report which gains are active (override file vs config defaults)
    if pid_loaded then
        print("  PID gains loaded: " .. tostring(pid_path))
    else
        print("  PID file missing (" .. tostring(pid_path) .. ") - using config.pid gains")
    end

    hw.setAllSpeed(0)
    hw.cutAllOutputs()
    hw.engineOutputsOff()
    clutch_engaged = false

    -- Waypoints (config/wp_<slot>.lua) + network keyboard for wp input
    local wpn = WP.load(config.slot or "ship")
    print("  Waypoints loaded: " .. tostring(wpn))
    local net_ok = Kbd.openNet()
    if config.kbd_id then -- pre-seed pairing from the setup wizard
        Kbd.id = tonumber(config.kbd_id) or Kbd.id
    end
    if not Kbd.id then -- last runtime pairing (config/kbd_last_id)
        local f = fs.open("config/kbd_last_id", "r")
        if f then
            Kbd.id = tonumber(f.readAll() or "") or nil
            f.close()
        end
    end
    Kbd.onPaired = function(id) -- persist so boots can skip the pairing wait
        local wf = fs.open("config/kbd_last_id", "w")
        if wf then
            wf.writeLine(tostring(id))
            wf.close()
        end
        print("  Keyboard computer #" .. tostring(id) .. " paired (saved)")
    end
    print("  Network: rednet " .. (net_ok and "OPEN" or "NO MODEM") ..
        ", keyboard " .. (Kbd.id and ("#" .. Kbd.id) or "not paired yet"))
    print("  Kbd link: " .. Kbd.stats())

    local mon = hw.getDevice("main_monitor")
    if mon then
        local hud = loadLib("lib.hud")
        local ship_label = (ship_info and ship_info.name) or config.name
        if ship_label then hud.setShipLabel(ship_label) end
        local ok, w, h = pcall(hud.init, mon)
        if ok then
            print("HUD ready: " .. tostring(w) .. "x" .. tostring(h) .. " px (mode 2)")
        else
            print("HUD ERROR: " .. tostring(w))
            print("Monitor HUD disabled.")
        end
    else
        print("No monitor found - HUD disabled.")
    end

    running = true
    power_state = "off"
    status_message = ""
    status_time = 0

    local ship_label = (ship_info and ship_info.name) or config.name or "SHIP"
    local feats = config.features or {}
    print("Flight controller initialized.")
    print("Ship: " .. ship_label .. "  config v" .. tostring(config.version))
    print("Mode: " .. flight.mode .. "  props=0  prox=" .. tostring(flight.proximity) ..
        "  " .. (flight.landed and "LANDED" or "AIRBORNE"))
    print("Features:" ..
        (feats.engine_auto_start and " engine-start" or "") ..
        (feats.clutch and " clutch" or "") ..
        (feats.auto_land and " auto-land" or "") ..
        (feats.cruise_mode and " cruise" or "") ..
        (feats.fuel_level and " fuel" or ""))
    print("Power: OFF (splash) — tap boot to start sequence")
    print("")
    print("Controls (when ON):")
    print("  W/S - Tilt collective (translation)")
    print("  Q/E - Yaw left/right")
    print("  Space/Ctrl - Altitude target +/−")
    if hasFeature("cruise_mode") then
        print("  Shift redstone - Hover <-> Cruise")
        print("  Cruise: W/S rear goal bar 0-15 (step +/-1, hold repeats), Space/Ctrl altitude")
    end
    local ctrl = "  Actions (monitor ACTIONS tab):"
    if hasFeature("auto_land") then ctrl = ctrl .. " land" end
    if hasFeature("gear") then ctrl = ctrl .. " gear" end
    ctrl = ctrl .. " mode  e-stop  reset  tabs"
    print(ctrl)
    print("  Red circle (top-left) - shutdown (decouples clutch)")
    print("    also the engine relay LEFT-face OFF button (rising edge)")
    print("")

    local controlTimer = os.startTimer(0.05)
    OS.mainLoop(controlTimer)
end

function OS.mainLoop(controlTimer)
    while running do
        local event, param1, param2, param3, param4 = os.pullEvent()
        local now = os.clock()

        if event == "key" then
            OS.handleKey(param1, param2)
        elseif event == "timer" then
            if param1 == controlTimer then
                -- 20 Hz cadence health: real inter-tick period + controlTick
                -- work time (os.clock is wall time). Surfaced as the SYSTEMS
                -- tab LOOP readout and as a terminal warning when we run
                -- slow — timers fire late, never early, so the controller
                -- may detune under load but the fixed dt keeps it stable.
                local stats = OS.loop_stats
                if not stats then
                    stats = { ema = 0, worst = 0, late = 0, late_streak = 0,
                              work_ema = 0, work_worst = 0, n = 0 }
                    OS.loop_stats = stats
                end
                if stats._last then
                    local period = now - stats._last
                    stats.n = stats.n + 1
                    if stats.n == 1 then
                        stats.ema = period
                    else
                        stats.ema = stats.ema + (period - stats.ema) * 0.05
                    end
                    if period > stats.worst then stats.worst = period end
                    if period > 0.075 then
                        stats.late = stats.late + 1
                        stats.late_streak = stats.late_streak + 1
                        if stats.late_streak == 5 then
                            print(string.format(
                                "[LOOP] control slow: %.0f ms avg (target 50)",
                                stats.ema * 1000))
                        end
                    else
                        stats.late_streak = 0
                    end
                end
                stats._last = now

                -- Always re-arm so a control error cannot kill the 20 Hz loop;
                -- log each distinct error (once) instead of swallowing it
                local t0 = os.clock()
                local ok, err = pcall(OS.controlTick)
                if ok then
                    local work = os.clock() - t0
                    if stats.work_ema == 0 then
                        stats.work_ema = work
                    else
                        stats.work_ema = stats.work_ema + (work - stats.work_ema) * 0.05
                    end
                    if work > stats.work_worst then stats.work_worst = work end
                    OS._last_tick_error = nil
                elseif err ~= OS._last_tick_error then
                    OS._last_tick_error = err
                    print("[CONTROL ERROR] " .. tostring(err))
                end
                controlTimer = os.startTimer(0.05)
            end
        elseif event == "monitor_touch" then
            pcall(OS.handleMonitorTouch, param2, param3)
        elseif event == "rednet_message" then
            local kok, kerr = pcall(Kbd.onMessage, param1, param2, param3)
            if not kok then
                print("[" .. string.format("%.0f", os.clock()) ..
                    "] kbd message error: " .. tostring(kerr))
            end
        elseif event == "modem_message" then
            -- raw kbd->ship channel (bypasses rednet's dedup/filter)
            local kok, kerr = pcall(Kbd.onModemRaw, param1, param2,
                param3, param4)
            if not kok then
                print("[" .. string.format("%.0f", os.clock()) ..
                    "] kbd raw error: " .. tostring(kerr))
            end
        elseif event == "peripheral" then
            OS.handlePeripheralConnect(param1, param2)
        elseif event == "peripheral_detach" then
            OS.handlePeripheralDisconnect(param1)
        elseif event == "terminate" then
            OS.shutdown()
            return
        end

        if status_time > 0 and now - status_time > 3 then
            status_message = ""
            status_time = 0
        end

        if now - last_hud_update >= hud_interval then
            OS.updateDisplay()
            last_hud_update = now
        end
    end
end

function OS.bootTick()
    if not hw then return end
    if not hasFeature("engine_auto_start") then return end

    local eng = config.engine or {}
    local t = os.clock() - boot_started
    local start_s = eng.start_seconds or 3
    local clutch_at = start_s + (eng.clutch_delay or 1)
    local active = eng.active or 15
    local _ = active

    if t < start_s then
        if not OS._starter_on then
            OS._starter_on = true
            print("[" .. string.format("%.0f", os.clock()) .. "] Engine starter ON (" .. start_s .. "s)")
        end
        hw.setEngineStarter(true)
        hw.setClutch(false)
        clutch_engaged = false
    else
        if OS._starter_on then
            OS._starter_on = false
            hw.setEngineStarter(false)
            print("[" .. string.format("%.0f", os.clock()) .. "] Engine starter OFF")
        end
        hw.setEngineStarter(false)
    end

    if t >= clutch_at then
        -- IMPORTANT: this couples engines -> propellers (flight). Never remove.
        if not clutch_engaged and hasFeature("clutch") then
            hw.setClutch(true)
            clutch_engaged = true
            print("[" .. string.format("%.0f", os.clock()) .. "] Clutch COUPLED")
            status_message = "CLUTCH ON"
            status_time = os.clock()
        elseif hasFeature("clutch") then
            hw.setClutch(true)
        end
    end
end

function OS.controlTick()
    if not flight then return end

    if power_state == "booting" then
        OS.bootTick()
        return
    end

    if power_state ~= "on" then
        -- Keep ship safe while splash
        if power_state == "off" then
            hw.cutAllOutputs()
            flight:cutPropsSoft()
            if not clutch_engaged then
                hw.engineOutputsOff()
            end
        end
        return
    end

    -- ###############################################################
    -- # CRITICAL - FLIGHT ENABLER - DO NOT DELETE OR "OPTIMIZE AWAY" #
    -- ###############################################################
    -- This is what actually couples the engines to the propellers.
    -- Without this block the clutch is never engaged during normal
    -- operation, the engines spin freely, and the ship CANNOT fly.
    -- (The boot-time coupling in OS.bootTick only runs when the
    -- engine_auto_start feature is on, so ships with that feature off
    -- never coupled the clutch at all -- hence this explicit coupling.)
    -- It is load-bearing for flight; removing it grounds the ship.
    if hasFeature("clutch") and not clutch_engaged then
        if hw.setClutch(true) then
            clutch_engaged = true
            print("[" .. string.format("%.0f", os.clock()) ..
                "] Clutch COUPLED -> propellers (flight enabled)")
            status_message = "CLUTCH ON"
            status_time = os.clock()
        end
    end
    -- ###############################################################

    local keys = hw.readInputs()

    -- Engine relay front/back = UP/DOWN tab keys: rising edge switches the
    -- monitor tab (each key press = one step; sides come from input_map).
    OS._tab_edge = OS._tab_edge or { up = false, down = false }
    local up_d = (keys.UP or 0) > 0
    local dn_d = (keys.DOWN or 0) > 0
    if up_d and not OS._tab_edge.up then
        local hud = loadLib("lib.hud")
        local id = hud.prevTab() -- tab strip is top-down: up = earlier tab
        if id then
            status_message = "Tab: " .. tostring(id):upper()
            status_time = os.clock()
        end
    elseif dn_d and not OS._tab_edge.down then
        local hud = loadLib("lib.hud")
        local id = hud.nextTab() -- down = later tab
        if id then
            status_message = "Tab: " .. tostring(id):upper()
            status_time = os.clock()
        end
    end
    OS._tab_edge.up = up_d
    OS._tab_edge.down = dn_d

    -- OFF button: engine relay LEFT face input, same action as the monitor's
    -- red circle. Works with the network down and with no keyboard, which is
    -- the point of putting it on a relay face.
    --
    -- The rising edge lives in Flight:pollOff (stateful across ticks). Checked
    -- BEFORE the flight tick and it returns immediately: powerOff cuts all
    -- outputs, so nothing later in this tick may re-command what it just cut.
    if flight:pollOff(keys.OFF) then
        print("[" .. string.format("%.0f", os.clock()) ..
            "] OFF button (engine relay left) -> shutdown")
        OS.powerOff()
        return
    end

    -- Flight recorder (10 s samples) + keyboard ask timeout
    Rec.tick(os.clock(), flight.state.position)
    Kbd.tick(os.clock())

    local shift = keys.SHIFT or 0
    -- During AUTOPILOT most manual flight controls are inert: only the
    -- on-screen CANCEL button (and e-stop / shutdown) may alter flight —
    -- EXCEPT the manual Q/E yaw stick, which survives into the autopilot's
    -- two rotation phases (aim/align; see the pilot_yaw read below).
    -- Tab switching (UP/DOWN) stays live so the pilot can still read menus.
    local ap_active = flight.ap ~= nil
    local shifted = false
    if hasFeature("cruise_mode") then
        -- always poll so the rising-edge arming stays fresh; Flight:pollShift
        -- itself refuses to toggle the mode while the autopilot owns it.
        shifted = flight:pollShift(shift)
    end
    if shifted and not ap_active then
        status_message = "Mode: " .. flight.mode
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] Mode -> " .. flight.mode .. " (shift)")
    end

    -- Redstone Space/Ctrl altitude steps (rising edge + hold repeat @ 20Hz)
    local step = (config.limits and config.limits.alt_step) or 2
    local sp = (keys.SPACE or 0) > 0
    local ct = (keys.CTRL or 0) > 0
    OS._alt_ticks = OS._alt_ticks or { space = 0, ctrl = 0 }
    local function altHold(name, down, delta)
        local t = OS._alt_ticks
        if not down then
            t[name] = 0
            return
        end
        t[name] = (t[name] or 0) + 1
        -- first tick, then every 0.2s while held
        if t[name] == 1 or t[name] % 4 == 0 then
            if flight:adjustAltitude(delta) then
                status_message = (delta > 0 and "Alt+: " or "Alt-: ") ..
                    string.format("%.1f", flight.targets.altitude)
                status_time = os.clock()
            end
        end
    end
    -- Manual Q/E yaw stick, read every tick: while the autopilot runs it
    -- survives as flight.pilot_yaw and Flight adds it to its own yaw_cmd in
    -- the two rotation phases — aim (not facing the goal yet) and align
    -- (above the waypoint, turning onto the saved heading). Cruise/correct/
    -- arrive ignore it: bank-to-turn owns the heading there with the rear
    -- thrusters at speed.
    local pilot_yaw = 0
    if keys.Q and keys.Q > 0 then pilot_yaw = -1
    elseif keys.E and keys.E > 0 then pilot_yaw = 1 end
    flight.pilot_yaw = pilot_yaw

    if not ap_active then
        altHold("space", sp, step)
        altHold("ctrl", ct, -step)
        flight:processInputs(keys)
    else
        -- keep the held-repeat counters cleared so release does not burst
        OS._alt_ticks.space = 0
        OS._alt_ticks.ctrl = 0
    end
    flight:update()

    -- Safety shutdown requested by flight (auto-land goal runaway):
    -- powerOff decouples the clutch (props free of the engines) and drops
    -- the monitor back to the splash screen.
    if flight.shutdown_request then
        local why = flight.shutdown_request
        flight.shutdown_request = nil
        print("[" .. string.format("%.0f", os.clock()) ..
            "] Safety shutdown: " .. tostring(why))
        OS.powerOff()
        return
    end

    -- Waypoint autopilot events (arrival / cancellation)
    if flight.wp_event then
        local e = flight.wp_event
        flight.wp_event = nil
        if e.kind == "arrived" then
            status_message = "ARRIVED: " .. tostring(e.name)
            print("[" .. string.format("%.0f", os.clock()) ..
                "] WP arrived: " .. tostring(e.name))
        else
            status_message = "WP CANCELLED: " .. tostring(e.name)
        end
        status_time = os.clock()
    end
end

-- Shared by keyboard (M/L/G/X/R/T/N) and ACTIONS tab buttons
function OS.doAction(name)
    if power_state ~= "on" or not flight then return end

    -- AUTOPILOT: the manual flight actions are inert so nothing can wrest
    -- control from the sequence. Only emergencies (estop), the window toggle
    -- and the autopilot's own CANCEL button are allowed through.
    if flight.ap ~= nil and name ~= "estop"
        and name ~= "apcancel" and name ~= "autopilot" then
        status_message = "AUTOPILOT ACTIVE - use CANCEL"
        status_time = os.clock()
        return
    end

    if name == "estop" then
        flight:emergencyStop()
        status_message = "EMERGENCY STOP"
        status_time = os.clock()
        print("[" .. string.format("%.0f", os.clock()) .. "] EMERGENCY STOP")

    elseif name == "apcancel" then
        -- reason nil: cancelAutopilot stays quiet, the status line reports it
        local ok = flight:cancelAutopilot(nil)
        status_message = ok and "AUTOPILOT CANCELLED" or "NO AUTOPILOT"
        status_time = os.clock()
        if ok then print(ts() .. " autopilot cancelled") end

    elseif name == "land" then
        if not hasFeature("auto_land") then
            status_message = "No auto-land on this ship"
            status_time = os.clock()
        else
            local ok, msg = flight:toggleAutoLand()
            status_message = msg or "AUTO-LAND"
            status_time = os.clock()
            print("[" .. string.format("%.0f", os.clock()) .. "] " .. tostring(msg))
        end

    elseif name == "gear" then
        if not hasFeature("gear") then
            status_message = "No gear on this ship"
            status_time = os.clock()
        elseif not flight.gear_down then
            flight.gear_down = true
            hw.setGear(true)
            flight.gear_settle = (config.proximity and config.proximity.gear_settle_ticks) or 20
            status_message = "GEAR DOWN"
            status_time = os.clock()
        elseif (flight.proximity or 0) > 0 then
            status_message = "PROX ACTIVE - GEAR LOCKED"
            status_time = os.clock()
        else
            flight.gear_down = false
            hw.setGear(false)
            status_message = "GEAR UP"
            status_time = os.clock()
        end

    elseif name == "autopilot" then
        -- Toggle the waypoint window (list -> popup -> travel/delete)
        local hud = loadLib("lib.hud")
        if hud.wpIsOpen() then
            hud.wpClose()
        else
            hud.setWaypoints(WP.list)
            hud.wpOpen()
        end
    end
end

-- ============================================================
-- Printer / recorder / waypoint actions (NAV tab + wp window)
-- ============================================================
function OS.findPrinter()
    if OS._printer_off and os.clock() - OS._printer_off < 5 then
        return nil -- throttle scans right after a detach
    end
    if OS._printer_cache then
        local ok, alive = pcall(function()
            return peripheral.getName(OS._printer_cache) ~= nil
        end)
        if ok and alive then return OS._printer_cache end
        OS._printer_cache = nil
    end
    local pname = config and config.peripherals and config.peripherals.printer
    local pr = nil
    if pname then
        pr = peripheral.wrap(pname)
        -- a wired-network name can be reused: make sure it is really a printer
        if pr and type(pr.newPage) ~= "function" then pr = nil end
    end
    if not pr then
        pr = peripheral.find("printer")
    end
    OS._printer_cache = pr
    return pr
end

local function validName(v)
    return type(v) == "string" and v ~= "" and #v <= 10
        and v:match("^%w+$") ~= nil
end

function OS.doNav(op)
    if power_state ~= "on" or not flight then return end

    if op == "rec" then
        local on = Rec.toggle(flight.state.position)
        if on then
            status_message = "REC STARTED (10s samples)"
            print(ts() .. " recorder started")
        else
            status_message = string.format("REC STOPPED (%d samples)", Rec.count())
            print(ts() .. " recorder stopped: " .. Rec.count() .. " samples")
        end
        status_time = os.clock()

    elseif op == "print" then
        if OS.printing then
            status_message = "ALREADY PRINTING"
            status_time = os.clock()
            return
        end
        if Rec.count() < 2 then
            status_message = "NO RECORDING - PRESS REC FIRST"
            status_time = os.clock()
            return
        end
        local pr = OS.findPrinter()
        if not pr then
            status_message = "NO PRINTER FOUND"
            status_time = os.clock()
            return
        end
        OS.printing = "1/3"
        status_time = os.clock()
        local title = (ship_info and ship_info.name) or config.name or "SHIP"
        local ok, msg = Report.print(pr, Rec.data(), title, Rec.stats(),
            Rec.INTERVAL)
        OS.printing = nil
        status_message = msg or (ok and "PRINTED" or "PRINT FAILED")
        status_time = os.clock()
        print(ts() .. " print: " .. status_message)

    elseif op == "quickwp" then
        if Kbd.isPending() then
            Kbd.cancel("cancelled")
            status_message = "KBD CANCELLED"
            status_time = os.clock()
            return
        end
        local pos = flight.state.position
        local heading = ((flight.state.yaw or 0) % 360 + 360) % 360
        local x, z = pos.x, pos.z
        local ok, err = Kbd.ask({ { "Name", "name" } }, function(values, kerr)
            if not values then
                status_message = "KBD: " .. tostring(kerr or "failed")
                status_time = os.clock()
                return
            end
            local name = values[1]
            if not validName(name) then
                status_message = "BAD NAME (1-10 letters/digits)"
                status_time = os.clock()
                return
            end
            local n, aerr = WP.add({ name = name, x = x, z = z,
                heading = heading })
            if not n then
                status_message = "WP SAVE FAILED"
                status_time = os.clock()
                return
            end
            local hud = loadLib("lib.hud")
            hud.setWaypoints(WP.list)
            status_message = "WP SAVED: " .. name
            status_time = os.clock()
            print(ts() .. " waypoint saved: " .. name ..
                string.format(" (%.1f, %.1f, H%.0f)", x, z, heading))
        end)
        if not ok then
            status_message = "KBD: " .. tostring(err)
            status_time = os.clock()
        else
            status_message = Kbd.promptText() or "KBD..."
            status_time = os.clock()
        end

    elseif op == "newwp" then
        if Kbd.isPending() then
            Kbd.cancel("cancelled")
            status_message = "KBD CANCELLED"
            status_time = os.clock()
            return
        end
        local ok, err = Kbd.ask({
            { "X", "number" },
            { "Z", "number" },
            { "Heading", "number" },
            { "Name", "name" },
        }, function(values, kerr)
            if not values then
                status_message = "KBD: " .. tostring(kerr or "failed")
                status_time = os.clock()
                return
            end
            local x, z, h = tonumber(values[1]), tonumber(values[2]),
                tonumber(values[3])
            local name = values[4]
            if not x or not z or not h then
                status_message = "BAD NUMBER INPUT"
                status_time = os.clock()
                return
            end
            if not validName(name) then
                status_message = "BAD NAME (1-10 letters/digits)"
                status_time = os.clock()
                return
            end
            local n, aerr = WP.add({ name = name, x = x, z = z, heading = h })
            if not n then
                status_message = "WP SAVE FAILED"
                status_time = os.clock()
                return
            end
            local hud = loadLib("lib.hud")
            hud.setWaypoints(WP.list)
            status_message = "WP SAVED: " .. name
            status_time = os.clock()
            print(ts() .. " waypoint saved: " .. name ..
                string.format(" (%.1f, %.1f, H%.0f)", x, z, h % 360))
        end)
        if not ok then
            status_message = "KBD: " .. tostring(err)
            status_time = os.clock()
        else
            status_message = Kbd.promptText() or "KBD..."
            status_time = os.clock()
        end
    end
end

-- Actions coming from the waypoint window ("travel:N", "confirmdel:N",
-- "noop").
function OS.doWp(op)
    local i = tonumber(op:match("^travel:(%d+)$") or "")
        or tonumber(op:match("^confirmdel:(%d+)$") or "")
    if op:match("^travel:") then
        local wp = i and WP.list[i]
        if not wp then return end
        local ok, msg = flight and flight:startAutopilot(wp)
        status_message = msg or (ok and "AUTOPILOT" or "AUTOPILOT FAILED")
        status_time = os.clock()
        if ok then
            local hud = loadLib("lib.hud")
            hud.wpClose()
            print(ts() .. " autopilot -> " .. tostring(wp.name))
        end
    elseif op:match("^confirmdel:") then
        local wp = i and WP.list[i]
        if not wp then return end
        local name = wp.name
        WP.remove(i)
        local hud = loadLib("lib.hud")
        hud.setWaypoints(WP.list)
        hud.wpAfterDelete()
        status_message = "WP DELETED: " .. tostring(name)
        status_time = os.clock()
        print(ts() .. " waypoint deleted: " .. tostring(name))
    end
    -- "noop" and anything else: view transition already handled by the HUD
end

function OS.handleKey(key, held)
    if held then return end
    local keys = _G.keys
    if not keys then
        local ok, mod = pcall(require, "keys")
        if ok then keys = mod end
    end
    if not keys then return end

    -- Power keys only meaningful when on (except allow nothing on splash)
    if power_state == "off" then
        if key == keys.space or key == keys.enter then
            OS.beginBoot()
        end
        return
    end
    if power_state == "booting" then
        return
    end

    -- Tab navigation: keyboard arrows mirror the redstone UP/DOWN relays.
    -- Arrows stay live even during autopilot (only flight controls are inert).
    if key == keys.up or key == keys.down then
        local hud = loadLib("lib.hud")
        local id = (key == keys.up) and hud.prevTab() or hud.nextTab()
        if id then
            status_message = "Tab: " .. tostring(id):upper()
            status_time = os.clock()
        end
        OS.updateDisplay()
        return
    end

    -- Space/Ctrl altitude = a manual flight control: inert during autopilot.
    if flight and flight.ap then return end

    -- Actions (mode/land/gear/estop/…) are monitor-only (ACTIONS tab).
    if key == keys.space then
        local step = (config.limits and config.limits.alt_step) or 2
        if flight:adjustAltitude(step) then
            status_message = "Alt+: " .. string.format("%.1f", flight.targets.altitude)
            status_time = os.clock()
        end
    elseif key == keys.leftCtrl or key == keys.rightCtrl then
        local step = (config.limits and config.limits.alt_step) or 2
        if flight:adjustAltitude(-step) then
            status_message = "Alt-: " .. string.format("%.1f", flight.targets.altitude)
            status_time = os.clock()
        end
    end
end

function OS.beginBoot()
    if power_state ~= "off" then return end
    power_state = "booting"
    boot_started = os.clock()
    OS._starter_on = false
    clutch_engaged = false
    -- A fresh boot must not inherit the previous run's e-stop latch
    -- (powerOff->emergencyStop leaves it set; HUD would show READY otherwise).
    if flight then
        flight.estop = false
        -- Re-stamp the altitude goal on the first powered tick. powerOff ran
        -- setMode(HOVER), which froze targets.altitude at the power-off
        -- altitude, and controlTick does not call flight:update() while the
        -- splash/boot screens are up -- so state.altitude never refreshes
        -- during them. If the ship was moved in that window, powering up would
        -- otherwise fly it back to the pre-move altitude. The flag is consumed
        -- in Flight:update() after updateState(), so the goal comes from a
        -- fresh reading rather than the stale one (Flight:resyncAltitudeTarget).
        flight.recapture_alt = true
    end
    status_message = ""
    print("[" .. string.format("%.0f", os.clock()) .. "] Boot sequence (" .. tostring(BOOT_DURATION) .. "s)...")
end

function OS.powerOff()
    if power_state ~= "on" then return false, "NOT ON" end
    if not flight then return false, "NO FLIGHT" end
    -- allowed in the air too (pilot may need an emergency power-down);
    -- emergencyStop cuts all outputs, so the ship will drop
    flight:emergencyStop()
    hw.cutAllOutputs()
    -- Decouple clutch on deliberate shutdown only (grounded power button)
    if hasFeature("clutch") then
        hw.setClutch(false)
        clutch_engaged = false
        print("[" .. string.format("%.0f", os.clock()) .. "] Clutch DECOUPLED")
    end
    hw.setEngineStarter(false)
    OS._starter_on = false
    power_state = "off"
    -- Session state back to a first-time OS start: HOVER mode, default tab,
    -- no stale status. (beginBoot still clears the e-stop latch on the next
    -- boot.) Next screen is the boot splash.
    flight:setMode(Flight.MODE_HOVER)
    Rec.stop()
    Kbd.cancel("shutdown")
    OS.printing = nil
    local hud = loadLib("lib.hud")
    hud.resetState()
    status_message = ""
    print("[" .. string.format("%.0f", os.clock()) .. "] Shutdown -> splash")
    return true, "OFF"
end

function OS.handleMonitorTouch(x, y)
    local hud = loadLib("lib.hud")
    local action = hud.handleTouch(x, y)
    if not action then return end

    if power_state == "off" then
        if action == "boot" then
            OS.beginBoot()
        end
    elseif power_state == "booting" then
        -- ignore
    elseif action == "shutdown" then
        local ok, msg = OS.powerOff()
        if not ok then
            status_message = msg or "SHUTDOWN BLOCKED"
            status_time = os.clock()
            print("[" .. string.format("%.0f", os.clock()) .. "] Shutdown blocked: " .. tostring(msg))
        end
    elseif action:sub(1, 4) == "act:" then
        OS.doAction(action:sub(5))
    elseif action:sub(1, 4) == "nav:" then
        OS.doNav(action:sub(5))
    elseif action:sub(1, 3) == "wp:" then
        OS.doWp(action:sub(4))
    elseif action ~= "boot" then
        local tab = action
        if action:sub(1, 4) == "tab:" then
            tab = action:sub(5)
        end
        status_message = "Tab: " .. tostring(tab):upper()
        status_time = os.clock()
    end

    -- redraw now so the first tap is visible without waiting for the HUD timer
    OS.updateDisplay()
    last_hud_update = os.clock()
end

function OS.handlePeripheralConnect(name, peripheralType)
    print("[" .. string.format("%.0f", os.clock()) .. "] Connected: " .. name)
    status_message = "Connected: " .. name
    status_time = os.clock()
    OS._printer_cache = nil
    OS._printer_off = nil
    Kbd.openNet() -- a freshly attached modem may be the rednet link
    for key, assigned in pairs(config.peripherals or {}) do
        if assigned == name then
            pcall(Hardware.connect)
        end
    end
end

function OS.handlePeripheralDisconnect(name)
    print("[" .. string.format("%.0f", os.clock()) .. "] Disconnected: " .. name)
    status_message = "Disconnected: " .. name
    status_time = os.clock()
    OS._printer_cache = nil
    OS._printer_off = os.clock()
    Kbd._opened[name] = nil -- allow re-open if a modem detaches
end

function OS.updateDisplay()
    local mon = hw.getDevice("main_monitor")
    if not mon then return end

    local hud = loadLib("lib.hud")

    if power_state == "off" then
        pcall(hud.renderPower, "off", 0, status_message)
        return
    end

    if power_state == "booting" then
        local p = (os.clock() - boot_started) / BOOT_DURATION
        if p >= 1 then
            power_state = "on"
            hud.markChromeDirty()
            status_message = clutch_engaged and "READY + CLUTCH" or "READY"
            status_time = os.clock()
            print("[" .. string.format("%.0f", os.clock()) .. "] Boot complete" ..
                (clutch_engaged and " (clutch coupled)" or ""))
            p = 1
        end
        pcall(hud.renderPower, "booting", p, status_message)
        return
    end

    if not flight then return end
    local ok, err = pcall(function()
        local status = flight:getStatus()
        -- OS-level fields the NAV tab buttons/status line need
        status.loop = OS.loop_stats -- 20 Hz cadence stats (SYSTEMS tab)
        status.recording = Rec.isActive()
        status.rec_t = Rec.duration()
        status.rec_n = Rec.count()
        status.kbd_prompt = Kbd.promptText()
        status.kbd_last = Kbd.lastInfo()
        status.printing = OS.printing
        status.has_printer = OS.findPrinter() ~= nil
        hud.render(mon, status, config, status_message)
    end)
    if not ok then
        if not OS._hud_error_once then
            OS._hud_error_once = true
            print("[HUD ERROR] " .. tostring(err))
        end
    end
end

function OS.shutdown()
    running = false
    if flight then flight:emergencyStop() end
    pcall(function()
        if hw then
            hw.setEngineStarter(false)
            if hasFeature("clutch") then
                hw.setClutch(false)
                clutch_engaged = false
            end
        end
    end)
    pcall(function()
        local hud = loadLib("lib.hud")
        hud.shutdown()
    end)
    print("ArtCorpOS shutdown.")
end

return OS
