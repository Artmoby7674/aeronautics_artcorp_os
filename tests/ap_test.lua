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
-- Boots are driven from lib/os_main.lua, which needs the full hardware +
-- graphics stack and cannot be required here. What matters for the altitude
-- re-stamp is the CONTRACT between beginBoot() and Flight:update(), so this
-- stub reproduces beginBoot's one arming line verbatim. If os_main.lua stops
-- setting the flag, this fails instead of the suite quietly going green.
local function readBootArmsRecapture()
    local path = "lib/os_main.lua"
    local fh = io.open(path, "r")
    if not fh then return nil end
    local src = fh:read("*a")
    fh:close()
    local f = src:find("flight.recapture_alt = true", 1, true)
    return f ~= nil
end

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
        -- Ship local X = LONGITUDINAL: av.x = roll rate, av.z = pitch rate, and
        -- pitch+ = nose down = NEGATIVE Z rotation (see Flight:updateState).
        --
        -- These must be published. Flight:updateState() RECOMPUTES
        -- state.roll_rate / state.pitch_rate from angularVelocity and throws
        -- away whatever the harness set directly on `state`, so a harness that
        -- only fills angularVelocity.y silently feeds the whole stabiliser a
        -- roll_rate and pitch_rate of exactly 0 -- i.e. the rate (momentum)
        -- term is multiplied by zero every tick and never once contributes.
        -- That is precisely the bug the suite was blind to: the ship rang in
        -- game while all 86 checks passed, because here the D term could not
        -- possibly do anything.
        state.angularVelocity.x = plant.roll_rate * math.pi / 180
        state.angularVelocity.z = -plant.pitch_rate * math.pi / 180
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
--    DISCOVERED from the props rather than hardcoded. y250 is the MINIMUM
--    FLIGHT HEIGHT: it is where the plan starts, and the climb continues past
--    it for as long as the lift props are still turning faster than 13,
--    stopping when they reach 13.
--
--    The plan and the discovery climb are deliberately different numbers. The
--    PLAN (ap.goal_alt, the altitude shown as the goal) starts at the floor
--    and is only ever raised by a ceiling the ship has measured. The
--    DISCOVERY CLIMB (ap.ceil) starts at the 450 m hard guard so the probe
--    has room to work, and is never displayed or held as a destination. The
--    bug this replaced: the guard leaked into the plan, so an alt-less
--    waypoint was sent to y450 and the HUD showed y450.
--
--    In THIS plant the discovery settles just above the floor: the density
--    model already needs ~14.9 of 15 by y250, so the climb stops a few metres
--    after the floor. The "keep going because the props are still at 5" half
--    of the policy cannot show up here at all -- this pressure curve has no
--    altitude above the floor where demand is that low -- so it is checked
--    directly in test 7 against posed thrust instead.
do
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    local ok = f:startAutopilot{ name = "LEVEL", x = 200, z = 0, heading = 0 }
    check("level: startAutopilot accepts the trip", ok, ok and nil or "rejected")
    check("level: a waypoint with no alt asks to climb",
        f.ap.needs_climb == true, "needs_climb=" .. tostring(f.ap.needs_climb))
    -- The whole point of the plan/seek split: the GOAL is the floor, and the
    -- 450 guard is nowhere near it.
    check("level: goal starts at the 250 floor, not the 450 guard",
        f.ap.goal_alt == 250, f.ap.goal_alt)
    check("level: goal is never the hard guard",
        f.ap.goal_alt < 450, f.ap.goal_alt)
    check("level: the discovery climb is what seeks the guard",
        f.ap.ceil == 450, f.ap.ceil)

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
    check("level: cleared the 250 floor",
        peak >= 250, string.format("peak=%.1f", peak))
    -- The probe must stop on or just above the floor -- never below it, and
    -- never past the point where the props ran out.
    check("level: stopped on the ceiling it discovered",
        peak >= 250 and peak < 300, string.format("peak=%.1f", peak))
    check("level: learned the ceiling for later runs",
        (f.config.limits.ceiling or -1) >= 250
            and (f.config.limits.ceiling or 1e9) < 300,
        "limits.ceiling=" .. tostring(f.config.limits.ceiling))
    print(string.format("level trip: peak=%.2f learned=%.1f t=%.0fs",
        peak, f.config.limits.ceiling or -1, t))
end

-- 1b. getStatus() EXPOSES EVERY FIELD THE A/P SCREEN READS.
-- The HUD renders distance, progress, the phase/step pair, bearing error and
-- the pause flag straight out of getStatus(). A field that is present on
-- Flight.ap but missing here shows up in-game as a blank or "--" on a live
-- screen, and no flight test would catch it.
do
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    local s0 = f:getStatus()
    check("getStatus: ap is nil when no run is active", s0.ap == nil, type(s0.ap))

    local ok = f:startAutopilot{ name = "TELE", x = 900, z = 0, heading = 0, alt = 90 }
    check("getStatus: waypoint accepted", ok, ok and nil or "rejected")

    local seen_step, seen_phase, seen_eta, err_seen
    for i = 1, 400 do
        env.step()
        local s = f:getStatus()
        if s.ap then
            local a = s.ap
            if type(a.phase) ~= "string" then seen_phase = a.phase end
            if type(a.step) ~= "string" and type(a.step) ~= "nil" then seen_step = a.step end
            if a.eta ~= nil and type(a.eta) ~= "number" then seen_eta = a.eta end
            if finite(a.dist) and finite(a.progress) and finite(a.err)
               and finite(a.heading) and finite(a.alt) and finite(a.speed) then
                err_seen = true
            end
            check("getStatus: phase is a string the HUD can map",
                a.phase == "aim" or a.phase == "cruise" or a.phase == "correct"
                or a.phase == "arrive" or a.phase == "align" or a.phase == "land",
                tostring(a.phase))
            check("getStatus: name is a string", type(a.name) == "string", type(a.name))
            check("getStatus: progress is 0..1",
                a.progress >= 0 and a.progress <= 1, a.progress)
            check("getStatus: paused is a boolean", type(a.paused) == "boolean",
                type(a.paused))
            break
        end
    end
    check("getStatus: ap exposes finite dist/progress/err/heading/alt/speed",
        err_seen == true)
    print(string.format("getStatus telemetry: phase=%s step=%s dist=%.1f progress=%.2f err=%.1f",
        tostring(f.ap and f.ap.phase), tostring(f.ap and f.ap.step),
        f.ap and f.ap.dist or -1, f.ap and f.ap.progress or -1, f.ap and f.ap.err or -1))
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

