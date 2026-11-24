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
        kp = 0.30,           -- prop units per degree
        kd = 0.32,           -- prop units per deg/s
        ki = 0.06,           -- prop units per degree-second (hull trim)
        int_limit = 3,
        max_corr = 5,        -- prop units per axis
        deadband = 0.3,      -- degrees (P term only)
        rate_tau = 0.08,     -- s smoothing on the measured rates
        reserve = 2,         -- prop units of lift the stabiliser may borrow
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
        dwell_ticks = 3,     -- min ticks a tilt state is held (servo-friendly)
        sign = 1,            -- flip if Q/E turn the wrong way
    },

    -- Fore/aft and sideways in HOVER.
    hover = {
        brake = true,        -- hands off = hold position (tilt + bank damping)
        fwd_gain = 0.15,     -- tilt duty per m/s of fore/aft speed error
        fwd_dead = 0.25,     -- m/s
        lat_gain = 0.3,      -- degrees of bank per m/s of sideways drift
        lat_max = 4,         -- degrees
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
        hop_range = 400,     -- m: closer than this = hover travel only
        hop_climb = 20,      -- m above start altitude for hover hops
        approach_r = 90,     -- m: cruise hands over to hover approach
        cruise_speed = 40,   -- m/s cap
        cruise_brake = 1.2,  -- m/s^2 assumed when planning the slow-down
        hover_speed = 12,    -- m/s cap for hover travel/approach
        hover_brake = 1.5,   -- m/s^2 assumed for tilt braking
        speed_gain = 0.8,    -- rear levels per m/s of speed error
        speed_int = 0.15,
        turn_limit = 45,     -- deg off course in cruise: stop and turn
        arrive_r = 2.5,      -- m
        arrive_speed = 0.6,  -- m/s
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
