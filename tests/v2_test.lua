-- v2 OS flight tests: the real v2 code flying the rigid-body simulator.
-- Run via tests/run.py (lupa). Prints one line per scenario.
local World = dofile("tests/v2/world.lua")
local Sim = require("sim")
local HW = require("hw")
local U = require("util")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1 else
        failed = failed + 1
        print("FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end
local function f(n) return string.format("%.2f", n) end

local function landedEvent(w)
    for _, e in ipairs(w.fl.events) do if e.kind == "landed" then return e end end
end

-- 1. Estimator conventions: the quaternion -> heading/pitch/roll path
do
    for _, c in ipairs({ { 0, 0, 0 }, { 90, 5, 0 }, { 213, -7, 12 }, { 359, 3, -20 } }) do
        local w = World.new({ sim = { heading = c[1], pitch = c[2], roll = c[3], y = 120 } })
        local s = w.fl.est:update(HW.ship(), 0.05)
        local h, p, r = w.sim:attitude()
        check("est heading " .. c[1], math.abs(U.wrap180(s.heading - h)) < 0.01, f(s.heading))
        check("est pitch " .. c[1], math.abs(s.pitch - p) < 0.01, f(s.pitch))
        check("est roll " .. c[1], math.abs(s.roll - r) < 0.01, f(s.roll))
        if c[2] == 0 or c[3] == 0 then
            -- single-axis cases must read back exactly what was built
            check("est pitch built " .. c[1], math.abs(s.pitch - c[2]) < 0.01, f(s.pitch))
            check("est roll built " .. c[1], math.abs(s.roll - c[3]) < 0.01, f(s.roll))
        end
    end
    -- ship pointing north, moving north = positive forward speed
    local w = World.new({ sim = { heading = 0, y = 120 } })
    w.sim.vel.z = -3
    w.sim.history = {}
    w.sim:snapshot()
    local s = w.fl.est:update(HW.ship(), 0.05)
    check("est forward speed", math.abs(s.u - 3) < 1e-6, f(s.u))
    w.sim.vel.z, w.sim.vel.x = 0, 2 -- east = to the right of north
    w.sim.history = {}
    w.sim:snapshot()
    s = w.fl.est:update(HW.ship(), 0.05)
    check("est sideways speed (+ = right)", math.abs(s.w - 2) < 1e-6, f(s.w))
end

-- 2. Wiring: thrust is inverted at the wire, tilt is on/off
do
    local w = World.new({ yaw_as_designed = true }) -- raw pins, no side swap
    HW.setProp("FL", 12)
    HW.setTilt("FR", -1)
    local o = w.sim:readOutputs()
    check("wire: FL thrust 12 -> reads 12", o.FL == 12, o.FL)
    check("wire: FR tilt back", o.FR_tilt == -1, o.FR_tilt)
end

-- 3. Takeoff from the ground and hover
do
    local w = World.new()
    check("boot on the ground = parked", w.fl.phase == "parked", w.fl.phase)
    w:tap("SPACE")
    local maxatt = 0
    -- long enough for the take-off direction check to finish its nudges
    w:run(70, function(w)
        local t = w:truth()
        maxatt = math.max(maxatt, math.abs(t.pitch), math.abs(t.roll))
    end)
    local t = w:truth()
    print(string.format("takeoff: alt=%.2f (target %.1f) maxatt=%.2f", t.alt, w.fl.alt_target, maxatt))
    check("takeoff: flying", w.fl.phase == "flying", w.fl.phase)
    check("takeoff: climbs 20 m", math.abs(w.fl.alt_target - 84) < 0.01, w.fl.alt_target)
    check("takeoff: holds altitude", math.abs(t.alt - 84) < 0.5, f(t.alt))
    check("takeoff: level", maxatt < 3, f(maxatt))
end

-- 4. Hover with an off-centre hull: trims itself level and holds position
do
    local w = World.new({ sim = { hull_pitch = 0.5, hull_roll = -0.3, hull_yaw = 0.2 } }):airborne(150, 90)
    w.sim.vel.x, w.sim.vel.z = 2, 1.5
    local sum, n, mx = 0, 0, 0
    w:run(60, function(w)
        if w.t > 25 then
            local t = w:truth()
            local a = math.max(math.abs(t.pitch), math.abs(t.roll))
            sum, n, mx = sum + a, n + 1, math.max(mx, a)
        end
    end)
    local t = w:truth()
    print(string.format("hover trim: mean=%.2f max=%.2f hdg=%.1f drift=%.1f m alt=%.2f", sum / n, mx, t.heading, U.hypot(t.x, t.z), t.alt))
    check("hover: mean attitude < 1.5", sum / n < 1.5, f(sum / n))
    check("hover: max attitude < 3", mx < 3, f(mx))
-- no heading hold any more (the ship cannot strafe, so hands-off only
    -- stops rotation and fore/aft drift); it must not be spinning
    check("hover: not rotating", math.abs(w.fl.est.s.yaw_rate) < 1.5, f(w.fl.est.s.yaw_rate))
    check("hover: drift braked (coasting allowed under the pulse threshold)", t.speed < 1.2, f(t.speed))
    check("hover: drift distance bounded", U.hypot(t.x, t.z) < 25, f(U.hypot(t.x, t.z)))
    check("hover: altitude held", math.abs(t.alt - 150) < 1, f(t.alt))
end

-- 5. Turning at cruise altitude does not sink (the rotate-step drop)
do
    local w = World.new():airborne(230, 0)
    w:run(5)
    local low = 1e9
    -- a heading command (what the autopilot sends) instead of the pilot
    w.fl.ap = { update = function() return { alt = 230, heading = 180, damp_u = 0 } end, cancel = function() end }
    w:run(60, function(w) low = math.min(low, w:truth().alt) end)
    w.fl.ap = nil
    local t = w:truth()
    print(string.format("turn@230: heading=%.1f lowest=%.2f", t.heading, low))
    check("turn@230: reaches heading", math.abs(U.wrap180(t.heading - 180)) < 4, f(t.heading))
    check("turn@230: no sink (< 1.5 m)", 230 - low < 1.5, f(230 - low))
end

-- 6. Manual controls: Q turns left, W moves forward, release brakes
do
    local w = World.new():airborne(120, 0)
    w.sim:press("Q", true) w:run(3) w.sim:press("Q", false)
    w:run(8)
    local h = w:truth().heading
    check("Q turns left", U.wrap180(h - 0) < -10, f(h))
    local w2 = World.new():airborne(120, 0)
    w2.sim:press("W", true) w2:run(4) w2.sim:press("W", false)
    local moved = -w2:truth().z
    check("W moves forward (north)", moved > 3, f(moved))
    w2:run(15)
    check("release brakes to a stop", w2:truth().speed < 0.6, f(w2:truth().speed))
end

-- 7. Auto-land from 80 m above ground
do
    local w = World.new({ sim = { hull_roll = 0.3 } }):airborne(144, 30)
    w:run(3)
    w.fl:beginLanding({})
    local maxatt, maxsink = 0, 0
    w:run(90, function(w)
        local t = w:truth()
        maxatt = math.max(maxatt, math.abs(t.pitch), math.abs(t.roll))
        maxsink = math.max(maxsink, -t.vy)
        return w.fl.phase == "parked"
    end)
    print(string.format("autoland: t=%.1f touch=%.2f maxsink=%.2f maxatt=%.2f", w.t, w.sim.touch_v or -1, maxsink, maxatt))
    check("autoland: landed", w.fl.phase == "parked", w.fl.phase)
    check("autoland: soft (< 1.2 m/s)", (w.sim.touch_v or 9) < 1.2, w.sim.touch_v)
    check("autoland: sink capped", maxsink < w.tune.vertical.sink_max + 1, f(maxsink))
    check("autoland: level", maxatt < 4, f(maxatt))
    check("autoland: under 40 s", w.t < 40, f(w.t))
end

-- 8. Long autopilot trip with an off-centre rear thruster (pitches the nose
--    AND yaws right), from the ground, ending landed on the waypoint heading
do
    -- rear_dy -0.7 with pitch inertia 100 tips the hull as hard as -2 did
    -- with the old 300 (the real three rear thrusters sit around the centre)
    local w = World.new({ sim = { drag = 0.08, rear_dz = 0.4, rear_dy = -0.7, hull_pitch = 0.3 } })
    w:startAP({ name = "FAR", x = 1200, z = -800, heading = 200 })
    local maxatt, below, phases = 0, 0, {}
    w:run(600, function(w)
        local t = w:truth()
        maxatt = math.max(maxatt, math.abs(t.pitch), math.abs(t.roll))
        local ap = w.fl.ap
        if ap then
            phases[ap.phase] = true
            if ap.phase == "cruise" then below = math.max(below, ap.goal_alt - t.alt) end
        end
        return landedEvent(w) ~= nil
    end)
    local t = w:truth()
    local miss = U.hypot(t.x - 1200, t.z + 800)
    print(string.format("trip: t=%.0f miss=%.1f m hdg=%.1f touch=%.2f below=%.1f maxatt=%.1f", w.t, miss, t.heading, w.sim.touch_v or -1, below, maxatt))
    check("trip: landed", landedEvent(w) ~= nil)
    check("trip: used cruise", phases.cruise == true)
    -- The ship cannot strafe, so it stops near the point, turns in place
    -- and descends with only fore/aft drift cancelled (no sideways fixes:
    -- the tail fin would turn them into rotation). It lands where it drifts
    -- to: within ~15 m is the target for a hull this size.
    check("trip: on the waypoint (< 15 m)", miss < 15, f(miss))
    -- aligned before the descent; no heading hold on the way down (no tilt
    -- loops), so the tail fin may turn it a little as it drifts
    check("trip: on its heading (within 20 deg)", math.abs(U.wrap180(t.heading - 200)) < 20, f(t.heading))
    -- the altitude hold is a fixed prop speed (the air settles the ship):
    -- at speed, airflow through the slightly pitched props costs some lift
    -- and the ship sinks a few metres until the denser air holds it
    check("trip: never sank > 10 m in cruise", below < 10, f(below))
    check("trip: attitude < 8 deg", maxatt < 8, f(maxatt))
    check("trip: soft touchdown", (w.sim.touch_v or 9) < 1.2, w.sim.touch_v)
    check("trip: autopilot released", w.fl.ap == nil)
    check("trip: asks for power-off", landedEvent(w).shutdown == true)
end

-- 9. Short hop stays in hover
do
    local w = World.new():airborne(100, 0)
    w:startAP({ name = "HOP", x = -150, z = 120, heading = 90 })
    local vmax = 0
    w:run(300, function(w)
        vmax = math.max(vmax, w:truth().speed)
        return landedEvent(w) ~= nil
    end)
    local t = w:truth()
    local miss = U.hypot(t.x + 150, t.z - 120)
    print(string.format("hop: t=%.0f miss=%.1f", w.t, miss))
    check("hop: landed", landedEvent(w) ~= nil)
    check("hop: slow (hop speed cap)", vmax < w.tune.autopilot.hop_speed + 2, f(vmax))
    check("hop: on the waypoint (< 15 m)", miss < 15, f(miss))
end

-- 10. E-stop cuts the props; SPACE restores flight
do
    local w = World.new():airborne(150, 0)
    w:run(2)
    w.fl:setEstop(true)
    w:run(0.5)
    local o = w.sim:readOutputs()
    check("estop: props cut", o.FL == 0 and o.RR == 0, o.FL)
    w:tap("SPACE")
    w:run(20)
    check("estop: SPACE resumes", w.fl.phase == "flying", w.fl.phase)
    check("estop: recovers a hover", math.abs(w:truth().vy) < 1, f(w:truth().vy))
end

-- 11. Upside down in the air: auto-unflip rights the ship
do
    local w = World.new({ sim = { roll = 175, y = 260 } }):airborne(260, 0)
    w.sim.q = Sim.quatFromHeading(0, 0, 175)
    w.sim.history = {}
    w.sim:snapshot()
    w.fl:boot("air")
    local upright_at, reversed_at
    w:run(40, function(w)
        local _, _, r, up = w.sim:attitude()
        if w.sim.lift_reverse and not reversed_at then reversed_at = w.t end
        if up > 0.9 and not upright_at and w.fl.phase == "flying" and not w.sim.grounded then
            upright_at = w.t
        end
        return upright_at and w.t > upright_at + 5
    end)
    check("unflip: reverses lift within 1.2 s", reversed_at and reversed_at < 1.2, reversed_at)
    local t = w:truth()
    print(string.format("unflip: upright at %s, alt=%.1f", tostring(upright_at), t.alt))
    -- KNOWN LIMIT, not asserted: with the sim's roll inertia the roll from
    -- 175 to 90 deg takes ~7 s at full differential with no vertical lift
    -- near 90 deg, so the simulated ship reaches the ground from any height
    -- (130..260 m tried). Whether the real ship rolls faster is unknown; this
    -- test only pins the sequence: cut, reverse, right, release, fly.
    check("unflip: upright again", upright_at ~= nil)
    check("unflip: still flying", w.fl.phase == "flying", w.fl.phase)
    check("unflip: lift reverse released", w.sim.lift_reverse == false)
end

-- 12. Robustness: the ship's real inertia and lags are unknown, so sweep them
do
    local worst = 0
    for _, inertia in ipairs({ 0.5, 1, 2 }) do
        for _, tau in ipairs({ 0.1, 0.25, 0.5 }) do
            for _, delay in ipairs({ 1, 2 }) do
                local w = World.new({ sim = { inertia = { 30 * inertia, 400 * inertia, 100 * inertia },
                    prop_tau = tau * 2.4, delay_ticks = delay, hull_pitch = 0.4 } }):airborne(150, 45)
                w.sim.vel.x = 3
                local mx = 0
                w:run(40, function(w)
                    if w.t > 15 then
                        local t = w:truth()
                        mx = math.max(mx, math.abs(t.pitch), math.abs(t.roll))
                    end
                end)
                worst = math.max(worst, mx)
                check(string.format("robust I x%.1f tau %.2f delay %d", inertia, tau, delay), mx < 4, f(mx))
            end
        end
    end
    print(string.format("robustness: worst steady attitude %.2f deg", worst))
end

-- 13. Direction self-check at take-off. A correction that pushes the wrong
--     way makes a self-righting hull swing wider every time (the reported
--     roll); the take-off check must detect it and fix it, and must leave a
--     correctly wired ship alone.
do
    local function flight(swap_lr, swap_fb)
        -- real-ship-like response (strong, ~1 s late), pitch 3x heavier
        local w = World.new({ sim = { inertia = { 30, 400, 300 }, prop_tau = 0.6 } })
        if swap_lr or swap_fb then
            local raw = w.sim.readOutputs
            w.sim.readOutputs = function(self)
                local o = raw(self)
                if swap_lr then o.FL, o.FR, o.RL, o.RR = o.FR, o.FL, o.RR, o.RL end
                if swap_fb then o.FL, o.RL, o.FR, o.RR = o.RL, o.FL, o.RR, o.FR end
                return o
            end
        end
        w:tap("SPACE")
        w:run(80)
        w.sim.w.x = math.rad(2) -- a roll kick after the check
        local late = 0
        w:run(60, function(w) if w.t > 110 then local _, p, r = w.sim:attitude(); late = math.max(late, math.abs(r), math.abs(p)) end end)
        return w.fl.ctl, late
    end
    local c, late = flight(false, false)
    print(string.format("dircheck correct: roll %+d pitch %+d known %s/%s late %.2f", c.roll_sign, c.pitch_sign, tostring(c.roll_known), tostring(c.pitch_known), late))
    check("dircheck: correct wiring kept", c.roll_sign == 1 and c.pitch_sign == 1)
    check("dircheck: both axes checked", (c.roll_known or 0) > 0 and (c.pitch_known or 0) > 0)
    check("dircheck: steady after", late < 3, f(late))
    c, late = flight(true, false)
    print(string.format("dircheck L/R swapped: roll %+d pitch %+d late %.2f", c.roll_sign, c.pitch_sign, late))
    check("dircheck: reversed roll detected", c.roll_sign == -1 and c.pitch_sign == 1)
    check("dircheck: steady after fixing roll", late < 3, f(late))
    c, late = flight(false, true)
    print(string.format("dircheck F/B swapped: roll %+d pitch %+d late %.2f", c.roll_sign, c.pitch_sign, late))
    check("dircheck: reversed pitch detected", c.pitch_sign == -1 and c.roll_sign == 1)
    check("dircheck: steady after fixing pitch", late < 3, f(late))
end

-- 14. The real ship's control loop runs every ~0.2 s (each Sable call waits
--     for the game). The controller must use the real tick length: v2.9 to
--     v2.20 assumed 0.05 s, read turn rates ~4x too big and swung itself
--     over (reproduced here with fake_dt).
do
    local function kick(opts)
        local w = World.new(opts):airborne(120, 0)
        w.fl.ctl.roll_known, w.fl.ctl.pitch_known = 1, 1
        w.sim.w.x = math.rad(10)
        local late = 0
        w:run(60, function(w)
            local _, p, r = w.sim:attitude()
            if w.t > 40 then late = math.max(late, math.abs(p), math.abs(r)) end
        end)
        return late, w
    end
    local ok_late, w = kick({ loop_ticks = 4, sim = { prop_tau = 1.0 } })
    local bad_late = kick({ loop_ticks = 4, fake_dt = 0.05, sim = { prop_tau = 1.0 } })
    print(string.format("slow loop: real dt late %.2f deg, fixed 0.05 s late %.1f deg", ok_late, bad_late))
    check("slow loop: steady with the real tick length", ok_late < 2, f(ok_late))
    check("slow loop: the old fixed 0.05 s reproduces the swing", bad_late > 20, f(bad_late))
    -- turn rate from a 0.2 s tick is the real rate
    local w2 = World.new({ loop_ticks = 4 }):airborne(120, 0)
    w2.sim.w.y = math.rad(-10) -- body yaw (sim sign: - = heading increasing)
    w2.fl.calib = nil
    w2:run(0.6) -- three ticks: the estimate has caught up, no tilt acted yet
    local truth = -math.deg(w2.sim.w.y)
    check("slow loop: yaw rate read at its real size", math.abs(w2.fl.est.s.yaw_rate - truth) < 1.5,
        f(w2.fl.est.s.yaw_rate) .. " vs " .. f(truth))