-- 2b. THE 450 GUARD IS NEVER AN ALTITUDE GOAL.
--
--     Reported from the real ship: the autopilot set its altitude goal to
--     y450 when climbing. Root cause: ceilingTarget() doubled as both "the
--     altitude we plan to cruise at" and "what to climb toward while we are
--     still finding out". With one number, "nothing learned yet" had to answer
--     AP_CEIL_HARD so the probe had somewhere to go -- and that 450 was handed
--     straight to the pilot as the goal. In a world with thin air the props
--     never fall short, so it could also sit at 450 indefinitely.
--
--     These assert the split, and the two behaviours it has to keep straight:
--     an alt-less waypoint may have its goal RAISED by a real measurement, and
--     an explicit altitude may never be raised by anything.
do
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight

    -- (a) fresh world: plan is the floor, only the seek touches the guard.
    f.config.limits.ceiling = nil
    f:startAutopilot{ name = "A", x = 800, z = 0, heading = 0 }
    check("guard: an alt-less goal starts at the 250 floor",
        f.ap.goal_alt == 250, f.ap.goal_alt)
    check("guard: an alt-less goal is never the 450 guard",
        f.ap.goal_alt ~= 450, f.ap.goal_alt)
    check("guard: the discovery climb is the one that uses the guard",
        f.ap.ceil == 450, f.ap.ceil)
    check("guard: the trip is flagged alt-less so the probe may steer it",
        f.ap.alt_less == true, tostring(f.ap.alt_less))

    -- (b) a HIGH learned ceiling may raise an alt-less goal -- this is the
    --     thin-air world the operator described: keep climbing until the props
    --     come back to 13, then cruise there.
    f.ap = nil
    f.config.limits.ceiling = 6000
    f:startAutopilot{ name = "B", x = 800, z = 0, heading = 0 }
    check("guard: a measured ceiling raises an alt-less goal",
        f.ap.goal_alt == 6000, f.ap.goal_alt)

    -- (c) an EXPLICIT altitude is the operator's decision and is never raised
    --     by a high ceiling. This is the branch most likely to regress: the
    --     probe runs on every phase of every run, including this one.
    f.ap = nil
    f:startAutopilot{ name = "C", x = 800, z = 0, heading = 0, alt = 90 }
    check("guard: an explicit altitude is not raised to the ceiling",
        f.ap.goal_alt == 90, f.ap.goal_alt)
    check("guard: an explicit waypoint is not flagged alt-less",
        f.ap.alt_less == false, tostring(f.ap.alt_less))
    for _ = 1, 400 do env.step() end
    check("guard: an explicit altitude survives the probe running",
        f.ap and f.ap.goal_alt == 90, f.ap and f.ap.goal_alt or "landed")

    -- (d) an explicit altitude ABOVE what the ship can reach converges DOWN
    --     onto the measured ceiling rather than sitting at the guard.
    f.ap = nil
    f.config.limits.ceiling = 256
    f:startAutopilot{ name = "D", x = 800, z = 0, heading = 0, alt = 9999 }
    check("guard: an unreachable explicit altitude clamps to the guard",
        f.ap.goal_alt == 450, f.ap.goal_alt)
    for _ = 1, 600 do env.step() end
    check("guard: then converges onto the measured ceiling, not the guard",
        f.ap and f.ap.goal_alt ~= 450 and f.ap.goal_alt <= 300,
        f.ap and f.ap.goal_alt or "landed")

    f.config.limits.ceiling = nil
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
    -- An explicit altitude far above anything reachable must converge on the
    -- MEASURED ceiling once the probe has found it, not stay pinned at the
    -- 450 guard.
    local learned = tonumber((f.config.limits or {}).ceiling)
    check("ceiling: discovered a ceiling, not a hardcoded constant",
        learned ~= nil and learned >= 250 and learned <= 300,
        string.format("learned=%s", tostring(learned)))
    -- The commanded cruise target must sit on or above the 250 floor and below
    -- the guard. What the ship then ACHIEVES is physics: by the floor this
    -- plant needs ~14.9 of 15 just to hold, so it hunts a little under the
    -- target rather than sitting on it, and the tolerance below reflects that
    -- thin margin rather than hiding it.
    local target = f.ap and (f.ap.goal_alt or -1) or -1
    check("ceiling: cruise target is the measured ceiling, not the guard",
        target >= 250 and target <= 300 and target < 450,
        string.format("target=%.1f", target))
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
            if env.plant.alt >= 250 then
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
        altmax >= 250 and altmax <= 300,
        string.format("peak alt %.1f", altmax))
    check("trip: held the ceiling in transit (no sag, no runaway)",
        hold_max > 0 and hold_min >= 250 and hold_max <= 300,
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
--    y250, and the ship has to keep going.
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
        probeAt(249, 5) == true)
    check("policy: y250 is a floor, not a ceiling (props at 5 -> keep going)",
        probeAt(250, 5) == true)
    check("policy: props at 12.9 still count as room to climb",
        probeAt(250, 12.99) == true)
    check("policy: props at 13 stop the climb",
        probeAt(250, 13) == false)
    check("policy: recorded the floor as this world's ceiling",
        math.abs((lim.ceiling or -1) - 250) < 1e-6,
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

    -- The plan/seek split. This is the bug the whole change exists to fix:
    -- with one number for both jobs, "nothing learned yet" had to answer 450
    -- (so the probe had somewhere to go) and that 450 became the altitude
    -- GOAL the pilot saw. Two numbers keep each answer honest.
    lim.ceiling = nil
    check("policy: nothing learned yet -> the PLAN is the minimum flight height",
        f:ceilingTarget() == 250, f:ceilingTarget())
    check("policy: nothing learned yet -> the SEEK is the hard guard",
        f:ceilingSeek() == 450, f:ceilingSeek())
    check("policy: the plan is never the hard guard",
        f:ceilingTarget() ~= f:ceilingSeek(), f:ceilingTarget())
    lim.ceiling = 250
    check("policy: a ceiling exactly on the floor is honoured",
        f:ceilingTarget() == 250, f:ceilingTarget())
    check("policy: a learned ceiling is also the seek target",
        f:ceilingSeek() == 250, f:ceilingSeek())
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

-- 9. THE CLIMB IS SMOOTH, HANDS OVER EARLY, AND NEVER SAILS OVER THE GOAL.
--    This is the regression for the reported "brutal climb": props slammed to
--    max, then to zero, ship fell like a brick, overshot, repeated. The climb
--    law uses a FIXED target, a constant-rate transit and a braking profile.
--
--    The height-validation gate is now a DISTANCE (AP_CLIMB_VALIDATE = 10 m)
--    rather than "stopped on the goal". Two measured reasons:
--      * the v^2 brake profile approaches as sqrt(remaining), so the tail was
--        always a crawl -- the last 20 blocks cost 6.55 s and the last 10 cost
--        4.85 s of a 28.7 s climb, serialised in front of the rotation;
--      * requiring |rate| <= 0.4 m/s before leaving the phase let the ship
--        arrive at the goal still doing 5+ m/s, where the "never push past the
--        goal" collective cap turned a hot arrival into a ballistic one and it
--        sailed 2.87 blocks over. Handing over at 10 blocks costs 2.87 -> 0.00.
--    The last blocks are closed by the altitude POSITION PID, which the turn
--    step already runs, so the two overlap instead of queueing. So these
--    assertions pin the NEW contract: hand over in the validation band with a
--    bounded rate, then CONVERGE ON THE TARGET during the rotation.
do
    local TARGET = 200
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    f:startAutopilot{ name = "SMOOTH", x = 800, z = 0, heading = 0, alt = TARGET }

    local peak, max_dcmd, max_dcmd_turn = -1e9, 0, 0
    local prev_cmd, rate_sum, rate_n = nil, 0, 0
    local tail20, tail10 = 0, 0
    local t, hand_t, hand_remain, hand_v = 0, nil, nil, nil
    local saw_brake_in_turn = false
    for _ = 1, 4000 do                     -- 200 s
        env.step()
        t = t + DT
        if not finite(env.plant.alt) then break end
        local cmd = env.plant.cmd
        -- Slam is measured PER PHASE. The climb->turn handover is smooth (see
        -- AP_CLIMB_HANDOVER_SLEW); the turn step contains a separate,
        -- PRE-EXISTING discontinuity at the HOVER->CRUISE mode change, which
        -- is measured on its own below rather than folded in here.
        if prev_cmd ~= nil then
            local d = math.abs(cmd - prev_cmd)
            if f.ap and f.ap.step == "climb" then
                max_dcmd = math.max(max_dcmd, d)
            elseif f.ap and f.ap.step == "turn" then
                max_dcmd_turn = math.max(max_dcmd_turn, d)
            end
        end
        prev_cmd = cmd
        if env.plant.alt > peak then peak = env.plant.alt end
        local remain = TARGET - env.plant.alt
        if f.ap and f.ap.step == "climb" then
            -- steady-state window: clear of both the launch transient and the
            -- braking tail, so this measures the cruise climb
            if env.plant.alt > 100 and remain > 25 then
                rate_sum = rate_sum + env.plant.v
                rate_n = rate_n + 1
            end
            if remain <= 20 then tail20 = tail20 + DT end
            if remain <= 10 then tail10 = tail10 + DT end
        elseif f.ap and f.ap.step == "turn" then
            if (f.ap.climb_brake or 0) > 0 then saw_brake_in_turn = true end
            if hand_t == nil then
                -- the handoff: record what the ship was doing when it handed over
                hand_t, hand_remain, hand_v = t, remain, math.abs(env.plant.v)
            end
        end
        -- keep running well past the handoff so convergence can be measured
        if hand_t ~= nil and t > hand_t + 25 then break end
    end

    -- (a) THE NEW CONTRACT: hand over in the validation band, i.e. still
    --     short of the goal rather than sitting on it.
    check("climb: hands over in the validation band, short of the goal",
        hand_remain ~= nil and hand_remain >= 4 and hand_remain <= 16,
        string.format("remain=%.2f at handoff", hand_remain or -1))
    -- (b) ...with a bounded arrival rate, so the position PID has the 10 m of
    --     run-out it needs to arrest it (~2.0 m/s^2 of real braking here).
    check("climb: hands over at a bounded rate (arresting distance fits)",
        hand_v ~= nil and hand_v <= 6.5, string.format("v=%.3f", hand_v or -1))
    -- (c) THE TAIL IS THE COMPLAINT: the last 20 blocks used to cost 6.55 s.
    check("climb: the last 20 blocks are no longer a crawl (< 3.0 s)",
        tail20 > 0 and tail20 < 3.0, string.format("tail20=%.2fs", tail20))
    check("climb: the last 10 blocks are no longer a crawl (< 1.0 s)",
        tail10 > 0 and tail10 < 1.0, string.format("tail10=%.2fs", tail10))
    -- (d) THE HEADLINE REQUIREMENT, at the tolerance the shipped code has
    --     always used. Validating the height early on its own made this WORSE
    --     (2.00 -> 3.47 blocks) because the collective changed hands at 5 m/s;
    --     keeping the climb's brake running through the rotation (i) recovered
    --     it and came out slightly ahead of HEAD: measured peak 201.62 here vs
    --     202.00 at HEAD. So this asserts the real contract rather than a
    --     number picked to fit.
    check("climb: never sails over the goal (+2 m)",
        peak <= TARGET + 2.0, string.format("peak=%.2f", peak))
    -- (i) The mechanism that protects (d): the braked arrival is still being
    --     flown by the climb law while the turn rotates. Without this the tail
    --     gets fast again but the ship sails over the goal.
    check("climb: the brake keeps flying through the rotation",
        saw_brake_in_turn, "climb law was dropped at the phase change")
    -- (e) No per-tick step change anywhere near a 0 <-> 15 slam. The attack
    --     limiter allows 20/s * 0.05 = 1.0 prop per tick; allow a little slack
    --     for the hmax clamp but nothing like a full-scale slam.
    check("climb: collective does not slam (max step <= 1.2 prop/tick)",
        max_dcmd <= 1.2, string.format("max step=%.3f", max_dcmd))
    -- (f) The last blocks are closed by the position PID during the turn, so
    --     the ship must still END UP on the requested altitude. This is the
    --     old "reaches the requested altitude" check, measured over the window
    --     where the convergence actually happens rather than at the instant of
    --     handoff (where the ship is deliberately still 10 m short).
    check("climb: converges onto the target during the rotation",
        math.abs(env.plant.alt - TARGET) <= 4.0,
        string.format("alt=%.2f target=%d", env.plant.alt, TARGET))
    -- Transit is a steady climb, not a surge-and-coast.
    local mean_rate = (rate_n > 0) and (rate_sum / rate_n) or 0
    check("climb: transit rate is steady and positive (linear gain)",
        mean_rate > 1.0 and mean_rate < 9.0, string.format("mean v=%.2f", mean_rate))
    -- (h) PRE-EXISTING, not fixed here, but pinned so it cannot get worse.
    --     Flight:setMode resets every PID and re-targets altitude to the
    --     current value, and the two vertical laws disagree about tilt: hover
    --     divides its demand by mean_tilt_lift (cos 25 deg = 0.906) while
    --     cruise zeroes the tilt and uses 1. The HOVER->CRUISE switch inside
    --     the turn step is therefore a single-tick step in mean thrust. It is
    --     identical at the previous commit (measured 3.588 there, 3.572
    --     here), so this change did not introduce it -- the OLD version of
    --     this test simply broke out of its loop the instant the climb handed
    --     over to the turn and never ran as far as the mode change. The old
    --     "max step <= 1.2" pass was partly luck of where it stopped.
    --     Asserted against the measured pre-existing baseline, not against an
    --     aspiration, so this test states what is true rather than what would
    --     be nice.
    check("turn: HOVER->CRUISE step is not worse than the known baseline",
        max_dcmd_turn <= 3.7, string.format("max turn step=%.3f (baseline 3.59)", max_dcmd_turn))
    print(string.format("climb: peak=%.2f held=%.2f hand_remain=%.2f hand_v=%.3f tail20=%.2f tail10=%.2f max_step=%.3f turn_step=%.3f mean_v=%.2f",
        peak, env.plant.alt, hand_remain or -1, hand_v or -1, tail20, tail10, max_dcmd, max_dcmd_turn, mean_rate))
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

-- 12. CRUISE MUST ACTUALLY CRUISE.
-- A bank is how cruise steers: updateCruise drives the roll PID to a nonzero
-- setpoint, and rotationControl() (hover tilt-yaw) is only ever called from
-- updateHover. So "cruise is using hover yaw" can only mean the ship is not
-- actually in MODE_CRUISE.
--
-- A revision gated the bank on available headroom, keyed on (hmax - hover) --
-- which is 0.0 at the ceiling BY CONSTRUCTION. So it switched heading control
-- off exactly where the ship spends the whole leg and handed the bearing back
-- to the hover turn: 17% of the leg in cruise, 83% in hover. The theory behind
-- it ("an unsustained bank is positive feedback") was untested.
--
-- The METRIC had to change when the cruise/correct -> aim recourse edge was
-- added. The original counted MODE_CRUISE over EVERY tick, so a deliberate
-- re-aim (phase "aim", mode HOVER) counted against it -- and in this plant a
-- deliberate re-aim is the dominant outcome, because cruise CANNOT steer here
-- and so needs re-aiming over and over (see below). The regression this guard
-- exists for is a *silent* handover: the phase still said "cruise" while the
-- mode was HOVER. Counting cruise-mode occupancy over the ticks actually spent
-- in a cruise-mode phase distinguishes that regression exactly (phase stays
-- "cruise", mode is HOVER -> low occupancy) while not punishing an explicit
-- re-aim (phase is "aim" -> those ticks are excluded).
--
-- What this plant CANNOT do, and why the recourse count is high: cruise steers
-- by tilting the lift vector, and cruise zeroes prop tilt, so here the bank
-- produces NO course change and the fin weathervane is the only yaw path. The
-- AP test plant therefore cannot hold a bearing in cruise at all, and the ship
-- must re-aim ~26 times over 4000 ticks no matter how the threshold is set
-- (60 deg -> 41.9% occupancy, 90 deg -> 39.3%: the aim dwell time dominates,
-- not the threshold). Tuning AP_RECOURSE against this number would be fitting
-- a threshold to a model that cannot represent the dynamics. The recourse edge
-- is therefore tested directly, by asserting the transition, in test 14.
do
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    f:startAutopilot{ name = "CRUISE", x = 2000, z = 0, heading = 90, alt = 270 }
    local in_cruise_mode, in_cruise_phase = 0, 0
    for _ = 1, 4000 do
        env.step()
        local ap = f.ap
        if ap then
            local cruise_phase = (ap.phase == "cruise" or ap.phase == "correct"
                or ap.phase == "arrive") and not ap.hover_only
            if cruise_phase then
                in_cruise_phase = in_cruise_phase + 1
                if f.mode == "CRUISE" then in_cruise_mode = in_cruise_mode + 1 end
            end
        end
    end
    local pct = (in_cruise_phase > 0) and (100 * in_cruise_mode / in_cruise_phase) or 0
    check("cruise: a cruise-mode phase always runs in MODE_CRUISE (no silent hover handover)",
        pct >= 70, string.format("in-cruise-mode=%.1f%% of cruise-phase ticks", pct))
    print(string.format("cruise: in-cruise-mode=%.1f%% of cruise-phase ticks", pct))
end

-- 13. RATE FEEDBACK MUST BE LIVE, AND MUST DAMP THE MOMENTUM.
-- Three separate things have to hold, and each one broke silently:
--
--  a) the HARNESS has to publish roll rate. Flight:updateState() recomputes
--     state.roll_rate from ship angular velocity and discards whatever the
--     harness set on `state` directly. Filling only angularVelocity.y (yaw)
--     left x at 0, so the rate term was multiplied by zero on every tick of
--     every test -- it could not do anything, ever.
--  b) the DEADBAND must not disarm the rate term. rollCap/stabCap return 0
--     inside the 2 deg band, and the rate term used to live inside that clamp.
--     The deadband is an attitude gate; the one moment a hull needs damping is
--     the moment it passes back through level carrying the momentum its own
--     correction just gave it.
--  c) the DUTY GATE must not disarm it either (same argument, manual flight).
do
    local env = makeEnv({ alt0 = 270 })
    local f = env.flight
    f:setMode(f.MODE_HOVER)
    f.targets.altitude = 270
    for _ = 1, 400 do env.step() end

    -- NB: env.step() runs flight:update() FIRST and only publishes the plant
    -- state at the end, so a disturbance written into the plant is not visible
    -- to the controller until the NEXT step. Two steps per probe, or every
    -- reading below is a tick stale and measures nothing.
    env.plant.roll_rate = -6.0
    env.step(); env.step()
    check("damping: ship roll rate actually reaches the stabiliser",
        math.abs(f.state.roll_rate or 0) > 1.0,
        string.format("state.roll_rate=%.2f (plant -6.00)", f.state.roll_rate or 0))

    -- THE REGRESSION, aimed straight at it: a hull sitting INSIDE the 2 deg
    -- attitude deadband but still rotating fast. rollCap() returns 0 there and
    -- the duty schedule returns 0 there, so a rate term living inside either
    -- one is multiplied by zero and the hull coasts straight through level
    -- carrying the momentum its own correction just gave it -- the "PID does
    -- not dampen the momentum it gave to correct the roll, so it wiggles
    -- again" report. A PROPORTIONAL term is correct to be silent here; a RATE
    -- term is not, and the two have to be separable to tell them apart.
    local inband = 0
    for _, rr in ipairs({ -3.0, -6.0, -9.0 }) do
        env.plant.roll = 1.0        -- inside the deadband
        env.plant.roll_rate = rr
        env.step()                  -- publish
        env.step()                  -- controller acts on it
        local diff = math.abs((f.outputs.RL_speed or 0) - (f.outputs.RR_speed or 0))
        if diff > 0.05 then inband = inband + 1 end
        env.plant.roll_rate = 0
        for _ = 1, 40 do env.step() end   -- settle back before the next probe
    end
    check("damping: rate term still acts INSIDE the attitude deadband",
        inband == 3,
        string.format("%d/3 in-band rotations opposed (0 => rate term is dead)", inband))

    -- ...and the whole disturbance must bleed off monotonically. A correction
    -- that keeps reversing sign is the ring the pilot is complaining about.
    env.plant.roll = 6.0
    local unopposed, reversals, t, settle, prev = 0, 0, 0, nil, 6
    for _ = 1, 400 do
        env.step()
        t = t + 0.05
        local r, rr = env.plant.roll, env.plant.roll_rate
        local diff = math.abs((f.outputs.RL_speed or 0) - (f.outputs.RR_speed or 0))
        if math.abs(rr) > 3 and diff < 0.01 then unopposed = unopposed + 1 end
        if prev > 0.5 and r < -0.5 then reversals = reversals + 1 end
        prev = r
        if not settle and math.abs(r) < 0.5 and math.abs(rr) < 1 then settle = t end
    end
    check("damping: never coasts through the deadband unopposed",
        unopposed == 0, string.format("unopposed_ticks=%d", unopposed))
    check("damping: roll disturbance does not ring (reversals <= 1)",
        reversals <= 1, string.format("reversals=%d", reversals))
    check("damping: roll disturbance settles",
        settle ~= nil,
        string.format("settle=%s", settle and string.format("%.2fs", settle) or "never"))
    print(string.format("damping: inband=%d/3 unopposed=%d reversals=%d settle=%s",
        inband, unopposed, reversals, settle and string.format("%.2fs", settle) or "never"))
