-- Vertical-axis regression test: the REAL lib/flight.lua + lib/pid.lua
-- driving a point-mass plant that mirrors ship physics (README/wiki):
--
--   pressure(h) = e^(-0.004 * (h - 63))          -- thrust falls with height
--   thrust_frac = pressure * (cmd / hover_throttle) * (1 - v / 25)
--   a = (thrust_frac - 1) * g,   g = 11          -- cmd = mean prop speed 0..15
--
-- The controller must: hold a hover, track altitude steps with bounded
-- overshoot, reject a vertical disturbance, and never exceed the physical
-- ceiling (~y293: where max cmd 15 no longer beats gravity).
--
-- Run from repo root: lua5.4 tests/vertical_test.lua
-- (also runs via tests/run.py under lupa)

package.path = "./?.lua;" .. package.path

local Flight = dofile("lib/flight.lua")
local cfg = dofile("config/atlas.lua")

local G = (cfg.physics and cfg.physics.gravity) or 11
local PRESS_K, PRESS_REF, AIRFLOW = 0.004, 63, 25
local DT = cfg.tick_rate or 0.05
local HOVER_T = (cfg.limits and cfg.limits.hover_throttle) or 6

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL: %s%s", name,
            detail ~= nil and (" -- " .. tostring(detail)) or ""))
    end
end

local function finite(x)
    return x == x and x > -1e9 and x < 1e9
end

local function makeEnv(alt0, prox0, nose_up_D)
    local plant = {
        alt = alt0, v = 0,
        pitch = 0, pitch_rate = 0,
        -- Constant nose-up disturbance (deg/s^2): gravity on an off-centre
        -- hull. The pitch channel is deliberately the REAL physics:
        --   pitch'' = pressure(alt) * den(v) * (rear - front) - D
        -- so attitude authority scales exactly like the wiki thrust term.
        D = nose_up_D or 0,
        cmd = 0, prox = prox0 or 0,
        props = { FL = 0, FR = 0, RL = 0, RR = 0 },
        creep = (cfg.limits and cfg.limits.landed_creep) or 1,
    }
    local state = {
        altitude = alt0, pitch = 0, roll = 0, yaw = 0,
        speed = 0, climb_rate = 0,
        velocity = { x = 0, y = 0, z = 0 },
        forward = { x = 0, y = 0, z = 1 },
        position = { x = 0, y = alt0, z = 0 },
        angularVelocity = { x = 0, y = 0, z = 0 },
    }
    local hw = {}
    function hw.getShipState() return state end
    function hw.getProximity() return plant.prox end
    function hw.hasFeature(name) return not not cfg.features[name] end
    function hw.setGear() end
    function hw.setLiftReverse() end
    function hw.setRearOutput() end
    function hw.setRearReverse() end
    function hw.setPropellerOutput(prop, channel, value)
        if channel == "speed" then plant.props[prop] = value or 0 end
    end
    function hw.cutAllOutputs()
        plant.props.FL, plant.props.FR = 0, 0
        plant.props.RL, plant.props.RR = 0, 0
    end

    local flight = Flight.new(cfg, hw)
    flight.targets.altitude = alt0
    flight:captureHeading()

    local env = { flight = flight, plant = plant, state = state }
    function env.step()
        flight:update()
        local p = plant.props
        plant.cmd = (p.FL + p.FR + p.RL + p.RR) / 4
        local grounded = plant.prox
            >= ((cfg.proximity and cfg.proximity.landed_threshold) or 15)
        -- pitch channel (skipped when grounded: rigid hull)
        if not grounded then
            local front = (p.FL + p.FR) / 2
            local rear = (p.RL + p.RR) / 2
            local denp = 1 - plant.v / AIRFLOW
            if denp < 0.25 then denp = 0.25 end
            local pres = math.exp(-PRESS_K * (plant.alt - PRESS_REF))
            -- front < rear (front reduced) -> nose-down torque (pitch+)
            plant.pitch_rate = plant.pitch_rate
                + (pres * denp * (rear - front) - plant.D) * DT
            plant.pitch = plant.pitch + plant.pitch_rate * DT
            if plant.pitch > 60 then plant.pitch, plant.pitch_rate = 60, 0 end
            if plant.pitch < -60 then plant.pitch, plant.pitch_rate = -60, 0 end
            state.pitch = plant.pitch
            state.pitch_rate = plant.pitch_rate
            -- updateState reads pitch_rate as -rateDps(av.z): feed rad/s
            state.angularVelocity.z = -plant.pitch_rate * math.pi / 180
        end
        if grounded then
            plant.v = 0 -- resting on the ground: rigid
            return plant.cmd
        end
        local den = 1 - plant.v / AIRFLOW
        if den < 0.25 then den = 0.25 end
        local frac = math.exp(-PRESS_K * (plant.alt - PRESS_REF))
            * (plant.cmd / HOVER_T) * den
        local a = (frac - 1) * G
        plant.v = plant.v + a * DT
        plant.alt = plant.alt + plant.v * DT
        state.altitude = plant.alt
        state.climb_rate = plant.v
        state.velocity.z = plant.v
        state.position.y = plant.alt
        return plant.cmd
    end
    return env