end

-- 15. Autopilot order: climb first (heading left alone), turn up there,
--     then go. A waypoint right BEHIND the ship must not leave it flapping
--     between "turn left" and "turn right" (v2.21 flight: stuck facing away).
do
    local w = World.new():airborne(90, 0)
    w.fl.ctl.roll_known, w.fl.ctl.pitch_known = 1, 1
    w.fl.calib = nil
    -- point due south (behind, 180 deg) and a bit east
    w:startAP({ name = "BEHIND", x = 3, z = 400, heading = 90 })
    local turned_low, turn_alt, reached_cruise, flips, last_dir = false, nil, false, 0, nil
    w:run(240, function(w)
        local ap, t = w.fl.ap, w:truth()
        if not ap then return true end
        if ap.phase == "depart" and math.abs(U.wrap180(t.heading - 0)) > 15 then turned_low = true end
        if ap.phase == "turn" and not turn_alt then turn_alt = t.alt end
        if ap.phase == "turn" then
            local d = w.fl.turn_dir
            -- flips while the point is still well behind (the small correction
            -- at the end of the turn is fine)
            if d and last_dir and d ~= last_dir and math.abs(ap.herr or 0) > 120 then flips = flips + 1 end
            last_dir = d or last_dir
        end
        if ap.phase == "cruise" then reached_cruise = true return true end
    end)
    print(string.format("ap order: turned while climbing=%s turn started at alt %.1f (goal %.1f) dir flips %d cruise=%s",
        tostring(turned_low), turn_alt or -1, w.fl.ap and w.fl.ap.goal_alt or -1, flips, tostring(reached_cruise)))
    check("ap order: no turning during the climb", not turned_low)
    check("ap order: turns at the travel altitude", turn_alt and w.fl.ap and math.abs(turn_alt - w.fl.ap.goal_alt) < 4.5, f(turn_alt or -1))
    check("ap order: waypoint behind = one steady turn", flips == 0, flips)
    check("ap order: faces it and cruises", reached_cruise)