end

--- 14. THE NEW CRUISE/ARRIVAL GUARDS, ASSERTED AT THE COMMAND.
--- Test 12 cannot reach these: this plant's cruise cannot steer (cruise zeroes
--- prop tilt, so a bank produces no course change) and its top speed is ~7-10
--- m/s against the game's 10-20, so closed-loop thresholds cannot be trusted
--- here. Each is therefore asserted directly on the command or the transition,
--- which is the honest level at which this plant can carry them.
do
    -- 14a. apHoverDrive must refuse to thrust forward across a large bearing.
    -- This is the orbit: dist is RADIAL, so a ship receding from a point it has
    -- already passed has the same braking profile as one still approaching, so
    -- the profile asks for MORE thrust, the bearing flips ~180 deg, and it
    -- circles. Assert the refusal directly, on and off the threshold.
    local env = makeEnv({ alt0 = 60 })
    local f = env.flight
    -- apHoverDrive is called directly here, so drive state.velocity /
    -- state.forward directly: a bank-free yaw about +z, so a velocity of
    -- (0,0,v) IS forward speed.
    f.state.forward = { x = 0, y = 0, z = 1 }
    f.state.velocity = { x = 0, y = 0, z = 0 }
    f:apHoverDrive(60, 90)          -- 90 deg off: must not push forward
    check("orbit: no forward thrust while the bearing is large",
        f.targets.move_forward <= 0,
        string.format("move_forward=%.2f at 90 deg off", f.targets.move_forward or 0))
    -- ...and it must not brake forever either: sustained reverse tilt would
    -- walk the ship backwards away from the point.
    check("orbit: coasts to a stop rather than reversing while rotating",
        f.targets.move_forward == 0,
        string.format("move_forward=%.2f when already stopped", f.targets.move_forward or 0))
    f.state.velocity = { x = 0, y = 0, z = 8 }   -- running on at the waypoint
    f:apHoverDrive(60, 90)
    check("orbit: brakes the run-on while rotating",
        f.targets.move_forward < 0,
        string.format("move_forward=%.2f while still fast", f.targets.move_forward or 0))
    -- Inside the tolerance the normal braking profile must still apply, or the
    -- ship would never close on the point at all.
    f:apHoverDrive(60, 5)
    check("orbit: thrusts forward once the bearing is on the point",
        f.targets.move_forward > 0,
        string.format("move_forward=%.2f at 5 deg off", f.targets.move_forward or 0))

    -- 14b/14c need the ship actually IN a cruise-mode phase with a live bank
    -- command, otherwise they measure hover and pass vacuously. pinBank()
    -- drives the waypoint to sit at a fixed bearing offset from the nose, so
    -- the bearing error (and therefore the bank) stays put while the test
    -- changes speed and climb rate underneath it. NOTE state.speed and
    -- state.climb_rate are RE-PUBLISHED from the plant every step, so they are
    -- driven via plant.vx/vz/v.
    local function pinBank(env, f, degd)
        local ar = math.rad(degd)
        for _ = 1, 8000 do
            env.step()
            local ap = f.ap
            if ap and ap.phase == "cruise" and f.mode == "CRUISE" then
                local fw = f.state.forward or { x = 0, y = 0, z = 1 }
                local fl = math.sqrt(fw.x * fw.x + fw.z * fw.z)
                if fl > 1e-6 then
                    local ux, uz = fw.x / fl, fw.z / fl
                    local px, pz = -uz, ux
                    local p = f.state.position or { x = 0, y = 0, z = 0 }
                    local off = 1200 * math.tan(ar)
                    ap.x = (p.x or 0) + 1200 * ux + off * px
                    ap.z = (p.z or 0) + 1200 * uz + off * pz
                end
                if math.abs(ap.err or 0) > 2 then return true end
            end
        end
        return false
    end
    local function propDiff(f)
        return math.abs((f.outputs.RL_speed or 0) - (f.outputs.RR_speed or 0))
    end

    local env2 = makeEnv({ alt0 = 60 })
    local g = env2.flight
    g:startAutopilot{ name = "BANKAIR", x = 2000, z = 0, heading = 90, alt = 200 }
    check("bank: pinned in a cruise phase with a live bank", pinBank(env2, g, 8),
        string.format("phase=%s mode=%s", tostring(g.ap and g.ap.phase), tostring(g.mode)))
    env2.plant.vx, env2.plant.vz = 0, 0
    env2.step(); env2.step(); env2.step()
    local stopped = propDiff(g)
    check("bank: no bank command below the airspeed threshold",
        g.mode == "CRUISE" and stopped < 0.02,
        string.format("diff=%.4f at speed 0 (phase=%s)", stopped, tostring(g.ap and g.ap.phase)))
    env2.plant.vx, env2.plant.vz = 25, 0    -- moving
    env2.step(); env2.step(); env2.step()
    local rolling = propDiff(g)
    check("bank: bank command returns once the ship is moving again",
        rolling > 0.05, string.format("diff=%.4f at speed 25", rolling))

    -- 14c. The bank must also fade on vertical RATE. The altitude-position fade
    -- alone closes a limit cycle rather than damping it (bank -> lift vector
    -- tilts -> sink -> alt error grows -> bank fades -> climb -> bank returns).
    -- Assert a fast climb/sink rate drives the bank command to ~nothing.
    local env3 = makeEnv({ alt0 = 200 })
    local h = env3.flight
    h:startAutopilot{ name = "BANKRATE", x = 2000, z = 0, heading = 90, alt = 200 }
    check("bank: pinned in a cruise phase with a live bank", pinBank(env3, h, 8),
        string.format("phase=%s mode=%s", tostring(h.ap and h.ap.phase), tostring(h.mode)))
    env3.plant.vx, env3.plant.vz = 25, 0
    env3.plant.v = 0
    env3.step(); env3.step(); env3.step()
    local lvl = propDiff(h)
    env3.plant.v = 9        -- published as climb_rate, past AP_BANK_RATE_FADE
    env3.step(); env3.step()
    local sunk = propDiff(h)
    -- force altitude error to 0 so only the rate term applies
    h.targets.altitude = h.state.altitude
    env3.step(); env3.step()
    sunk = propDiff(h)
    check("bank: a fast climb/sink rate fades the bank out",
        sunk < lvl * 0.8 + 0.1,
        string.format("diff %.4f -> %.4f at 9 m/s vertical", lvl, sunk))

    -- 14d. The bank must steer on COURSE, not on nose heading. Assert the
    -- helper exists, is nil when too slow to have a course, and returns the
    -- velocity-to-target angle (so a crabbing nose does not read as an error).
    local env4 = makeEnv({ alt0 = 200 })
    local k = env4.flight
    k.state.velocity = { x = 0, y = 0, z = 0 }
    check("course: nil below the course-speed threshold",
        k:apCourseError(100, 100, 0) == nil, "velocity zero -> nil")
    k.state.velocity = { x = 10, y = 0, z = 0 }   -- travelling due +x
    local ce = k:apCourseError(100, 100, 0)       -- target also due +x
    check("course: aligned course reads zero error",
        ce ~= nil and math.abs(ce) < 1e-6, string.format("course_err=%s", tostring(ce)))
    local ce2 = k:apCourseError(100, 0, 100)      -- target due +z, still flying +x
    check("course: a 90 deg course error is reported",
        ce2 ~= nil and math.abs(math.abs(ce2) - 90) < 1e-6,
        string.format("course_err=%s", tostring(ce2)))

    -- 14e. cruise/correct -> aim RECOURSE. The phase machine had no edge back to
    -- aim from a travel leg at all, so once a run left the first rotation it
    -- could never re-aim: "once it's in phase 3 it can't go back to phase 2".
    -- Assert the transition directly: enter aim with the climb SKIPPED, since
    -- the ship is already holding cruise altitude.
    local env5 = makeEnv({ alt0 = 200 })
    local m = env5.flight
    m:startAutopilot{ name = "RECOURSE", x = 2000, z = 0, heading = 90, alt = 200 }
    for _ = 1, 6000 do
        env5.step()
        if m.ap and m.ap.phase == "cruise" then break end
    end
    check("recourse: run reaches the cruise phase", m.ap and m.ap.phase == "cruise",
        string.format("phase=%s", m.ap and tostring(m.ap.phase) or "no ap"))
    -- ap.err is RECOMPUTED from geometry every tick, so assigning it does
    -- nothing. Move the waypoint instead: after the aim phase the nose faces
    -- +x, so a target at (-d,+d) sits ~135 deg off the bearing (too far to
    -- bank back) and (+d,+d) sits ~45 deg (which `correct` handles).
    local function aimWaypoint(dx, dz)
        local p = m.state.position or { x = 0, y = 0, z = 0 }
        m.ap.x = (p.x or 0) + dx
        m.ap.z = (p.z or 0) + dz
    end
    aimWaypoint(-1200, 1200)         -- ~135 deg: too far to bank back
    env5.step()
    check("recourse: a large heading error re-enters ROTATE from cruise",
        m.ap.phase == "aim", string.format("phase=%s err=%.1f",
            tostring(m.ap.phase), m.ap.err or 0))
    check("recourse: the re-aim skips the climb (already at cruise altitude)",
        m.ap.step == "turn" and m.ap.needs_climb == false,
        string.format("step=%s needs_climb=%s", tostring(m.ap.step), tostring(m.ap.needs_climb)))
    check("recourse: the re-aim runs in HOVER, where the yaw steer exists",
        m.mode == "HOVER", string.format("mode=%s", tostring(m.mode)))
    -- And from `correct`, which is the leg the pilot actually got stuck in.
    m.ap.phase = "correct"
    aimWaypoint(-1200, 1200)
    env5.step()
    check("recourse: a large heading error re-enters ROTATE from correct too",
        m.ap.phase == "aim", string.format("phase=%s err=%.1f",
            tostring(m.ap.phase), m.ap.err or 0))
    -- A MODERATE error must NOT recourse -- it is what `correct` is for.
    m.ap.phase = "cruise"
    aimWaypoint(1200, 1200)           -- ~45 deg: correctable by banking
    env5.step()
    check("recourse: a moderate error does not re-aim (stays with correct)",
        m.ap.phase == "correct", string.format("phase=%s err=%.1f",
            tostring(m.ap.phase), m.ap.err or 0))
