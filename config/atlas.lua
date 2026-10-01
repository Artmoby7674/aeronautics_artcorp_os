return {
    name = "Atlas",
    version = "1.2", -- bump forces full peripheral re-wizard when assignments are older

    -- Offset of computer from center of mass (in blocks)
    -- Positive X = right, Positive Y = up, Positive Z = forward
    computer_offset = { x = 0, y = 6, z = 0 },

    -- Feature flags: OS only offers / runs what the ship actually has.
    -- Multi-ship packs flip these off without changing OS code.
    features = {
        hud = true,
        gear = true,
        auto_land = true,
        cruise_mode = true,
        engine_auto_start = true, -- boot sequence: starter pulse + clutch
        clutch = true,
        fuel_level = false,       -- reserved: fuel container item count later
        rear_reverse = true,      -- REAR relay reverse face (auto-land fore/aft hold)
    },

    -- Engine start + clutch (one relay, two faces)
    -- Boot: starter (left) high for start_seconds, wait clutch_delay, clutch (right) high.
    -- Shutdown (grounded power button): clutch off. Starter always off when not booting.
    engine = {
        relay_key = "engine_relay",
        start_side = "left",
        clutch_side = "right",
        start_seconds = 3,
        clutch_delay = 1,   -- after starter stops
        boot_seconds = 5,   -- total loading bar length
        active = 15,
        inactive = 0,
    },

    -- Reserved for later fuel-container readout (do not wire yet)
    fuel = {
        type = "charcoal",
        smelt_time = 80,
        items_per_smelt = 8,
        tank_capacity = 12960,
        -- inventory_key = nil, -- peripheral that will report item counts
        -- container_slot = nil,
    },

    -- Wired network device names (target names for the setup wizard)
    peripherals = {
        input_1 = "relay_1",     -- WASD
        input_2 = "relay_2",     -- Q/E/Space/Ctrl
        aux_relay = "relay_aux", -- shift + gear + proximity
        engine_relay = "relay_eng", -- engine start (L) + clutch (R)
        output_FL = "relay_3",
        output_FR = "relay_4",
        output_RL = "relay_5",
        output_RR = "relay_6",
        output_REAR = "relay_7",
        main_monitor = "main_monitor",
    },

    -- Which side of each input relay has which key's link
    input_map = {
        input_1 = {
            W = "front",
            S = "back",
            A = "left",
            D = "right",
        },
        input_2 = {
            Q = "left",
            E = "right",
            SPACE = "front",
            CTRL = "back",
        },
        aux_relay = {
            SHIFT = "left",
            PROX = "back",
        },
        engine_relay = {
            UP = "front",
            DOWN = "back",
            -- LEFT face input. The starter link on this face is an OUTPUT
            -- (engine.start_side), and a relay face carries input and output
            -- independently, so the OFF button can share the face.
            OFF = "left",
        },
    },

    gear_output = {
        relay = "aux_relay",
        side = "front",
        deploy = 15,
        retract = 0,
    },

    proximity = {
        input_key = "aux_relay",
        side = "back",
        landed_threshold = 15,
        gear_deploy_threshold = 1,
        max_blocks = 15,
        -- Sensor rides on the front gear bottom; deploying drops it ~6 blocks
        -- closer for a moment. Wait this many 20Hz ticks before trust landed.
        gear_settle_ticks = 20,
    },

    output_map = {
        -- Slow-down link: left props use relay left face, right props right face
        FL   = { relay = "output_FL", tilt_fwd = "front", tilt_bwd = "back", speed = "left" },
        FR   = { relay = "output_FR", tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        RL   = { relay = "output_RL", tilt_fwd = "front", tilt_bwd = "back", speed = "left" },
        RR   = { relay = "output_RR", tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        REAR = { relay = "output_REAR", fw = "front", bw = "back", rev = "top" },
    },

    propellers = {
        FL = { x = -3, y = 0, z = 3 },
        FR = { x = 3,  y = 0, z = 3 },
        RL = { x = -3, y = 0, z = -3 },
        RR = { x = 3,  y = 0, z = -3 },
    },

    -- Create Aeronautics gravity (wiki: F/m across several blocks) = 11 m/s².
    -- Altitude PID is designed around this: plant gain k ≈ g / hover_throttle
    -- (speed units → m/s²) with ζ ≈ 0.8 so hover does not wobble.
    physics = {
        gravity = 11, -- m/s²
    },

    limits = {
        max_speed = 80,
        -- NOT the flight ceiling. The real one depends on hover_throttle,
        -- hover_max_speed and how dense the world's air is at altitude, so the
        -- autopilot discovers it at runtime: climb past the 280 floor until
        -- the lift props are down to 13 of 15. This is only an operator cap
        -- on commanded altitude, set above anything the ship can reach.
        max_altitude = 450,
        min_altitude = 0,
        max_tilt = 15,
        max_climb_rate = 10,
        max_descent_rate = 5,
        hover_speed = 2,
        tilt_max = 12,
        hover_min_speed = 0,
        hover_max_speed = 15,
        -- Thrust that cancels m*g at rest (feedforward). Must be accurate or
        -- the integral has to make up the difference (slow drift then overshoot).
        hover_throttle = 6,
        land_descent_rate = 12.0,
        alt_step = 5,
        cruise_rear = 12,
        cruise_ramp = 8,             -- speed units/s while W/S held in cruise
        cruise_speed_deadband = 1.5, -- ± this speed: hold rear thrust (air resistance)
        landed_creep = 1,            -- parked prop speed (slow-down wire 14)
    },

    pid = {
        -- Altitude from g=11, hover=6 → k = 11/6; ωn=0.8, ζ=0.8:
        --   kp = ωn²/k ≈ 0.35, kd = 2ζωn/k ≈ 0.70
        -- D on climb_rate (no step kick); I only near target (anti-windup).
        altitude = { kp = 0.35, ki = 0.08, kd = 0.70, integral_limit = 8, output_limit = 7,
            d_on_measurement = true, integral_separation = 2.5 },
        pitch    = { kp = 2.0, ki = 0.0, kd = 1.0, integral_limit = 5, output_limit = 6 },
        roll     = { kp = 2.0, ki = 0.0, kd = 1.0, integral_limit = 5, output_limit = 6 },
        yaw      = { kp = 2.2, ki = 0.0, kd = 1.4, integral_limit = 5, output_limit = 15 },
    },

    signal = {
        max = 15,
        min = 0,
    },

    -- Assigned at boot if present in peripherals but not yet mapped
    optional_peripherals = { "aux_relay", "engine_relay" },
}