end

-- 16. Cruise steers by banking only (never prop tilt at speed: the fin
--     turns tilt kicks into roll and pitch), and the fixed-speed altitude
--     hold settles a climb without the props swinging.
do
    local w = World.new({ loop_ticks = 3 }):airborne(150, 0)
    w.fl.ctl.roll_known, w.fl.ctl.pitch_known = 1, 1
    w.fl.calib = nil
    w.fl:setMode("cruise")
    w.fl.rear_target = 10
    w:run(30)
    w.fl.heading_target = 40
    local tilt_ticks, maxatt = 0, 0
    w:run(90, function(w)
        local o = w.sim:readOutputs()
        if o.FL_tilt ~= 0 or o.FR_tilt ~= 0 or o.RL_tilt ~= 0 or o.RR_tilt ~= 0 then tilt_ticks = tilt_ticks + 1 end
        local t = w:truth()
        maxatt = math.max(maxatt, math.abs(t.roll), math.abs(t.pitch))
    end)
    local hdg = w:truth().heading
    print(string.format("bank turn: heading %.1f (want 40), tilt ticks %d, max attitude %.1f", hdg, tilt_ticks, maxatt))
    check("bank turn: no prop tilt in cruise", tilt_ticks == 0, tilt_ticks)
    check("bank turn: reaches the heading", math.abs(U.wrap180(hdg - 40)) < 5, f(hdg))
    check("bank turn: gentle (attitude < 8 deg)", maxatt < 8, f(maxatt))

    -- climb 60 m on a fixed prop speed: no bounce, props steady once there
    local w2 = World.new({ loop_ticks = 3 }):airborne(120, 0)
    w2.fl.ctl.roll_known, w2.fl.ctl.pitch_known = 1, 1
    w2.fl.calib = nil
    local peak, lmin, lmax = 0, 99, 0
    w2:run(120, function(w)
        w.fl.alt_target = 180 -- the pilot keeps a target within 15 m: re-ask
        local t = w:truth()
        peak = math.max(peak, t.alt)
        if w.t > 80 then
            local l = w.fl.levels.FL or 0
            lmin, lmax = math.min(lmin, l), math.max(lmax, l)
        end
    end)
    local alt = w2:truth().alt
    print(string.format("throttle hold: alt %.1f (want 180) peak %.1f, prop levels %d..%d at the end", alt, peak, lmin, lmax))
    check("throttle hold: arrives within 3 m", math.abs(alt - 180) < 3, f(alt))
    check("throttle hold: no big overshoot (< 4 m)", peak < 184, f(peak))
    check("throttle hold: props steady (one level of dither)", lmax - lmin <= 1, lmin .. ".." .. lmax)
