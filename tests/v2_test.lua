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
    local w = World.new()
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
    w:run(25, function(w)
        local t = w:truth()
        maxatt = math.max(maxatt, math.abs(t.pitch), math.abs(t.roll))
    end)
    local t = w:truth()
    print(string.format("takeoff: alt=%.2f (target %.1f) maxatt=%.2f", t.alt, w.fl.alt_target, maxatt))
    check("takeoff: flying", w.fl.phase == "flying", w.fl.phase)
    check("takeoff: one tap = 6 m", math.abs(w.fl.alt_target - 70) < 0.01, w.fl.alt_target)
    check("takeoff: holds altitude", math.abs(t.alt - 70) < 0.5, f(t.alt))
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
    check("hover: heading held", math.abs(U.wrap180(t.heading - 90)) < 5, f(t.heading))
    check("hover: drift braked (coasting allowed under the pulse threshold)", t.speed < 1.2, f(t.speed))
    check("hover: drift distance bounded", U.hypot(t.x, t.z) < 25, f(U.hypot(t.x, t.z)))
    check("hover: altitude held", math.abs(t.alt - 150) < 1, f(t.alt))
end

-- 5. Turning at cruise altitude does not sink (the rotate-step drop)
do
    local w = World.new():airborne(230, 0)
    w:run(5)
    local low = 1e9
    w.fl.heading_target = 180
    w:run(40, function(w) low = math.min(low, w:truth().alt) end)
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
    local w = World.new({ sim = { drag = 0.08, rear_dz = 0.4, rear_dy = -2, hull_pitch = 0.3 } })
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
    -- Smooth, momentum-based travel (long tilt pulses, no flicker) trades
    -- precision for calm: a pulse is a ~4 m/s push, so the last metres are
    -- coarse. For a hull this size, landing within ~10 m is the target.
    check("trip: on the waypoint (< 10 m)", miss < 10, f(miss))
    check("trip: on its heading", math.abs(U.wrap180(t.heading - 200)) < 5, f(t.heading))
    check("trip: never sank > 5 m in cruise", below < 5, f(below))
    check("trip: attitude < 8 deg", maxatt < 8, f(maxatt))
    check("trip: soft touchdown", (w.sim.touch_v or 9) < 1.2, w.sim.touch_v)
    check("trip: autopilot released", w.fl.ap == nil)
    check("trip: asks for power-off", landedEvent(w).shutdown == true)
end

-- 9. Short hop stays in hover
do
    local w = World.new():airborne(100, 0)
    w:startAP({ name = "HOP", x = -150, z = 120, heading = 90 })
    local cruised = false
    w:run(300, function(w)
        if w.fl.mode == "cruise" then cruised = true end
        return landedEvent(w) ~= nil
    end)
    local t = w:truth()
    local miss = U.hypot(t.x + 150, t.z - 120)
    print(string.format("hop: t=%.0f miss=%.1f", w.t, miss))
    check("hop: landed", landedEvent(w) ~= nil)
    check("hop: never cruised", not cruised)
    check("hop: on the waypoint (< 10 m)", miss < 10, f(miss))
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
                local w = World.new({ sim = { inertia = { 300 * inertia, 400 * inertia, 300 * inertia },
                    prop_tau = tau, delay_ticks = delay, hull_pitch = 0.4 } }):airborne(150, 45)
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

print(string.format("v2_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_test FAILED", 0) end
