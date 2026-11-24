-- v2 tuning knobs. Wiring (relays, sides, peripherals) is NOT here: v2 reads
-- the ship's existing config/<slot>.lua + config/assignments_<slot>.lua, so
-- both OS versions drive the exact same hardware. Everything in this file is
-- behaviour. Per-ship overrides: v2/data/tune_local.lua (same shape, only the
-- keys you change).
return {
    physics = {
        gravity = 11,        -- m/s^2 (Create Aeronautics)
        press_k = 0.004,     -- air pressure e^(-k (y - ref))
        press_ref = 63,
        airflow = 25,        -- m/s through the props (1 - v/airflow term)
        tilt_deg = 25,       -- fixed prop tilt angle when a tilt face is on
        tilt_lag = 0.2,      -- s the tilt mechanism takes to swing (lift
                             -- compensation follows it, not the command)
    },

    -- Vertical channel: altitude -> climb-rate setpoint -> lift.
    vertical = {
        alt_gain = 0.8,      -- (m/s) per m of altitude error
        brake_accel = 1.5,   -- m/s^2 used to shape the stop onto a target
        climb_max = 6,       -- m/s
        sink_max = 5,        -- m/s
        rate_gain = 1.2,     -- (m/s^2) per (m/s) of climb-rate error
        rate_int = 0.35,     -- integral on climb-rate error
        int_limit = 3,       -- m/s^2
        hover_learn = true,  -- learn the real hover throttle in flight
        hover_learn_tau = 25,-- s
    },

    -- Pitch/roll stabiliser: prop speed DIFFERENCES, applied symmetrically
    -- (one side up, the other down) so a correction never costs lift.
    attitude = {
        kp = 0.20,           -- prop units per degree
        kd = 1.5,            -- prop units per deg/s (heavy damping: a big hull
                             -- carries momentum, so brake the swing early)
        ki = 0.03,           -- prop units per degree-second (hull trim)
        -- ROLL has its own gains: the hull is long and narrow, so it rolls
        -- much more easily than it pitches; pitch-level damping (kd 1.5) made
        -- the roll axis oscillate in the sim when it is 4-8x lighter.
        roll = { kp = 0.20, kd = 0.6 },
        int_limit = 3,
        max_corr = 5,        -- prop units per axis
        deadband = 0.3,      -- degrees (P term only)
        rate_tau = 0.08,     -- s smoothing on the measured rates
        reserve = 2,         -- prop units of lift the stabiliser may borrow
        slew = 8,            -- prop units per second a prop speed may change
    },

    -- Heading: binary prop tilt (any signal = full 25 deg) modulated in time.
    yaw = {
        heading_gain = 1.0,  -- (deg/s) per deg of heading error
        brake_accel = 2.5,   -- deg/s^2 assumed when stopping a turn (conservative:
                             -- a stronger ship just turns at rate_max)
        rate_max = 15,       -- deg/s
        hold_band = 1.5,     -- deg: hands-off heading this close = leave the tilts alone
        rate_gain = 0.15,    -- tilt duty per deg/s of rate error
        rate_int = 0.02,     -- integral: learns constant turning torques
        int_limit = 0.6,
        manual_rate = 20,    -- deg/s while Q/E held
        sign = 1,            -- flip if Q/E turn the wrong way
    },

    -- Prop tilt is on/off and a tilt flip on props this size is a big torque
    -- kick, so tilts are pulses with hysteresis: engage above `on`, release
    -- below `off`, held at least min_on / min_off seconds. The ship coasts on
    -- momentum between pulses.
    tilt = {
        on = 0.35,           -- demand (0..1) that engages a tilt
        off = 0.1,           -- demand below which it releases
        min_on = 0.8,        -- s a tilt stays engaged at least
        min_off = 1.5,       -- s a side stays level before tilting again
    },

    -- HOVER, hands off: stay level, and the REAR thruster cancels fore/aft
    -- drift. No position or heading hold: the ship cannot strafe.
    hover = {
        brake = true,        -- rear-thruster braking when hands off (AUTO BRAKE)
        rear_on = 0.5,       -- m/s of fore/aft drift that starts the braking
        rear_off = 0.15,     -- m/s under which it stops
        rear_gain = 3,       -- rear levels per m/s of drift
        rear_max = 10,       -- rear level cap while braking
        fwd_gain = 0.3,      -- tilt demand per m/s (autopilot hover travel)
        fwd_dead = 0.25,     -- m/s
        lat_gain = 0.12,     -- (unused by default: no sideways correction)
        lat_max = 2,
        tilt_sign = 1,       -- flip if W moves the ship backwards
    },

    cruise = {
        ramp = 4,            -- rear levels per second (rising only)
        bank_gain = 0.25,    -- degrees of bank per degree of heading error
        bank_max = 6,
        manual_turn = 12,    -- deg/s of heading change while Q/E held
    },

    landing = {
        decel = 1.2,         -- m/s^2 braking budget inside sensor range
        touch_rate = 0.8,    -- m/s final sink
        sink_accel = 1.0,    -- m/s^2 sink ramp-in
        ground_ticks = 4,    -- sensor at 15 this many ticks = touchdown
        stall_rate = 0.25,   -- m/s: not moving while asked to sink...
        stall_time = 2.5,    -- ...for this long (x3 if the sensor sees nothing)
        settle_time = 1.0,   -- s at creep after touchdown before "landed"
        creep = 1,           -- parked prop speed
    },

    autopilot = {
        cruise_alt = 230,    -- preferred travel altitude (capped by lift)
        lift_margin = 3.5,   -- prop units kept free at cruise altitude
        hop_range = 400,     -- m: closer than this = slow, low hop
        hop_climb = 20,      -- m above start altitude for hops
        cruise_speed = 40,   -- m/s cap
        hop_speed = 8,       -- m/s cap for hops
        creep_speed = 3,     -- m/s cap when creeping back after a miss
        cruise_brake = 1.0,  -- m/s^2 assumed when planning the stop (rear reverse)
        stop_margin = 2,     -- m: plan to stop this short of the point
        face_r = 40,         -- m: closer than this, no more steering (straight in)
        retry_r = 10,        -- m: stopped further than this = re-aim and creep
        retries = 2,
        speed_gain = 0.8,    -- rear levels per m/s of speed error
        speed_int = 0.15,
        turn_limit = 45,     -- deg off course in cruise: stop and turn
        arrive_r = 4,        -- m
        heading_tol = 4,     -- deg
        shutdown_on_land = true,
        phase_timeout = 240, -- s per phase
    },

    unflip = {
        detect_time = 0.75,  -- s upside down before acting (lift is cut
                             -- at once: upside down it pushes the ship DOWN)
        timeout = 20,
        drive = 7,           -- prop units of righting differential
    },

    ui = {
        fps = 5,             -- monitor refresh rate
        palette = true,      -- set the v2 colour palette on the monitor
    },
}