end

-- 17. Landing leans gently against sideways drift (v2.23 flight: landed
--     ~100 m off sliding sideways at ~2 m/s all the way down).
do
    local function land(lat)
        local w = World.new({ loop_ticks = 3, tune = { hover = { lat_gain = lat } } }):airborne(100, 0)
        w.fl.ctl.roll_known, w.fl.ctl.pitch_known = 1, 1
        w.fl.calib = nil
        w.sim.vel.x = 3 -- sliding to the right
        w.fl:beginLanding({})
        local x0, maxr = w.sim.pos.x, 0
        w:run(120, function(w)
            local _, _, r = w.sim:attitude()
            maxr = math.max(maxr, math.abs(r))
            return w.fl.phase ~= "landing"
        end)
        return w.sim.pos.x - x0, maxr
    end
    local off = land(0)
    local d, maxr = land(1.0)
    print(string.format("landing drift: %.1f m with the lean (%.1f m without), max roll %.1f", d, off, maxr))
    check("landing drift: lean cuts the slide to under half", d < off / 2, f(d))
    check("landing drift: only a little roll (< 4 deg)", maxr < 4, f(maxr))
end

-- 18. The ship measures the air it flies in (servers set very different
--     atmospheres). First flight in each world, default assumptions:
--     thick air that reaches high = it climbs on to the full Y270;
--     thin air = it finds the real ceiling and travels under it.
do
    local function first_trip(press_k, hover)
        local w = World.new({ loop_ticks = 3, sim = { press_k = press_k, hover = hover } }):airborne(100, 0)
        w.fl.ctl.roll_known, w.fl.ctl.pitch_known = 1, 1
        w.fl.calib = nil
        w:startAP({ name = "FAR", x = 0, z = -3000, heading = 0 })
        w:run(400, function(w) return w.fl.ap and w.fl.ap.phase == "cruise" and w.fl.ap.pt > 20 end)
        return w
    end
    local w = first_trip(0.0015, 4)
    local ap, pts = w.fl.ap, w.fl.atmos:points()
    print(string.format("air thick: %s, cruising at Y%.0f", w.fl.atmos:summary(), w:truth().alt))
    check("air thick: reached cruise", ap and ap.phase == "cruise")
    check("air thick: travels at the default Y270", math.abs(w:truth().alt - 270) < 6, f(w:truth().alt))
    check("air thick: trend measured", pts.measured and math.abs(pts.k - 0.0015) < 0.0005, f(pts.k))
    check("air thick: hover speed measured", math.abs(w.fl.atmos:hoverAt(63) - 4) < 0.3, f(w.fl.atmos:hoverAt(63)))

    w = first_trip(0.008, 6)
    ap, pts = w.fl.ap, w.fl.atmos:points()
    -- true ceiling with 3.5 prop units spare: 63 + ln(11.5/6)/0.008 = Y144
    print(string.format("air thin: %s, cruising at Y%.0f", w.fl.atmos:summary(), w:truth().alt))
    check("air thin: reached cruise (no timeout)", ap and ap.phase == "cruise")
    check("air thin: travels under the real ceiling", w:truth().alt < 148 and w:truth().alt > 120, f(w:truth().alt))
    check("air thin: trend measured", pts.measured and math.abs(pts.k - 0.008) < 0.002, f(pts.k))

    -- the measured air survives a restart
    local A = require("atmos")
    local b = A.new(w.tune, 6)
    check("air: saved and loaded", b:fromTable(w.fl.atmos:toTable()) and math.abs(b:hoverAt(140) - w.fl.atmos:hoverAt(140)) < 1e-6)