end

-- 1. Hover hold: start on target, stay there for 30 s
local e1 = makeEnv(150)
local max_cmd, min_cmd, bad = -1e9, 1e9, false
for _ = 1, 600 do
    local cmd = e1.step()
    max_cmd = math.max(max_cmd, cmd)
    min_cmd = math.min(min_cmd, cmd)
    if not (finite(e1.plant.alt) and finite(e1.plant.v) and finite(cmd)) then
        bad = true
    end
end
check("hover: finite", not bad)
check("hover: altitude held", math.abs(e1.plant.alt - 150) <= 3.0,
    string.format("alt=%.2f", e1.plant.alt))
check("hover: climb quiet", math.abs(e1.plant.v) <= 1.5,
    string.format("v=%.2f", e1.plant.v))
check("hover: cmd in range", min_cmd >= 0 and max_cmd <= 15,
    string.format("%.2f..%.2f", min_cmd, max_cmd))

-- 2. Step up 30 m: must arrive, bounded overshoot, bounded climb rate
e1.flight.targets.altitude = 180
local peak, vpeak = e1.plant.alt, 0
for _ = 1, 600 do
    e1.step()
    peak = math.max(peak, e1.plant.alt)
    vpeak = math.max(vpeak, e1.plant.v)
end
check("step up: reaches target", math.abs(e1.plant.alt - 180) <= 4.0,
    string.format("alt=%.2f", e1.plant.alt))
check("step up: overshoot <= 8m", peak <= 188,
    string.format("peak=%.2f", peak))
check("step up: climb rate bounded", vpeak <= 12,
    string.format("vmax=%.2f", vpeak))

-- 3. Step back down: arrives without deep undershoot
e1.flight.targets.altitude = 150
local trough = e1.plant.alt
for _ = 1, 600 do
    e1.step()
    trough = math.min(trough, e1.plant.alt)
end
check("step down: reaches target", math.abs(e1.plant.alt - 150) <= 4.0,
    string.format("alt=%.2f", e1.plant.alt))
check("step down: undershoot <= 8m", trough >= 142,
    string.format("min=%.2f", trough))

-- 4. Disturbance: 4 m/s downward kick at steady hover, must recover
local e2 = makeEnv(150)
for _ = 1, 400 do e2.step() end
e2.plant.v = -4
for _ = 1, 400 do e2.step() end
check("disturbance: altitude recovered", math.abs(e2.plant.alt - 150) <= 4.0,
    string.format("alt=%.2f", e2.plant.alt))
check("disturbance: velocity settled", math.abs(e2.plant.v) <= 2.0,
    string.format("v=%.2f", e2.plant.v))

-- 5. Ceiling: unreachable target -> physical limit, never past ~y300
local e3 = makeEnv(260)
e3.flight.targets.altitude = 500
local over = false
for _ = 1, 1500 do
    e3.step()
    if not finite(e3.plant.alt) or e3.plant.alt > 296 then over = true end
end
check("ceiling: never exceeds ~y293", not over,
    string.format("alt=%.2f", e3.plant.alt))