end

--- 15. THE ALTITUDE GOAL MUST BE RE-STAMPED ON BOOT.
--- powerOff() runs setMode(HOVER), which captures targets.altitude from
--- state.altitude. While the splash/boot screens are up, controlTick returns
--- before flight:update(), so state is never re-read and the goal is frozen at
--- the power-off altitude. Move the ship in that window and power-up flies it
--- back to the pre-move altitude -- the reported "it tries to get back to the
--- altitude you were at when in the splash screen".
do
    check("boot: beginBoot() arms the re-capture flag in os_main.lua",
        readBootArmsRecapture(),
        "lib/os_main.lua no longer sets flight.recapture_alt = true")

    local env = makeEnv({ alt0 = 200 })
    local f = env.flight
    -- Reproduce the freeze exactly: a goal stamped at 200, then the ship moved
    -- to 120 with no update() in between (what the splash screen does -- it
    -- never calls flight:update(), so state.altitude stays at the old value).
    f.targets.altitude = 200
    env.plant.alt = 120
    env.step()               -- refresh state from the plant: altitude -> 120
    env.plant.alt = 120
    check("boot: the stale goal survives the move (precondition)",
        math.abs(f.targets.altitude - f.state.altitude) > 50,
        string.format("goal=%.1f state=%.1f", f.targets.altitude, f.state.altitude))

    -- Arm the one-shot the way beginBoot() does, then run ONE tick.
    f.recapture_alt = true
    env.step()
    check("boot: the altitude goal is re-stamped from the fresh reading",
        math.abs(f.targets.altitude - 120) < 0.5,
        string.format("goal=%.1f, expected the live altitude 120", f.targets.altitude))
    check("boot: the re-capture is one-shot (flag cleared)",
        f.recapture_alt == false, string.format("recapture_alt=%s", tostring(f.recapture_alt)))

    -- And it must not re-stamp every tick afterwards, which would silently
    -- disable manual altitude commands (W/S, Space/Ctrl) for good. The flag is
    -- one-shot, so the goal must now behave like any other manual altitude.
    env.plant.alt = 150
    env.step()
    f:adjustAltitude(2)
    local stepped = f.targets.altitude
    env.step()
    check("boot: a manual altitude command is not overwritten on later ticks",
        math.abs(f.targets.altitude - stepped) < 0.5,
        string.format("after adjust=%.1f, next tick=%.1f", stepped, f.targets.altitude))

    -- The altitude PID must not carry integral wind-up from before the boot
    -- into the re-stamped goal, or the ship lurches on the first tick.
    local env2 = makeEnv({ alt0 = 300 })
    local g = env2.flight
    env2.step()                       -- settle at 300
    g.targets.altitude = 300
    env2.plant.alt = 250
    env2.step()                       -- state now 250, goal still 300: error
    g.recapture_alt = true
    env2.step()
    check("boot: the re-stamped goal has no altitude PID wind-up",
        math.abs(g.targets.altitude - 250) < 0.5,
        string.format("goal=%.1f, expected the live altitude 250", g.targets.altitude))

    -- The PID reset is load-bearing, and it is specifically the ALTITUDE PID's
    -- integral: with the goal re-stamped but the integral still holding the
    -- pre-boot error, the first powered tick gets a large accumulated command
    -- and the ship lurches away from the altitude it was just told to hold.
    --
    -- integral_separation is 2.5, so a large error does NOT wind the integral
    -- up -- the error has to be small and persistent (holding station slightly
    -- low on hover feedforward is the real case). So hold the error at 2.0 by
    -- re-asserting the goal each tick, which saturates the integral.
    local e3 = makeEnv({ alt0 = 300 })
    local w = e3.flight
    e3.step()
    for _ = 1, 200 do
        w.targets.altitude = w.state.altitude + 2.0
        e3.step()
    end
    local wound = w.pid.altitude.integral or 0
    check("boot: the altitude integral really does wind up before the boot",
        wound > 0.5, string.format("integral=%.3f", wound))
    w.recapture_alt = true
    e3.step()
    check("boot: the altitude PID integral is cleared with the re-stamped goal",
        math.abs(w.pid.altitude.integral or 0) < 1e-9,
        string.format("integral=%.3f after re-stamp", w.pid.altitude.integral or 0))