end

-- 19. FLY from the ground climbs at once (v2.26 flight: it hovered a
--     minute waiting for the direction check, which never finished).
do
    local w = World.new({ loop_ticks = 3 }) -- parked, directions not checked
    local alt0 = w:truth().alt
    w:startAP({ name = "FAR", x = 0, z = -3000, heading = 0 })
    w:run(15)
    local up = w:truth().alt - alt0
    print(string.format("fly from ground: %.1f m up after 15 s (phase %s)", up, w.fl.ap and w.fl.ap.phase or "-"))
    check("fly from ground: climbing within 15 s (> 25 m)", up > 25, f(up))
end

-- 20. Arrival (v2.30 flight): the fixed-speed hold settled 4.6 m under the
--     travel altitude and the re-aim waited for "within 4 m" forever; and
--     a ship that stops making progress short of the point gets level-1
--     rear nudges until it arrives.
do
    -- hold settles ~6 m low (sim needs 6.15, the ship believes 6; learning off)
    local w = World.new({ loop_ticks = 3, sim = { hover = 6.15 }, tune = { vertical = { hover_learn = false } } }):airborne(190, 0)
    w.fl.ctl.roll_known, w.fl.ctl.pitch_known = 1, 1
    w.fl.calib = nil
    w:startAP({ name = "SIDE", x = 0, z = -800, heading = 0 })
    local left_depart = w:run(120, function(w) return w.fl.ap and w.fl.ap.phase ~= "depart" end)
    print(string.format("settled low: left depart=%s at t=%.0f (alt %.1f, goal %.1f)", tostring(left_depart), w.t,
        w:truth().alt, w.fl.ap and w.fl.ap.goal_alt or -1))
    check("settled low: depart does not hang", left_depart)

    -- re-aim after a near miss goes straight to the turn
    local w2 = World.new({ loop_ticks = 3 }):airborne(150, 0)
    w2.fl.ctl.roll_known, w2.fl.ctl.pitch_known = 1, 1
    w2.fl.calib = nil
    local ap = w2:startAP({ name = "NEAR", x = 15, z = -10, heading = 0 })
    ap.retries = 1
    w2:run(1)
    check("re-aim: no altitude wait", ap.phase ~= "depart", ap.phase)

    -- no speed control at all near the point: only the nudges can move it
    local w3 = World.new({ loop_ticks = 3, tune = { autopilot = { speed_gain = 0, speed_int = 0 } } }):airborne(150, 0)
    w3.fl.ctl.roll_known, w3.fl.ctl.pitch_known = 1, 1
    w3.fl.calib = nil
    w3:startAP({ name = "AHEAD", x = 0, z = -45, heading = 0 })
    local max_rear, nudged = 0, false
    w3:run(300, function(w)
        max_rear = math.max(max_rear, w.fl.rear or 0)
        if w.fl.ap and w.fl.ap.nudging then nudged = true end
        return w.fl.ap and (w.fl.ap.phase == "stop" or w.fl.ap.phase == "align" or w.fl.ap.phase == "land")
    end)
    local d = math.sqrt(w3:truth().x ^ 2 + (w3:truth().z + 45) ^ 2)
    print(string.format("nudges: nudged=%s, %.1f m from the point, max rear level %.1f, phase %s", tostring(nudged), d,
        max_rear, w3.fl.ap and w3.fl.ap.phase or "-"))
    check("nudges: used", nudged)
    check("nudges: get it to the point (< 8 m)", d < 8, f(d))
    check("nudges: only level 1", max_rear <= 1.01, f(max_rear))