check("ceiling: still climbed toward ceiling", e3.plant.alt >= 270,
    string.format("alt=%.2f", e3.plant.alt))

-- 6. Grounded: proximity latches landed -> landed-idle creep, level outputs
local e4 = makeEnv(8, 15)
for _ = 1, 80 do e4.step() end
check("grounded: landed latched", e4.flight.landed == true)
check("grounded: idle creep", math.abs((e4.plant.props.FL or -1) - e4.plant.creep) < 0.01,
    string.format("FL=%.2f creep=%.2f", e4.plant.props.FL or -1, e4.plant.creep))
check("grounded: props level",
    e4.plant.props.FL == e4.plant.props.FR
    and e4.plant.props.FR == e4.plant.props.RL
    and e4.plant.props.RL == e4.plant.props.RR)

-- 7. Pitch trim: constant nose-up disturbance (off-centre hull) at hover
--    must be held at a small bounded mean error (stepped cap + pulse duty).
local e5 = makeEnv(150, 0, 1.0)
local sum, n = 0, 0
for i = 1, 600 do
    e5.step()
    if i > 300 then
        sum = sum + math.abs(e5.plant.pitch)
        n = n + 1
    end
end
local hover_mean = sum / n
check("pitch hover: bounded trim", hover_mean >= 0.5 and hover_mean <= 6,
    string.format("mean %.2f deg", hover_mean))

-- 8. Closed-loop climb sanity: the ship must actually climb with the
--    disturbance active, and pitch must stay bounded throughout (the
--    authority-ratio property is asserted directly in check 9 — closed-
--    loop ratios are limit-cycle-phase dependent and flaky across Lua
--    interpreters).
e5.flight.targets.altitude = 285
local climb_sum, climb_n, max_alt = 0, 0, 150
for _ = 1, 600 do
    e5.step()
    max_alt = math.max(max_alt, e5.plant.alt)
    if e5.plant.alt >= 160 and e5.plant.alt <= 240 then
        climb_sum = climb_sum + math.abs(e5.plant.pitch)
        climb_n = climb_n + 1
    end
end
local climb_mean = climb_sum / math.max(1, climb_n)
print(string.format("pitch: hover-mean=%.2f deg, climb-mean=%.2f deg, max_alt=%.1f",
    hover_mean, climb_mean, max_alt))
check("pitch: actually climbed", max_alt >= 205, string.format("max_alt=%.1f", max_alt))
check("pitch: bounded during climb", climb_mean <= 6,
    string.format("climb mean %.2f deg", climb_mean))

-- 9. Scheduling invariant (regression for the kh/den fix): freeze a pitch
--    error outside the deadband (band-2: small enough that base_speed -
--    p_front never floor-clips, which would saturate the measurement) and
--    average the command DIFF over many duty periods at v=0 vs a v=8
--    climb. The delivered moment is pressure * den * diff; pressure is
--    identical in both cases (same altitude), so with correct scheduling
--     den * diff  must come out EQUAL (diff grows by 1/den while the plant
--    loses den). Without the /den term the climb case delivers only
--    den=0.68x of the moment — exactly the "noses up on the climb and
--    never corrects" bug. The duty phase train is identical in both
--    cases, so the ratio is deterministic to float precision.
local e6 = makeEnv(150, 0, 0)
local fl6 = e6.flight
fl6.landed = false
fl6.state = e6.state -- Flight.new caches its own copy; point it at ours
local function meanDiff(climb_rate)
    local acc, m, min_fl = 0, 0, 15
    for i = 1, 800 do
        e6.state.climb_rate = climb_rate
        e6.state.pitch = -3.5
        e6.state.pitch_rate = 0
        e6.state.speed = 0
        fl6:updateHover(0.05)
        if i > 200 then
            local o = fl6.outputs
            local front = ((o.FL_speed or 0) + (o.FR_speed or 0)) / 2
            local rear = ((o.RL_speed or 0) + (o.RR_speed or 0)) / 2
            acc = acc + math.abs(front - rear)
            m = m + 1
            if (o.FL_speed or 0) < min_fl then min_fl = o.FL_speed end
        end
    end
    return acc / m, min_fl, fl6.outputs.speed
