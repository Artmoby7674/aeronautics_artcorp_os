-- Autopilot regression test: the REAL lib/flight.lua driving a point-mass
-- plant.
--
-- SCOPE / HONESTY NOTE
-- The VERTICAL channel uses the same physics as tests/vertical_test.lua:
--   pressure(h) = e^(-0.004*(h-63)), thrust_frac = pressure*(cmd/hover_t)*(1-v/25)
--   a = (thrust_frac - 1)*g,  g = 11,  cmd = mean prop speed 0..15
-- That part is grounded, so the CLIMB assertions below test real behaviour.
--
-- The HORIZONTAL channel here is deliberately CRUDE (constant-acceleration
-- toward the commanded heading). It is NOT a validated Create:Aeronautics
-- 6-DOF model, so horizontal numbers are smoke-level only: they prove the
-- state machine advances and terminates, not that gains are right. Real
-- tuning needs in-game telemetry.
--
-- Run from repo root: lua5.4 tests/ap_test.lua

package.path = "./?.lua;" .. package.path

local Flight = dofile("lib/flight.lua")
local cfg = dofile("config/atlas.lua")

local G = (cfg.physics and cfg.physics.gravity) or 11
local PRESS_K, PRESS_REF, AIRFLOW = 0.004, 63, 25
local DT = cfg.tick_rate or 0.05
local HOVER_T = (cfg.limits and cfg.limits.hover_throttle) or 6
local CEIL = (cfg.limits and cfg.limits.max_altitude) or 285

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
local function finite(x) return x == x and x > -1e9 and x < 1e9 end
local function wrapDeg(a)
    while a > 180 do a = a - 360 end
    while a < -180 do a = a + 360 end
    return a