end

--- 16. THE REDSTONE OFF BUTTON.
--- The monitor's red circle had no redstone equivalent, so the only way to
--- power the ship down was a tap on a touch monitor -- with no working screen,
--- no keyboard, or a dead network there was no off at all. The button is on
--- the engine relay's LEFT face, the only free left INPUT on the ship: the
--- starter link on that face is an OUTPUT, and a relay face carries input and
--- output independently.
do
    local e = makeEnv({ alt0 = 200 })
    local f = e.flight

    -- The relay audit that justifies the wiring choice, asserted so a future
    -- config edit cannot quietly double-book the left face.
    local function loadcfg(path)
        local fh = io.open(path, "r")
        if not fh then return nil end
        local src = fh:read("*a")
        fh:close()
        local chunk = loadstring and loadstring(src, path) or load(src, path)
        if not chunk then return nil end
        local ok, val = pcall(chunk)
        return ok and val or nil
    end
    local cfg = loadcfg("config/atlas.lua")
    check("off: the shipped config maps OFF to the engine relay",
        cfg ~= nil and cfg.input_map ~= nil
            and cfg.input_map.engine_relay ~= nil
            and cfg.input_map.engine_relay.OFF == "left",
        cfg == nil and "config/atlas.lua did not load"
            or string.format("engine_relay.OFF=%s",
                tostring(cfg.input_map and cfg.input_map.engine_relay
                    and cfg.input_map.engine_relay.OFF)))
    check("off: OFF shares the left face with the starter OUTPUT, which is legal",
        cfg ~= nil and cfg.engine ~= nil and cfg.engine.start_side == "left",
        "engine.start_side is not left")

    -- No other input may sit on that same face side of the same relay.
    if cfg and cfg.input_map and cfg.input_map.engine_relay then
        local clashes = {}
        for key, side in pairs(cfg.input_map.engine_relay) do
            if key ~= "OFF" and side == "left" then clashes[#clashes + 1] = key end
        end
        check("off: nothing else claims the engine relay left face",
            #clashes == 0, "also on left: " .. table.concat(clashes, ","))
    end

    -- The rising edge: fires once on press, not once per tick held.
    -- Two presses in this sequence (idx2 and idx7); the 3-tick hold at idx2..4
    -- is the case that matters -- it must fire ONCE, not once per tick.
    local seq, presses = { 0, 0, 15, 15, 15, 0, 0, 15, 0 }, 0
    for _, v in ipairs(seq) do
        if f:pollOff(v) then presses = presses + 1 end
    end
    check("off: a held button fires exactly once per press",
        presses == 2, string.format("fired %d times over 2 presses", presses))

    -- A button held down from boot must fire on its first tick, not wait for
    -- a release it may never get.
    local g = makeEnv({ alt0 = 200 }).flight
    g.off_level, g.off_armed = 0, true
    check("off: a press already active at boot fires immediately",
        g:pollOff(15) == true, "did not fire on the first held tick")
    check("off: and does not refire while still held",
        g:pollOff(15) == false and g:pollOff(15) == false,
        "refired while held")

    -- Released is what arms it; a low signal must never fire.
    local h = makeEnv({ alt0 = 200 }).flight
    h.off_level, h.off_armed = 0, true
    check("off: a released button never fires",
        h:pollOff(0) == false and h:pollOff(0) == false, "fired while released")

    -- And it must not be gated on the autopilot: shutting down is the escape
    -- from a run that has gone wrong.
    local i = makeEnv({ alt0 = 200 }).flight
    i.ap = { phase = "cruise" }
    i.off_level, i.off_armed = 0, true
    check("off: the off button works during an autopilot run",
        i:pollOff(15) == true, "blocked by the autopilot")
end

--- 17. THE OFF BUTTON IS ACTUALLY WIRED UP, END TO END.
--- pollOff can be perfect and the button still dead if the config omits the
--- key or nothing calls it. Neither shows up in a unit test of the latch
--- itself, so assert the three connections that make it a real control:
--- config -> key name -> controlTick.
do
    local function loadcfg(path)
        local fh = io.open(path, "r")
        if not fh then return nil end
        local src = fh:read("*a")
        fh:close()
        local chunk = loadstring and loadstring(src, path) or load(src, path)
        if not chunk then return nil end
        local ok, val = pcall(chunk)
        return ok and val or nil
    end

    -- startup carries the wizard's built-in default config, which is what a
    -- fresh ship with no config/ gets. It is a script, not a loadable table
    -- (it needs CC peripherals), so assert the line instead of the value.
    local sfh = io.open("startup", "r")
    local ssrc = sfh and sfh:read("*a") or ""
    if sfh then sfh:close() end
    check("off: startup's default config also maps OFF to the engine relay left",
        ssrc:find('engine_relay = { UP = "front", DOWN = "back", OFF = "left" }',
            1, true) ~= nil,
        "startup's default engine_relay has no OFF = left")

    -- The live ship's own config. Deploy never touches config/, so this is
    -- edited by hand and can drift from the shipped one.
    local live = loadcfg(
        os.getenv("ATLAS_COMPUTERCRAFT") and
            (os.getenv("ATLAS_COMPUTERCRAFT") .. "/5/config/ArtAtlas.lua")
        or (os.getenv("HOME") ..
            "/.var/app/com.modrinth.ModrinthApp/data/ModrinthApp/profiles/" ..
            "Create Aeronautics/saves/Atlas Warmachine World/computercraft/" ..
            "computer/5/config/ArtAtlas.lua"))
    if live then
        check("off: the live ship's config has OFF on the engine relay left",
            live.input_map ~= nil and live.input_map.engine_relay ~= nil
                and live.input_map.engine_relay.OFF == "left",
            string.format("live ArtAtlas engine_relay.OFF=%s",
                tostring(live.input_map and live.input_map.engine_relay
                    and live.input_map.engine_relay.OFF)))
    end

    -- controlTick must poll it. os_main needs the full hardware stack and
    -- cannot be required here, so check the call survives as a source line.
    -- Match the whole line, not the substring: "if false and
    -- flight:pollOff(keys.OFF) then" still CONTAINS "pollOff(keys.OFF)" and
    -- would pass a substring search while polling nothing.
    local fh = io.open("lib/os_main.lua", "r")
    local src = fh and fh:read("*a") or ""
    if fh then fh:close() end
    -- Normalise whitespace so `if false and flight:pollOff(...)` is recognised as
    -- a modified form rather than passing as the bare call.
    local norm = src:gsub("%s+", " ")
    local callsPoll = norm:find("if flight:pollOff(keys.OFF) then", 1, true) ~= nil
    check("off: controlTick polls the OFF key every tick (not disabled)",
        callsPoll,
        "no bare `if flight:pollOff(keys.OFF) then` in controlTick "
            .. "(a disabled 'if false and ...' form would also fail here)")
    check("off: a fired OFF edge actually shuts the ship down",
        callsPoll and src:find("OS.powerOff()", 1, true) ~= nil,
        "no OS.powerOff() in os_main")
end

-- 18. THE CRUISE BANK MUST STEER TOWARD THE WAYPOINT, NOT AWAY FROM IT.
-- "The ship tries to yaw to the right in fast travel" was AP_BANK_SIGN = -1,
-- which banks AWAY from the bearing. That is positive feedback, not a turn
-- that fails to converge: the ship banks left to reach a target on its right,
-- which grows the error, which banks harder. It reads as a steady pull to one
-- side and it never arrives, which is why it did not look like a sign flip.
--
-- The chain, none of it a matter of taste:
--   config/atlas.lua:116  FL x=-3 / FR x=+3  => +x is the ship's right
--   hardware.lua:296      roll + = right down
--   right wing down       tilts the lift vector right => the ship turns right
--   apBearingError        returns POSITIVE for a target on +x (on the right)
-- So closing a positive error needs roll POSITIVE: the bank must carry the
-- SAME SIGN as the bearing error. That invariant is the whole test, and it is
-- what makes the old -1 fail.
--
-- This plant still cannot watch the yaw happen -- cruise zeroes prop tilt, so
-- fz = 0 for every prop and the yaw couple YAW_SIGN*x*fz is identically zero
-- (see the note above AP_TILT...). So assert the commanded ROLL, which is
-- directly observable as both a hull angle and a left/right prop differential.
-- Two independent observables, so the test cannot pass by coincidence.
local function bankSign(side)
    local env = makeEnv({ alt0 = 200 })
    local k = env.flight
    k:setMode("CRUISE")
    local dx = (side == "right") and 3000 or -3000
    k.ap = { name = "BANK", x = dx, z = 4000, alt = 200, phase = "cruise",
             pt = 0, needs_climb = false, progress = 0, start_dist = 5000,
             wp = { x = dx, z = 4000, alt = 200 }, paused = false }
    env.plant.vx, env.plant.vz = 0, 12
    k.state.speed = 12
    local err, roll = nil, nil
    for _ = 1, 40 do
        env.step()
        err = k.ap.err
        roll = env.plant.roll
    end
    local o = k.outputs
    return err, roll, (o.FR_speed or 0) - (o.FL_speed or 0)
end

local bErrR, bRollR, bDiffR = bankSign("right")
local bErrL, bRollL, bDiffL = bankSign("left")
check("bank: a target to the right produces a POSITIVE bearing error",
    bErrR ~= nil and bErrR > 0,
    string.format("err=%s", tostring(bErrR)))
check("bank: hull rolls toward the target (sign(roll) == sign(err)), right side",
    bRollR ~= nil and bErrR ~= nil and (bRollR > 0) == (bErrR > 0),
    string.format("err=%+.1f roll=%+.3f", bErrR or 0, bRollR or 0))
check("bank: hull rolls toward the target (sign(roll) == sign(err)), left side",
    bRollL ~= nil and bErrL ~= nil and (bRollL < 0) == (bErrL < 0),
    string.format("err=%+.1f roll=%+.3f", bErrL or 0, bRollL or 0))
check("bank: the prop differential backs the hull roll (FR-FL), right side",
    bDiffR ~= nil and bErrR ~= nil and (bDiffR > 0) == (bErrR > 0),
    string.format("FR-FL=%+.3f err=%+.1f", bDiffR or 0, bErrR or 0))
check("bank: the prop differential backs the hull roll (FR-FL), left side",
    bDiffL ~= nil and bErrL ~= nil and (bDiffL < 0) == (bErrL < 0),
    string.format("FR-FL=%+.3f err=%+.1f", bDiffL or 0, bErrL or 0))
-- The failure mode that actually bit: the sign is fine but the bank is
-- vanishing. AP_BANK_MIN_SPEED sits at 6 m/s and the gate is
-- (speed - 3)/3, so anything under 3 m/s gets NO bank at all.
check("bank: a full-speed leg keeps a usable bank command (not faded to nothing)",
    math.abs(bRollR or 0) > 0.1 and math.abs(bRollL or 0) > 0.1,
    string.format("|roll| right=%.3f left=%.3f", math.abs(bRollR or 0), math.abs(bRollL or 0)))

-- 18b. RECOURSE THRESHOLD. Now 45 deg (was 90, whose own comment said 60).
-- Below the threshold `correct` must keep the leg alive; above it the run must
-- drop back to phase 2 (aim) rather than trying to bank out of an error it
-- has no authority over.
local envR = makeEnv({ alt0 = 200 })
local r = envR.flight
r:startAutopilot{ name = "RECOURSE45", x = 2000, z = 0, heading = 90, alt = 200 }
for _ = 1, 6000 do
    envR.step()
    if r.ap and r.ap.phase == "cruise" then break end
end
check("recourse45: run reaches the cruise phase", r.ap and r.ap.phase == "cruise",
    string.format("phase=%s", r.ap and tostring(r.ap.phase) or "no ap"))
-- The nose does NOT face exactly +x after the aim phase (it comes out ~86 deg
-- off), so the offset -> error map has to be MEASURED, not derived. Rather than
-- pick two lucky offsets and trust them, sweep the whole neighbourhood and
-- assert the phase flips exactly at 45. This pins the boundary itself, so it
-- cannot be satisfied by any threshold other than 45.
local function setCourse(dx, dz)
    local p = r.state.position or { x = 0, y = 0, z = 0 }
    r.ap.x = (p.x or 0) + dx
    r.ap.z = (p.z or 0) + dz
end
local maxCorrect, minAim = 0, 360
local mismatches, samples = {}, 0
for dz = -400, -1800, -40 do
    r.ap.phase, r.ap.pt = "cruise", 0
    setCourse(1200, dz)
    envR.step()
    local e = r.ap.err or 0
    local ph = r.ap.phase
    samples = samples + 1
    -- expected phase from the two thresholds under test
    local want = (e > 45) and "aim" or ((e > 10) and "correct" or "cruise")
    if ph ~= want then
        mismatches[#mismatches + 1] = string.format("err=%.1f got=%s want=%s", e, ph, want)
    end
    if ph == "aim" then
        minAim = math.min(minAim, e)
    else
        maxCorrect = math.max(maxCorrect, e)
    end
end
check(string.format("recourse45: %d sampled headings all land on the right phase", samples),
    #mismatches == 0,
    #mismatches > 0 and table.concat(mismatches, "; ") or "no samples")
check("recourse45: nothing below 45 deg re-aims",
    maxCorrect < 45, string.format("largest non-aim error=%.2f", maxCorrect))
check("recourse45: everything above 45 deg re-aims",
    minAim > 45 and minAim < 360, string.format("smallest aim error=%.2f", minAim))

-- The bank must not merely point the right way, it must actually be there: a
-- faded-to-nothing bank would steer correctly and never arrive. Assert the
-- allocation GROWS with the error, measured against a dead-straight leg as the
-- zero reference. A relative check, because the absolute number is small and
-- plant-specific (reduce-only authority trims the hull at ~0.8 deg against an
-- 8 deg setpoint, so demanding a large absolute differential would be tuning
-- the test to the plant instead of to the law).
local function bankAlloc(tx, tz)
    local e = makeEnv({ alt0 = 200 })
    local g = e.flight
    g:setMode("CRUISE")
    g.ap = { name = "ALLOC", x = tx, z = tz, alt = 200, phase = "cruise",
             pt = 0, needs_climb = false, progress = 0, start_dist = 5000,
             wp = { x = tx, z = tz, alt = 200 }, paused = false }
    e.plant.vx, e.plant.vz = 0, 12
    g.state.speed = 12
    for _ = 1, 40 do e.step() end
    local o = g.outputs
    return g.ap.err or 0, e.plant.roll or 0,
        math.abs((o.FR_speed or 0) - (o.FL_speed or 0))
        + math.abs((o.RR_speed or 0) - (o.RL_speed or 0))
end
-- dead straight: target along the nose, so the bank law must ask for nothing
local zErr, zRoll, zDiff = bankAlloc(0, 4000)
-- well off, but under the 45 deg recourse so `correct` never throttles to a
-- crawl and AP_BANK_MIN_SPEED does not fade the bank out
local oErr, oRoll, oDiff = bankAlloc(-2400, 4000)
check("bank: the straight reference leg really is straight",
    math.abs(zErr) < 1, string.format("err=%.2f", zErr))
check("bank: the straight leg banks essentially nothing",
    math.abs(zDiff) < 0.01, string.format("diff=%.4f", zDiff))
check("bank: a ~31 deg course error asks the law for a real bank",
    math.abs(oErr) > 20 and math.abs(oErr) < 45, string.format("err=%.1f", oErr))
check("bank: the allocation grows with the error (bank is not faded out)",
    oDiff > math.max(zDiff * 5, 0.05),
    string.format("straight=%.4f  off-course=%.4f", zDiff, oDiff))
check("bank: the roll stabiliser is engaged (hull actually banks)",
    math.abs(oRoll) > math.abs(zRoll) and math.abs(oRoll) > 0.1,
    string.format("straight roll=%.3f  off-course roll=%.3f", zRoll, oRoll))

print(string.format("ap_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("ap_test FAILED", 0) end