end
local diff_hover, min_fl_h, base_h = meanDiff(0)
local diff_climb, min_fl_c, base_c = meanDiff(8)
local den_climb = 1 - 8 / AIRFLOW
local ratio = (den_climb * diff_climb) / diff_hover
print(string.format("sched: diff_hover=%.3f diff_climb=%.3f moment-ratio=%.3f (base %.2f/%.2f, minFL %.2f/%.2f)",
    diff_hover, diff_climb, ratio, base_h, base_c, min_fl_h, min_fl_c))
check("sched: diff nonzero", diff_hover > 1,
    string.format("diff_hover=%.3f", diff_hover))
check("sched: no floor clip", min_fl_h > 0.5 and min_fl_c > 0.5,
    string.format("min_fl %.2f/%.2f", min_fl_h, min_fl_c))
check("sched: climb moment invariance", ratio >= 0.85 and ratio <= 1.15,
    string.format("ratio=%.3f (broken code gives ~0.68)", ratio))

-- 10. AT CRUISE ALTITUDE THE VERTICAL LOOP IS THRUST-LIMITED, NOT GAIN-LIMITED.
--
-- Reported in-game: during FAST TRAVEL the ship fell ~210 blocks under its
-- altitude goal and "did not react". The instinct is to turn the altitude PID
-- up. Measured here, that does nothing at all, and this block exists to stop
-- the next person spending a day on it.
--
-- Why. Holding level needs cmd = hover_throttle * e^(k*(h-63)), so at the
-- ceiling the props are already commanded to ~13 of a hard maximum of 15 --
-- the ceiling discovery stops the climb at props=13, so the leftover margin
-- IS the 2 units by definition. The vertical loop's usable authority is
-- therefore
--     accel = g * (hmax / hover_cmd - 1)
-- which is a property of the ALTITUDE and the 15-unit hardware ceiling, not
-- of any gain. Meanwhile the P term saturates at output_limit once the error
-- passes output_limit/kp (~20 blocks), and updateCruise's
-- clamp(hover + out, hmin, hmax) then throws the surplus away. So for any
-- error over ~20 blocks the command is already pinned at hmax and every gain
-- in the PID produces the identical number.
do
    local hmax = (cfg.limits and cfg.limits.hover_max_speed) or 15
    local CEIL_LIFT = 13 -- AP_CEIL_LIFT: where the probe stops the climb
    -- the altitude at which holding level needs exactly CEIL_LIFT of props
    local opalt = PRESS_REF + math.log(CEIL_LIFT / HOVER_T) / PRESS_K
    local hover_at_op = HOVER_T * math.exp(PRESS_K * (opalt - PRESS_REF))
    local margin = hmax - hover_at_op
    local accel = G * (hmax / hover_at_op - 1)

    print(string.format("authority: opalt=%.1f hover=%.2f margin=%.2f accel=%.2f m/s^2 (sea level %.2f)",
        opalt, hover_at_op, margin, accel,
        G * (hmax / HOVER_T - 1)))

    -- Command the cruise law directly at a given gain / altitude / error and
    -- read the prop command back. PID.new copies its gains, so the flight has
    -- to be built AFTER the config is poked.
    local function cruiseCmd(kp, alt, err, v)
        local save = cfg.pid.altitude.kp
        cfg.pid.altitude.kp = kp
        local e = makeEnv(alt)
        e.flight:setMode(Flight.MODE_CRUISE)
        e.flight.state = e.state          -- Flight.new caches its own copy
        e.state.altitude = alt
        e.plant.alt = alt
        e.state.climb_rate = v or 0
        e.flight.targets.altitude = alt + err
        e.flight:updateCruise(DT)
        local cmd = e.flight.outputs.speed
        cfg.pid.altitude.kp = save
        return cmd
    end

    local kp0 = cfg.pid.altitude.kp
    local olim = cfg.pid.altitude.output_limit
    local sat_err = olim / kp0   -- error at which P alone hits output_limit

    check("authority: the ceiling leaves only ~2 prop units of margin",
        margin > 1.5 and margin < 2.5, string.format("margin=%.2f", margin))
    check("authority: that margin is a real but feeble 1.7 m/s^2",
        accel > 1.2 and accel < 2.5, string.format("accel=%.2f", accel))
    -- P saturates early: this is the whole reason gains stop mattering.
    check("authority: P saturates by ~20 blocks of error",
        sat_err > 5 and sat_err < 30, string.format("sat_err=%.1f", sat_err))
    -- The demand the law computes is genuinely larger than the ship can give.
    check("authority: the hmax clamp really does discard surplus demand",
        cruiseCmd(kp0, opalt, 210) == hmax,
        string.format("cmd=%.2f hmax=%.2f", cruiseCmd(kp0, opalt, 210), hmax))

    -- THE finding: gains are a no-op here. 100x kp must not move the command.
    local c_lo = cruiseCmd(kp0, opalt, 210)
    local c_hi = cruiseCmd(kp0 * 100, opalt, 210)
    check("authority: kp x100 leaves the command BIT-IDENTICAL (kp is not the lever)",
        c_lo == c_hi, string.format("kp=%.2f -> %.4f, kp=%.0f -> %.4f",
            kp0, c_lo, kp0 * 100, c_hi))
    check("authority: a 50-block and a 210-block error command the same thing",
        cruiseCmd(kp0, opalt, 50) == cruiseCmd(kp0, opalt, 210),
        string.format("50->%.4f 210->%.4f",
            cruiseCmd(kp0, opalt, 50), cruiseCmd(kp0, opalt, 210)))

    -- End to end: recovery from the reported fault is thrust-bound, so kp x100
    -- must not make it any quicker. This is the assertion that actually
    -- captures the operator's complaint.
    local function recover210(kp)
        local save = cfg.pid.altitude.kp
        cfg.pid.altitude.kp = kp
        local e = makeEnv(opalt)
        e.flight:setMode(Flight.MODE_CRUISE)
        e.flight.state = e.state
        e.flight.targets.altitude = opalt
        for _ = 1, 80 do e.step() end      -- settle on altitude
        e.state.altitude = opalt - 210
        e.plant.alt = opalt - 210
        e.plant.v = 0
        for i = 1, 1200 do
            e.step()
            if math.abs(e.plant.alt - opalt) <= 5 then
                cfg.pid.altitude.kp = save
                return i * DT
            end
        end
        cfg.pid.altitude.kp = save
        return nil
    end
    local t_lo, t_hi = recover210(kp0), recover210(kp0 * 100)
    print(string.format("recover 210 blocks: kp=%.2f -> %.1fs, kp=%.0f -> %s",
        kp0, t_lo or -1, kp0 * 100, t_hi and string.format("%.1fs", t_hi) or "NEVER"))
    check("authority: recovery from 210 under is finite (ship does come back)",
        t_lo ~= nil, string.format("t=%s", tostring(t_lo)))
    check("authority: kp x100 does NOT speed up recovery (thrust-bound)",
        t_lo ~= nil and t_hi ~= nil and math.abs(t_hi - t_lo) < 0.6,
        string.format("%.1fs vs %.1fs", t_lo or -1, t_hi or -1))
    -- Free-body check: all 15 units of thrust at the ceiling is the ceiling of
    -- what this ship can do, and the acceleration must match the closed form.
    local acc_meas = (function()
        local e = makeEnv(opalt)
        e.flight:setMode(Flight.MODE_CRUISE)
        e.flight.state = e.state
        e.state.altitude, e.plant.alt = opalt, opalt
        e.state.climb_rate = 0
        e.flight.targets.altitude = opalt
        for _ = 1, 40 do e.step() end
        local p = e.plant.props
        for _, k in ipairs({ "FL", "FR", "RL", "RR" }) do p[k] = hmax end
        e.plant.cmd = hmax
        local pres = math.exp(-PRESS_K * (opalt - PRESS_REF))
        return (pres * (hmax / HOVER_T) - 1) * G
    end)()
    check("authority: full thrust at the ceiling matches the closed form",
        math.abs(acc_meas - accel) < 0.05,
        string.format("measured=%.3f closed_form=%.3f", acc_meas, accel))
end

print(string.format("vertical_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("vertical_test FAILED", 0) end