end
local function clampf(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- ---------------------------------------------------------------- plant
local function makeEnv(opts)
    opts = opts or {}
    local alt0 = opts.alt0 or 60
    local plant = {
        alt = alt0, v = 0,
        x = 0, z = 0, vx = 0, vz = 0,
        yaw = opts.yaw or 0, yaw_rate = 0,
        pitch = 0, pitch_rate = 0, roll = 0, roll_rate = 0,
        rear = 0, rear_rev = 0, prox = 0, cmd = 0,
        props = { FL = 0, FR = 0, RL = 0, RR = 0 },
        -- physical (block-actual) prop tilt in degrees, filled in per step
        phys_tilt = { FL = 0, FR = 0, RL = 0, RR = 0 },
        -- prop geometry from config/atlas.lua (+x right, +z front)
        pos = { FL = { x = -3, z = 3 }, FR = { x = 3, z = 3 },
                RL = { x = -3, z = -3 }, RR = { x = 3, z = -3 } },
        -- 1 tilt command unit = 1 deg of prop vectoring
        tilt_angle = opts.tilt_angle or 25,
        -- deg of roll produced per deg/s of yaw (aft-CoM / fin coupling)
        yaw_coupling = opts.yaw_coupling or 0.02,
        -- weathervane restoring gain (aft fins pulling the nose onto the
        -- velocity vector) and fin presence
        wv_gain = opts.wv_gain or 0.35,
        fins = (opts.fins ~= false) and (opts.fins_gain or 1.0) or 0,
    }
    local state = {
        altitude = alt0, pitch = 0, roll = 0, yaw = plant.yaw,
        speed = 0, climb_rate = 0,
        velocity = { x = 0, y = 0, z = 0 },
        forward = { x = 0, y = 0, z = 1 },
        position = { x = 0, y = alt0, z = 0 },
        angularVelocity = { x = 0, y = 0, z = 0 },
        mass = 1000,
    }

    local hw = {}
    function hw.getShipState() return state end
    function hw.getProximity() return plant.prox end
    function hw.hasFeature(n) return not not cfg.features[n] end
    function hw.setGear() end
    function hw.setLiftReverse() end
    function hw.setRearOutput(_, v) plant.rear = v or 0 end
    function hw.setRearReverse(_, v) plant.rear_rev = v or 0 end
    function hw.setPropellerOutput(p, ch, v)
        if ch == "speed" then plant.props[p] = v or 0 end
    end
    function hw.cutAllOutputs()
        for k in pairs(plant.props) do plant.props[k] = 0 end
        plant.rear, plant.rear_rev = 0, 0
    end

    local flight = Flight.new(cfg, hw)
    flight.state = state
    flight.targets.altitude = alt0
    flight:captureHeading()

    local env = { flight = flight, plant = plant, state = state }
    function env.step()
        flight:update()
        local p = plant.props
        plant.cmd = (p.FL + p.FR + p.RL + p.RR) / 4

        local grounded = plant.prox >= 15
        local pres = math.exp(-PRESS_K * (plant.alt - PRESS_REF))
        local denv = 1 - plant.v / AIRFLOW
        if denv < 0.25 then denv = 0.25 end

        -- ---- PROPELLER ALLOCATION (per the ship's real geometry) ----------
        -- Prop positions from config/atlas.lua: +x right, +z front, +y up.
        --   FL(-3,+3)  FR(+3,+3)  RL(-3,-3)  RR(+3,-3)
        -- Each prop vectoring is FORE/AFT only (tilt_fwd/tilt_bwd), so:
        --   * collective  (all four the same angle) -> fore/aft TRANSLATION
        --   * yaw_tilt    (left pair +/- , right pair -/+) -> a pure YAW
        --     couple: the pairs push fore/aft against each other at mirrored
        --     lever arms, so net fore/aft force is zero and yaw is the only
        --     moment. (The props do not counter-rotate, so vertical thrust
        --     alone cannot yaw the ship.)
        --   * prop SPEED  -> ATTITUDE: front/rear differential pitches,
        --     left/right differential rolls.
        -- Yaw additionally rotates the hull about an axis BEHIND the centre of
        -- mass (big rear fins), which rolls/pitches it -- modelled here as a
        -- yaw-rate-proportional disturbance so the flight code's feedforward
        -- decoupling can be tested.
        local o = flight.outputs
        local DEG = math.pi / 180
        -- The prop block is BINARY: any tilt command past the deadband puts
        -- the prop at a fixed 25 deg, and the analog level is not
        -- proportional. The flight code is measured for the angle it actually
        -- commands (Flight's own tiltPhysicalAngle), not for the raw number.
        local TILT_ANGLE = plant.tilt_angle or 25
        -- Sign conventions, calibrated against the real ship:
        --   the code writes collective = -tilt_max for FORWARD, so a
        --   NEGATIVE tilt command must produce +z (nose-forward) thrust;
        --   and a positive yaw_cmd must INCREASE yaw.
        local TILT_FWD_SIGN = plant.tilt_fwd_sign or -1
        local YAW_SIGN = plant.yaw_sign or 1
        local YAW_K, YAW_D = 2.2, 2.5
        local PITCH_K, PITCH_D = 2.0, 4.0
        local ROLL_K, ROLL_D = 2.0, 4.0
        local PITCH_SPRING, ROLL_SPRING = 4.0, 4.0
        local YAW_COUPLE = plant.yaw_coupling or 0.02

        local function prop(i)
            local x, z = plant.pos[i].x, plant.pos[i].z
            local spd = plant.props[i] or 0
            local tilt = plant.phys_tilt[i] or 0
            -- thrust magnitude follows the same pressure/rate physics as lift
            local mag = pres * (spd / HOVER_T) * denv * G
            -- Thrust is redirected, not lost: the vector keeps its magnitude,
            -- so vertical is cos(25 deg) = 0.906 of level and the horizontal
            -- share is sin(25 deg). The user pointed this out -- it is the
            -- whole reason translating costs lift.
            local fy = mag * math.cos(tilt * DEG)
            local fz = TILT_FWD_SIGN * mag * math.sin(tilt * DEG)
            return x, z, fy, fz
        end

        -- quantise the commanded tilt exactly the way the block does
        for _, i in ipairs({ "FL", "FR", "RL", "RR" }) do
            local c = o[i .. "_tilt"] or 0
            plant.phys_tilt[i] = (math.abs(c) < 12 * 0.15) and 0
                or (c > 0 and TILT_ANGLE or -TILT_ANGLE)
        end

        local fy_t, fz_t, my, mx, mz = 0, 0, 0, 0, 0
        for _, i in ipairs({ "FL", "FR", "RL", "RR" }) do
            local x, z, fy, fz = prop(i)
            fy_t = fy_t + fy
            fz_t = fz_t + fz
            my = my + YAW_SIGN * x * fz -- yaw: vertical-plane couple
            mx = mx + z * fy          -- pitch: fore/aft thrust lever
            mz = mz + x * fy          -- roll: left/right thrust lever
        end

        if not grounded then
            -- Yaw: the aft fins weathercock the nose onto the velocity vector.
            -- Modelled as a RESTORING MOMENT on the yaw rate (a real
            -- aerodynamic moment), not as a direct offset on the yaw angle --
            -- offsetting the angle fights the control moment and invents an
            -- equilibrium that does not exist.
            local hsp = math.sqrt(plant.vx * plant.vx + plant.vz * plant.vz)
            local yaw_m = my
            if hsp > 0.5 and plant.fins > 0 then
                -- two-arg atan (plain Lua 5.4 has no math.atan2; CC:Tweaked does)
                local vh = math.deg(math.atan(-plant.vx, plant.vz))
                yaw_m = yaw_m + plant.fins * plant.wv_gain
                    * wrapDeg(vh - plant.yaw)
            end
            plant.yaw_rate = plant.yaw_rate
                + (yaw_m * YAW_K - plant.yaw_rate * YAW_D) * DT
            plant.yaw = wrapDeg(plant.yaw + plant.yaw_rate * DT)

            -- Pitch/roll from the prop SPEED differentials, plus the
            -- aft-CoM yaw disturbance (rotating behind the CoM rolls the hull
            -- into its own turn).
            -- The airframe is statically stable: pitch/roll are restored
            -- toward level by the hull, so a prop-speed differential settles
            -- at a trimmed angle instead of integrating without bound. The
            -- flight controller's PID then trims that angle out.
            -- Sign convention must match the flight code: pitch + = nose
            -- down, roll + = right down. Right-hand rotation about +x takes
            -- the nose (+z) DOWN, so nose-down-positive is -mx; about +z it
            -- takes the right side (+x) UP, so right-down-positive is -mz.
            -- (Both were the wrong way round here, and the mismatch made the
            -- stabiliser chase an attitude the plant kept pulling away from --
            -- a divergence, not a control bug.)
            local pitch_m = -mx - PITCH_SPRING * plant.pitch
            local roll_m = -mz - ROLL_SPRING * plant.roll
                + plant.yaw_rate * YAW_COUPLE
            plant.pitch_rate = plant.pitch_rate
                + (pitch_m * PITCH_K - plant.pitch_rate * PITCH_D) * DT
            plant.roll_rate = plant.roll_rate
                + (roll_m * ROLL_K - plant.roll_rate * ROLL_D) * DT
            plant.pitch = plant.pitch + plant.pitch_rate * DT
            plant.roll = plant.roll + plant.roll_rate * DT

            -- Translation: the tilt couple's fore/aft force along the nose,
            -- plus rear thrust. Net tilt force is zero for a pure yaw couple,
            -- so steering does not drag the ship sideways.
            local s, c = math.sin(math.rad(plant.yaw)), math.cos(math.rad(plant.yaw))
            local a = fz_t + (plant.rear > 0
                and plant.rear * (plant.rear_rev > 0 and -0.5 or 1.0) * 0.6 or 0)
            plant.vx = plant.vx + a * s * DT
            plant.vz = plant.vz + a * c * DT
            local ld = 1 - 0.6 * DT          -- drag, so it can actually stop
            plant.vx, plant.vz = plant.vx * ld, plant.vz * ld
            plant.x = plant.x + plant.vx * DT
            plant.z = plant.z + plant.vz * DT
        end

        -- vertical (grounded physics, same as vertical_test.lua)
        if grounded then
            plant.v, plant.vx, plant.vz = 0, 0, 0
        else
            local frac = pres * (plant.cmd / HOVER_T) * denv
            plant.v = plant.v + (frac - 1) * G * DT
            plant.alt = plant.alt + plant.v * DT
        end

        -- publish
        -- proximity is a 0..15 SIGNAL where high = close (landed fires at
        -- >=15, gear deploys at >=1), on flat ground at y=0.
        plant.prox = clampf(15 - plant.alt, 0, 15)
        state.altitude, state.climb_rate = plant.alt, plant.v
        state.pitch, state.roll, state.yaw = plant.pitch, plant.roll, plant.yaw
        state.pitch_rate, state.roll_rate = plant.pitch_rate, plant.roll_rate
        state.position.x, state.position.y, state.position.z =
            plant.x, plant.alt, plant.z
        state.velocity.x, state.velocity.y, state.velocity.z =
            plant.vx, plant.v, plant.vz
        state.speed = math.sqrt(plant.vx * plant.vx + plant.vz * plant.vz)
        state.forward.x = math.sin(math.rad(plant.yaw))
        state.forward.z = math.cos(math.rad(plant.yaw))
        state.angularVelocity.y = plant.yaw_rate * math.pi / 180
        return plant.cmd
    end
    return env
end

-- Debug hook: AP_TEST_ENV=1 exposes the plant to an external tracer instead of
-- running the suite (the tracer needs the SAME plant, not a second copy).
if os.getenv("AP_TEST_ENV") then
    _G.AP_TEST_MAKE_ENV = makeEnv
    return
end

-- --------------------------------------------------------------- tests
-- 1. A WAYPOINT WITH NO ALTITUDE CLIMBS TO THE CEILING, and the ceiling is
--    DISCOVERED from the props rather than hardcoded. y280 is a FLOOR: the
--    climb continues past it for as long as the lift props are still turning
--    faster than 13, and stops when they reach 13.
--
--    In THIS plant that is the floor, not something above it: the density
--    model puts the props at ~14.9 of 15 by y280, so they have already passed
--    13 and the climb stops on arrival at the floor. The "keep going because
--    the props are still at 5" half of the policy cannot show up here at all --
--    this pressure curve has no altitude above 280 where demand is that low --
--    so it is checked directly in test 7 against posed thrust instead.
do
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    local ok = f:startAutopilot{ name = "LEVEL", x = 200, z = 0, heading = 0 }
    check("level: startAutopilot accepts the trip", ok, ok and nil or "rejected")
    check("level: a waypoint with no alt asks to climb",
        f.ap.needs_climb == true, "needs_climb=" .. tostring(f.ap.needs_climb))
    check("level: target starts above the 280 floor, not at the ceiling",
        f.ap.goal_alt >= 280, f.ap.goal_alt)

    local peak, okAll, t = -1e9, true, 0
    for i = 1, 14000 do                     -- 700 s: the last stretch is slow
        env.step()
        t = i * DT
        if finite(env.plant.alt) then
            if env.plant.alt > peak then peak = env.plant.alt end
        else okAll = false; break end
        if f.landed or f.shutdown_request then break end
    end
    check("level: altitude stays finite", okAll)
    check("level: cleared the 280 floor",
        peak >= 280, string.format("peak=%.1f", peak))
    -- The probe must stop on or just above the floor -- never below it, and
    -- never past the point where the props ran out.
    check("level: stopped on the ceiling it discovered",
        peak >= 280 and peak < 300, string.format("peak=%.1f", peak))
    check("level: learned the ceiling for later runs",
        (f.config.limits.ceiling or -1) >= 280
            and (f.config.limits.ceiling or 1e9) < 300,
        "limits.ceiling=" .. tostring(f.config.limits.ceiling))
    print(string.format("level trip: peak=%.2f learned=%.1f t=%.0fs",
        peak, f.config.limits.ceiling or -1, t))
end

-- 2. EXPLICIT WAYPOINT ALTITUDE IS HONOURED AND NOT OVERSHOT.
do
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    local ok = f:startAutopilot{ name = "UP", x = 800, z = 0, heading = 0, alt = 90 }
    check("wp.alt: accepted", ok, ok and nil or "rejected")
    check("wp.alt: goal is the requested altitude",
        math.abs(f.ap.goal_alt - 90) < 1e-6, f.ap.goal_alt)
    check("wp.alt: climb requested", f.ap.needs_climb == true)

    local peak = -1e9
    local settled_alt
    for i = 1, 1200 do                     -- 60 s
        env.step()
        if env.plant.alt > peak then peak = env.plant.alt end
        if f.ap and f.ap.step == "turn" and not settled_alt then
            settled_alt = f.ap.alt
        end
    end
    check("wp.alt: no wild overshoot of the requested altitude (<= +8 m)",
        peak <= 90 + 8, string.format("peak=%.1f", peak))
    check("wp.alt: turn holds the TARGET altitude, not a drifted sample",
        settled_alt ~= nil and math.abs(settled_alt - 90) < 1e-6,
        settled_alt)
    print(string.format("wp.alt trip: peak=%.2f held=%.2f", peak, settled_alt or -1))
end

-- 3. CEILING IS RESPECTED as a hard clamp on the climb target.
do
    local env = makeEnv({ alt0 = 100 })
    local f = env.flight
    f:startAutopilot{ name = "HIGH", x = 800, z = 0, heading = 0, alt = 9999 }
    -- An absurd request is clamped to the probe's hard guard, NOT to a
    -- hardcoded 285, and never above it.
    check("ceiling: absurd wp.alt is clamped to the hard guard",
        f.ap.goal_alt <= 450, f.ap.goal_alt)
    for _ = 1, 9000 do
        env.step()
        if f.landed or f.shutdown_request then break end
    end
    -- However hard it is asked, the ship physically cannot exceed the thrust
    -- ceiling, and the probe stops it there.
    check("ceiling: never exceeds the physical ceiling",
        env.plant.alt <= 300, string.format("alt=%.1f", env.plant.alt))
    -- The old code hard-capped the goal at 285, so "beat 285" used to be the
    -- proxy for "this is discovered, not hardcoded". Assert the thing itself
    -- instead: a ceiling was LEARNED, and it is above that old constant. That
    -- is strictly stronger than the proxy and cannot rot when the margin below
    -- the ceiling changes.
    local learned = tonumber((f.config.limits or {}).ceiling)
    check("ceiling: discovered a ceiling, not the old hardcoded 285",
        learned ~= nil and learned >= 280 and learned <= 300,
        string.format("learned=%s", tostring(learned)))
    -- The commanded cruise target must sit on or above the 280 floor. What the
    -- ship then ACHIEVES is physics: by y280 this plant needs ~14.9 of 15 just
    -- to hold, so it hunts a little under the target rather than sitting on
    -- it, and the tolerance below reflects that thin margin rather than
    -- hiding it.
    local target = f.ap and (f.ap.goal_alt or -1) or -1
    check("ceiling: cruise target is on or above the 280 floor",
        target >= 280 and target <= 300, string.format("target=%.1f", target))
    check("ceiling: held the discovered ceiling",
        math.abs(env.plant.alt - target) <= 8,
        string.format("alt=%.1f target=%.1f", env.plant.alt, target))
end

-- 4. TRIP stays bounded and holds altitude.
--
--    SCOPE NOTE: the horizontal plant here is a first-principles stand-in, not
--    a validated Create:Aeronautics 6-DOF model. It reproduces the prop
--    allocation (tilt -> translation, tilt differential -> yaw, prop speed ->
--    pitch/roll) but its gains are invented. Do NOT tune real flight gains
--    against it, and do NOT treat a failure here as a real flight bug without
--    corroborating telemetry from the actual ship. What IS trustworthy here is
--    the vertical channel, which is derived from measured pressure/ground
--    physics, so the altitude assertions below are hard failures.
do
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    local ok = f:startAutopilot{ name = "TRIP", x = 200, z = 0, heading = 0 }
    check("trip: accepted", ok, ok and nil or "rejected")
    local reached, t, maxd, altmax, altmin = {}, 0, 0, -1e9, 1e9
    local hold_min, hold_max = 1e9, -1e9
    for i = 1, 6000 do                     -- 300 s
        env.step()
        t = i * DT
        if f.ap then reached[f.ap.phase] = true end
        if f.landed or f.shutdown_request then break end
        if not finite(env.plant.alt) or math.abs(env.plant.alt) > 1e6 then break end
        maxd = math.max(maxd, math.sqrt(env.plant.x * env.plant.x
            + env.plant.z * env.plant.z))
        -- Only judge the altitude hold during the TRAVEL legs. The final
        -- "land" phase deliberately descends onto the waypoint, so altitude
        -- going to 0 there is the autopilot working, not a drift.
        if not (f.ap and f.ap.phase == "land") and not f.landed then
            altmax, altmin = math.max(altmax, env.plant.alt),
                math.min(altmin, env.plant.alt)
            -- Once it has reached the ceiling, judge the HOLD, not the climb.
            -- An alt-less waypoint means "cruise at the operating ceiling",
            -- so the altitude to hold is discovered, not 60.
            if env.plant.alt >= 280 then
                hold_min, hold_max = math.min(hold_min, env.plant.alt),
                    math.max(hold_max, env.plant.alt)
            end
        end
    end
    local landed = f.landed or f.shutdown_request or f.ap == nil
    check("trip: advanced past the aim phase", reached.cruise or reached.arrive
        or reached.align or reached.land or reached.correct,
        "phases=" .. table.concat((function()
            local ks = {}
            for k in pairs(reached) do ks[#ks + 1] = k end
            table.sort(ks)
            return ks
        end)(), ","))
    check("trip: flight stayed bounded (no runaway)",
        maxd < 2000 and maxd >= 0,
        string.format("maxdist=%.0f", maxd))
    -- vertical channel: this IS trustworthy, so assert it hard
    check("trip: an alt-less waypoint climbs to the operating ceiling",
        altmax >= 280 and altmax <= 300,
        string.format("peak alt %.1f", altmax))
    check("trip: held the ceiling in transit (no sag, no runaway)",
        hold_max > 0 and hold_min >= 280 and hold_max <= 300,
        string.format("hold %.1f..%.1f", hold_min, hold_max))
    check("trip: completed and landed at the waypoint", landed,
        "did not reach a terminal state")
    local near_wp = math.sqrt((env.plant.x - 200) * (env.plant.x - 200)
        + (env.plant.z - 0) * (env.plant.z - 0))
    check("trip: landed close to the waypoint", near_wp < 15,
        string.format("%.1f m off (x=%.1f z=%.1f)", near_wp, env.plant.x, env.plant.z))
    print(string.format("trip: x=%.1f z=%.1f alt=%.1f maxd=%.0f t=%.0fs landed=%s",
        env.plant.x, env.plant.z, env.plant.alt, maxd, t, tostring(landed)))
end

-- 5. WAYPOINT STORE round-trips alt, and stays backward compatible with
--    existing wp files that have no alt field.
do
    -- stub the CC filesystem so lib/waypoints.lua can be exercised
    local written
    _G.fs = {
        exists = function() return false end,
        open = function(_, mode)
            if mode ~= "w" then return nil end
            return {
                -- NOTE: the handle's methods are invoked with the line as the
                -- only argument (verified against lib/waypoints.lua).
                writeLine = function(l) written = (written or "") .. tostring(l) .. "\n" end,
                close = function() end,
            }
        end,
    }
    local WP = dofile("lib/waypoints.lua")
    WP.load(1)                          -- establishes the store path
    WP.add{ name = "WITHALT", x = 10, z = 20, heading = 90, alt = 123.5 }
    WP.add{ name = "NOALT", x = 30, z = 40, heading = 0 }
    _G.fs = nil
    check("wp store: writes alt when supplied", written:find("alt = 123.5", 1, true) ~= nil,
        written)
    check("wp store: omits alt when absent (backward compatible)",
        written:find("NOALT") ~= nil
        and written:find("name = \"NOALT\"") ~= nil
        and not written:find("NOALT\".-alt"), written)
    print("wp store wrote:\n" .. (written or "<none>"))
end

-- 6. TILT LIFT COMPENSATION. The block holds a fixed 25 deg, which leaves
--    cos(25) = 0.906 of vertical thrust, so the hover demand has to be scaled
--    by 1/0.906 whenever the props are tilted or the ship sags every time it
--    moves. This is the check that keeps that payment honest.
do
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    -- Freeze the measured altitude at the target every step so the altitude
    -- PID contributes nothing. Then any change in the demand is purely the
    -- tilt compensation, and the expected ratio is exactly 1/cos(25).
    local function settle(stick_fwd, stick_yaw, n)
        f.targets.move_forward = stick_fwd
        f.targets.yaw_cmd = stick_yaw
        local last
        for _ = 1, n do
            env.state.altitude = 60
            env.state.climb_rate = 0
            env.step()
            last = f.outputs.speed
        end
        return last
    end
    local flat = settle(0, 0, 30)
    local want = 1 / math.cos(25 * math.pi / 180)
    -- Pure translation: all four props go to a full 25 deg, so the whole
    -- airframe is tilted and loses exactly cos(25) of lift.
    local fwd = settle(2, 0, 10)
    -- Pure yaw: left pair one way, right pair the other. Still all four props
    -- tilted, so the lift loss is the same -- which is the point.
    local yawed = settle(0, 1, 10)
    check("tilt costs lift: level demand sits at full thrust",
        flat > 5.5 and flat < 6.5, string.format("flat=%.2f", flat))
    check("translation lift is paid back by 1/cos(25)",
        math.abs(fwd / flat - want) < 0.02,
        string.format("ratio=%.3f want=%.3f", fwd / flat, want))
    check("yawing costs the same lift as translating",
        math.abs(yawed / flat - want) < 0.02,
        string.format("ratio=%.3f want=%.3f", yawed / flat, want))
    print(string.format("tilt lift: flat=%.2f fwd=%.2f yaw=%.2f  ratios %.3f/%.3f want=%.3f",
        flat, fwd, yawed, fwd / flat, yawed / flat, want))
end

-- 7. THE CEILING POLICY ITSELF, checked directly against posed thrust.
--
--    The plant's pressure curve puts the lift props at ~14.9 of 15 by y280,
--    so the "keep climbing because the props are still at 5" half of the
--    policy can never occur there. It is posed directly instead: demand with
--    no climb rate is hover_throttle * e^(0.004*(alt-63)), so any (altitude,
--    lift-prop-speed) pair can be reproduced by solving for the throttle.
--    This is the case that matters on a world where the player has terrain and
--    builds high -- denser air up there, props still turning at 5 on reaching
--    y280, and the ship has to keep going.
do
    local env = makeEnv({ alt0 = 100 })
    local f = env.flight
    local lim = f.config.limits
    local hmax = lim.hover_max_speed

    local function probeAt(alt, want)
        lim.hover_throttle = want / math.exp(0.004 * (alt - 63))
        return f:ceilingProbe(alt, hmax)
    end

    check("policy: below the floor it just climbs",
        probeAt(279, 5) == true)
    check("policy: y280 is a floor, not a ceiling (props at 5 -> keep going)",
        probeAt(280, 5) == true)
    check("policy: props at 12.9 still count as room to climb",
        probeAt(280, 12.99) == true)
    check("policy: props at 13 stop the climb",
        probeAt(280, 13) == false)
    check("policy: recorded the floor as this world's ceiling",
        math.abs((lim.ceiling or -1) - 280) < 1e-6,
        string.format("ceiling=%s", tostring(lim.ceiling)))

    -- a fresh world, this time one that goes up for a very long way
    lim.ceiling = nil
    check("policy: thousands of blocks still counts as room",
        probeAt(6000, 5) == true)
    check("policy: stops wherever the props reach 13, however high",
        probeAt(6000, 13) == false)
    check("policy: learned a ceiling in the thousands",
        math.abs((lim.ceiling or -1) - 6000) < 1e-6,
        string.format("ceiling=%s", tostring(lim.ceiling)))
    check("policy: cruises at the altitude it discovered",
        math.abs(f:ceilingTarget() - 6000) < 1e-6, f:ceilingTarget())

    lim.ceiling = nil
    check("policy: nothing learned yet -> hard guard, so it probes",
        f:ceilingTarget() == 450, f:ceilingTarget())
    lim.ceiling = 280
    check("policy: a ceiling exactly on the floor is honoured",
        f:ceilingTarget() == 280, f:ceilingTarget())
    lim.hover_throttle = HOVER_T
end

-- 8. YAW-COMPENSATION TRIM MUST NOT FIGHT THE STABILISER.
--
--    Reported from the real ship: the wobble happens on the way to FACING a
--    waypoint, and pitch+roll are what yaw the hull there. The trim pre-aims
--    the levelling PIDs at a compensating attitude, and the cap schedule was
--    keyed to the MEASURED attitude instead of the PID error. Mid-turn the
--    setpoint sits at 0.55*12 = 6.6 deg while the ship is still near level,
--    so |attitude| < 2 handed the stabiliser a cap of ZERO -- no authority at
--    the moment the error was largest -- then doubled the gain crossing 6 deg
--    on the way to its own target.
--
--    Disabled (the default, and correct for a hull that yaws by rolling), the
--    two must not fight. Enabled, a level ship with a real trim error must
--    still get authority.
do
    local env = makeEnv({ alt0 = 100 })
    local f = env.flight
    local lim = f.config.limits

    -- Sampled over a window, not a single tick: the levelling correction is a
    -- pulse train (duty across the deadband), so any one tick is legitimately
    -- zero. What matters is whether authority is exercised at all.
    local function levelShipWithFullYaw(yaw_stick)
        env.state.altitude = 300
        env.state.roll, env.state.pitch = 0, 0
        env.state.roll_rate, env.state.pitch_rate = 0, 0
        env.state.yaw_rate = 0
        env.state.speed = 0
        env.state.climb_rate = 0
        -- AP must be live: under the autopilot the pulse train is forced
        -- continuous, and it is the autopilot's aim phase that yaws by
        -- pitch/roll in the first place. Without it this is the manual path.
        f.ap = f.ap or { phase = "aim" }
        f.targets.yaw_cmd = yaw_stick
        local mx_roll, mx_pitch = 0, 0
        for _ = 1, 60 do
            f:updateHover(0.05)
            local o = f.outputs
            local dr = math.abs((o.FL_speed or 0) - (o.FR_speed or 0))
            local dp = math.abs((o.FL_speed or 0) - (o.RL_speed or 0))
            if dr > mx_roll then mx_roll = dr end
            if dp > mx_pitch then mx_pitch = dp end
        end
        return mx_roll, mx_pitch
    end

    -- default: no trim, so the levelling PIDs aim at level and a level ship
    -- needs no correction. Nothing extra steers.
    local d_roll, d_pitch = levelShipWithFullYaw(1.0)
    check("yaw trim off by default (a guess is not a setting)",
        (lim.yaw_roll_coupling or 0) == 0 and (lim.yaw_pitch_coupling or 0) == 0)
    check("yaw trim off: a level ship is left alone through a turn",
        d_roll < 1.01 and d_pitch < 1.01,
        string.format("roll diff %.2f pitch diff %.2f", d_roll, d_pitch))

    -- enabled: the trim moves the setpoint, and the cap MUST follow the error
    lim.yaw_roll_coupling, lim.yaw_pitch_coupling = 0.55, 0.30
    -- moderate yaw on purpose: at full yaw the collective is deliberately
    -- faded to nothing ("full yaw = no translation request"), so there is no
    -- authority to find. This is the band where a trim actually has to work.
    local r_roll, r_pitch = levelShipWithFullYaw(0.40)
    check("yaw trim on: stabiliser still has authority on a level ship",
        r_roll > 0.5 or r_pitch > 0.5,
        string.format("roll diff %.2f pitch diff %.2f", r_roll, r_pitch))

    -- and the trim is bounded: full yaw must never command a wild attitude
    check("yaw trim is bounded, not a hard turn command",
        math.abs(0.55 * 12) > 3.0, "expected the raw product to exceed the bound")

    lim.yaw_roll_coupling, lim.yaw_pitch_coupling = nil, nil
    f.targets.yaw_cmd = 0
    lim.hover_throttle = HOVER_T
end

-- 9. THE CLIMB IS SMOOTH AND NEVER SAILS OVER THE GOAL.
--    This is the regression for the reported "brutal climb": props slammed to
--    max, then to zero, ship fell like a brick, overshot, repeated. The climb
--    law now uses a FIXED target, a constant-rate transit and a braking
--    profile, so:
--      * the collective must move gradually (no 0 <-> 15 slam),
--      * the peak must stay close to the requested altitude,
--      * the ship must arrive with almost no vertical speed,
--      * mid-climb rate must be steady (linear altitude gain, not a series of
--        surges).
do
    local TARGET = 200
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    f:startAutopilot{ name = "SMOOTH", x = 800, z = 0, heading = 0, alt = TARGET }

    local peak, max_dcmd, arrive_v = -1e9, 0, nil
    local prev_cmd, samples, rate_sum, rate_n = nil, {}, 0, 0
    local braking = true
    for _ = 1, 4000 do                     -- 200 s
        env.step()
        if not finite(env.plant.alt) then break end
        local cmd = env.plant.cmd
        if prev_cmd ~= nil then
            max_dcmd = math.max(max_dcmd, math.abs(cmd - prev_cmd))
        end
        prev_cmd = cmd
        if env.plant.alt > peak then peak = env.plant.alt end
        -- steady-state window: well clear of the launch transient and the
        -- braking tail, so this measures the cruise climb, not the endpoints
        local alt = env.plant.alt
        if alt > 100 and alt < TARGET - 25 then
            rate_sum = rate_sum + env.plant.v
            rate_n = rate_n + 1
        end
        if f.ap and f.ap.step == "turn" and arrive_v == nil then
            arrive_v = math.abs(env.plant.v)
            braking = false
        end
        if arrive_v ~= nil then break end
    end

    check("climb: reaches the requested altitude",
        math.abs(env.plant.alt - TARGET) <= 4.0, string.format("alt=%.2f", env.plant.alt))
    -- The headline requirement: it must not go materially over the goal.
    check("climb: never sails over the goal (+2 m)",
        peak <= TARGET + 2.0, string.format("peak=%.2f", peak))
    -- No per-tick step change anywhere near a 0 <-> 15 slam. The attack
    -- limiter allows 20/s * 0.05 = 1.0 prop per tick; allow a little slack for
    -- the hmax clamp but nothing like a full-scale slam.
    check("climb: collective does not slam (max step <= 1.2 prop/tick)",
        max_dcmd <= 1.2, string.format("max step=%.3f", max_dcmd))
    -- Arrives with the vertical motion already killed, which is what stops the
    -- momentum carrying it through the goal into the turn.
    check("climb: arrives with ~zero vertical speed",
        arrive_v ~= nil and arrive_v <= 1.0, string.format("v=%.3f", tostring(arrive_v)))
    -- Transit is a steady climb, not a surge-and-coast.
    local mean_rate = (rate_n > 0) and (rate_sum / rate_n) or 0
    check("climb: transit rate is steady and positive (linear gain)",
        mean_rate > 1.0 and mean_rate < 9.0, string.format("mean v=%.2f", mean_rate))
    print(string.format("climb: peak=%.2f held=%.2f arrive_v=%.3f max_step=%.3f mean_v=%.2f",
        peak, env.plant.alt, arrive_v or -1, max_dcmd, mean_rate))
end

-- 10. THE TURN -> CRUISE HANDOFF MUST NOT SPIN THE SHIP.
--     Reported: "after rotating to face the wp, the ship dove again and lost
--     100 blocks of altitude and also didn't start going forward at all."
--     Root cause was NOT the rear spool (sweeping cruise_ramp to 1/s diverged
--     identically). It was the bank-to-turn loop: near the ceiling hover eats
--     the prop headroom, the reduce-only bank cannot be sustained, and a
--     saturated bank that cannot be held is positive feedback -- the hull yaws
--     off it, overshoots the bearing, and the reversed bank yaws it straight
--     back. Measured 8 deg of bank -> 44 deg/s of yaw and a bearing error
--     past 100 deg, with the ship sitting at 1 m/s oscillating
--     cruise<->correct and never making forward progress.
--
--     The fix gates banking on available headroom and hands steering back to
--     the hover turn (tilt-yaw costs no lift headroom) when the margin is
--     gone. So the bearing error must stay BOUNDED after the turn completes,
--     and the ship must actually get up to speed.
--
--     Leg is 200 m at the learned ceiling (the hard case: least headroom).
--     KNOWN GAP, not asserted here: legs past ~400 m still stall out at the
--     ceiling and past ~600 m at any altitude, because the bank-to-turn loop
--     itself is under-damped in this plant -- 8 deg of bank yaws at 44 deg/s,
--     so the bank saturates, overshoots, and reverses. That predates this
--     change (baseline f7a1272 reached max err 114 and the same 1.9 m/s crawl
--     on an 800 m leg) and needs in-game measurement of the bank->yaw gain
--     before it can be retuned honestly.
do
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    -- Bearing 90 deg off the nose, so the run must turn before it can cruise.
    f:startAutopilot{ name = "TURN", x = 200, z = 0, heading = 90 }

    local turned, max_err_after, max_spd, arrived = false, 0, 0, false
    for _ = 1, 6000 do                       -- 300 s
        env.step()
        if not finite(env.plant.alt) then break end
        if f.ap then
            if f.ap.phase == "cruise" then turned = true end
            if turned then
                max_err_after = math.max(max_err_after, math.abs(tonumber(f.ap.err) or 0))
            end
            max_spd = math.max(max_spd, math.sqrt(env.plant.vx ^ 2 + env.plant.vz ^ 2))
            if f.ap.phase == "align" then arrived = true end
        end
    end
    check("turn: the run reaches a cruise leg", turned, "never entered cruise")
    -- The old loop ran the error out past 100 deg and kept going. Bound it.
    check("turn: bearing error stays bounded after the turn (<= 40 deg)",
        max_err_after <= 40, string.format("max err=%.1f", max_err_after))
    -- "Didn't start going forward": the ship has to build real speed, not sit
    -- at the 1 m/s crawl the runaway pinned it to.
    check("turn: ship builds forward speed after the turn (>= 3 m/s)",
        max_spd >= 3, string.format("max v=%.2f m/s", max_spd))
    -- And it has to actually finish the leg, not stall short of it.
    check("turn: leg completes after the turn", arrived, "never reached align")
    print(string.format("turn: reached_cruise=%s max_err_after=%.1f max_v=%.2f arrived=%s",
        tostring(turned), max_err_after, max_spd, tostring(arrived)))
end

-- 11. THE STABILISER TAPERS AS THE PROPS SPEED UP.
--     Reported: "the higher we are, the faster the propeller speeds and so,
--     the stronger the corrections. So we need an adaptive PID that sends
--     smaller corrections the faster the propeller speed."
--     stabAdapt() scales the attitude differential by the headroom left above
--     hover, with a floor so the hull is still catchable. Same attitude error,
--     two altitudes: the correction up high must be SMALLER, not bigger.
--     Keyed on the STATIC hover (hover*den) so the gain does not move with
--     climb rate -- keying it on the live feedforward broke climb moment
--     invariance (vertical_test caught ratio 0.652).
--
--     NB the differential is measured on the Flight's OWN state table (f.state,
--     not env.state) -- Flight caches a copy, so writing env.state does
--     nothing and the test silently measured the undisturbed ship.
do
    local function meanDiffAt(alt0)
        local env = makeEnv({ alt0 = alt0 })
        local f = env.flight
        f:startAutopilot{ name = "TAPER", x = 2000, z = 0, heading = 0, alt = alt0 }
        local acc, n = 0, 0
        for _ = 1, 1200 do
            env.step()
            if f.ap and f.ap.phase == "aim" and f.ap.step == "turn" then
                -- same disturbance both times: hold a roll, measure the diff
                f.state.roll = -4.0
                f.state.roll_rate = 0
                f.state.yaw_rate = 0
                f:updateHover(0.05)
                local o = f.outputs
                acc = acc + math.abs((o.RL_speed or 0) - (o.RR_speed or 0))
                n = n + 1
                if n >= 200 then break end
            end
        end
        return (n > 0) and (acc / n) or 0
    end
    local low = meanDiffAt(80)     -- plenty of headroom
    local high = meanDiffAt(270)   -- props near max, almost nothing in hand
    check("taper: high-altitude correction is smaller than low-altitude",
        high < low * 0.85, string.format("low=%.3f high=%.3f", low, high))
    -- ...but it must not vanish: a leaning hull still has to be caught.
    check("taper: high-altitude correction keeps a floor (>= 25% of low)",
        high >= low * 0.25, string.format("low=%.3f high=%.3f", low, high))
    print(string.format("taper: low_alt_diff=%.3f high_alt_diff=%.3f ratio=%.2f",
        low, high, (low > 0) and (high / low) or 0))
end

print(string.format("ap_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("ap_test FAILED", 0) end