end

-- 21. Autopilot gear: up once the ground is out of sensor range, down
--     again for the landing; never up while the ground is in range.
do
    local w = World.new({ loop_ticks = 3 })
    local ground = w:truth().alt
    w:startAP({ name = "GEAR", x = 0, z = -350, heading = 0 })
    local went_up, up_low, up_alt = false, false, nil
    local landed_down = nil
    w:run(400, function(w)
        if not w.fl.gear_down then
            if not went_up then up_alt = w:truth().alt - ground end
            went_up = true
            if (w.fl.prox or 0) > 0 then up_low = true end
        end
        if w.fl.phase == "parked" and w.t > 20 then
            landed_down = w.fl.gear_down
            return true
        end
    end)
    print(string.format("ap gear: up=%s first up %.0f m above ground, up while ground in range=%s, landed with gear down=%s",
        tostring(went_up), up_alt or -1, tostring(up_low), tostring(landed_down)))
    check("ap gear: raised in flight", went_up)
    check("ap gear: only once clear of the ground (> 14 m)", up_alt and up_alt > 14, f(up_alt or -1))
    check("ap gear: never up with ground in range", not up_low)
    check("ap gear: down for touchdown", landed_down == true, tostring(landed_down))
end

-- 22. Long trips (v2.34 flight): the rear sat at 11-12 holding a 40 m/s
--     cap, and the autopilot cut itself off 240 s into every long cruise.
do
    local w = World.new({ loop_ticks = 3 }):airborne(200, 0)
    w.fl.ctl.roll_known, w.fl.ctl.pitch_known = 1, 1
    w.fl.calib = nil
    w:startAP({ name = "FAR", x = 0, z = -60000, heading = 0 })
    local cruise_t, full_t, vmax, pre_t = 0, 0, 0, 0
    w:run(420, function(w)
        local ap = w.fl.ap
        if ap and ap.phase == "cruise" then
            cruise_t = cruise_t + 0.15
            -- before the planned braking for arrival (speed plan above speed)
            if (ap.v_sp or 0) > w.fl.est.s.u + 2 then
                pre_t = pre_t + 0.15
                if (w.fl.rear or 0) >= 14.99 then full_t = full_t + 0.15 end
            end
        end
        vmax = math.max(vmax, w:truth().speed)
    end)
    local ap = w.fl.ap
    print(string.format("long trip: still flying=%s phase %s, cruise %.0f s, rear at 15 for %.0f s, top speed %.0f m/s",
        tostring(ap ~= nil), ap and ap.phase or "-", cruise_t, full_t, vmax))
    check("long trip: no timeout after 240 s of cruise", ap ~= nil and ap.phase == "cruise" and cruise_t > 300, f(cruise_t))
    check("long trip: rear at full thrust (15) until braking", pre_t > 100 and full_t > pre_t * 0.9,
        string.format("%.0f of %.0f s", full_t, pre_t))
    check("long trip: faster than the old 40 m/s cap", vmax > 45, f(vmax))

    -- a cruise that makes no progress still gives up
    local w2 = World.new({ loop_ticks = 3, tune = { autopilot = { speed_gain = 0, speed_int = 0, nudge_after = 1e9 } } }):airborne(200, 0)
    w2.fl.ctl.roll_known, w2.fl.ctl.pitch_known = 1, 1
    w2.fl.calib = nil
    w2:startAP({ name = "STUCK", x = 0, z = -3000, heading = 0 })
    local gave_up = w2:run(300, function(w) return w.fl.ap == nil end)
    check("stalled cruise still times out", gave_up, f(w2.t))
end

print(string.format("v2_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_test FAILED", 0) end
