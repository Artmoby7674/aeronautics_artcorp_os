local function loadLib(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    local path = (name:gsub("%.", "/")) .. ".lua"
    local fn = loadfile(path)
    if fn then
        local ok2, res = pcall(fn)
        if ok2 then return res end
        error(res, 0)
    end
    error(mod, 0)
end

local PID = loadLib("lib.pid")

local Flight = {}
Flight.__index = Flight

Flight.MODE_HOVER = "HOVER"
Flight.MODE_CRUISE = "CRUISE"

Flight.LAND_IDLE = "IDLE"
Flight.LAND_ARMED = "ARMED"       -- gear deploying / starting descent
Flight.LAND_DESCEND = "DESCEND"   -- auto-landing descent
Flight.LAND_TOUCH = "TOUCH"       -- ground contact
Flight.LAND_DONE = "LANDED"

-- Normalize degrees to (-180, 180]
local function wrapDeg(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

Flight.wrapDeg = wrapDeg

-- Shortest signed rotation from current to target (degrees)
local function angleError(target, current)
    return wrapDeg(target - current)
end

Flight.angleError = angleError

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Body rates (Sable usually rad/s; Create Avionics may report deg/s)
local function rateDps(v)
    if type(v) ~= "number" then return 0 end
    if math.abs(v) <= (2 * math.pi + 0.75) then
        return math.deg(v)
    end
    return v
end

-- ============================================================
-- Stability duty cycle (time-domain precision)
-- ============================================================
-- Correction strength is quantized (integer prop-speed units), so precision
-- comes from duration instead: corrections fire as short pulses on a fixed
-- window, with duty (on-time fraction) growing with attitude error.
local STAB_PERIOD = 0.6 -- s per pulse window

-- ============================================================
-- Auto-unflip: near-or-at inverted for > INV_HOLD seconds
-- ============================================================
local INV_ATT = 165        -- deg: "near or at 180"
local INV_HOLD = 5         -- s spent inverted before the sequence starts
local INV_KICK = 1.5       -- s of reversed/full/opposite-cut kick
local INV_RISE = 4         -- s of pure ascent (uniform full) before the drive
local INV_REVERSE_OFF = 90 -- deg: drop the reverse link below this attitude
local INV_DONE = 10        -- deg: sequence complete
local INV_TIMEOUT = 20     -- s hard abort (reverse off, normal law resumes)
local INV_COOLDOWN = 5     -- s before detection re-arms after a run

-- Kick: cut the pair on the OPPOSITE side of the flip. Flip a sign here if
-- the ship kicks the wrong way in-game.
local UNFLIP_ROLL_CUT = 1  -- roll >= 0 (rolled right) -> cut LEFT, else RIGHT
local UNFLIP_PITCH_CUT = 1 -- pitch >= 0 (went over forward) -> cut REAR, else FRONT

-- Drive: violent righting law (no deadband, no gentle cap). Torque polarity
-- inverts while the lift props run reversed, hence the sign switch.
local UNFLIP_KP = 6
local UNFLIP_KD = 1.5
local UNFLIP_DRIVE_POL = -1 -- -1 = reversed-thrust regime (flip if wrong way)

local function pickUnflipCut(pitch, roll)
    if math.abs(roll) >= math.abs(pitch) then
        if roll * UNFLIP_ROLL_CUT >= 0 then return "left" end
        return "right"
    end
    if pitch * UNFLIP_PITCH_CUT >= 0 then return "rear" end
    return "front"
end

-- ============================================================
-- Auto-landing assists
-- ============================================================
local LAND_GROUND_TICKS = 4 -- consecutive ticks at landed_thr before latch
local LAND_FA_KP = 2        -- fore-aft rear hold thrust gain (gentle)
local LAND_FA_DEAD = 0.3    -- m/s deadband (rear chatter)
local LAND_FA_PERIOD = 0.6  -- s pulse window for fore/aft corrections
local LAND_FA_DUTY = 0.5    -- max on-time fraction: corrections stay brief
local LAND_FA_FULL = 2.5    -- m/s excess velocity to reach max duty
local LAND_FA_SIGN = 1      -- flip if the rear push amplifies drift
local LAND_ALT_ERR_SHUTDOWN = 20 -- m goal-below-ship error: stop + OS shutdown

-- ============================================================
-- Waypoint AUTOPILOT (ACTIONS -> AUTOPILOT / >>> in WP popup).
-- Replaces the old wp_travel. Sequence:
--   aim   (HOVER)  two steps: CLIMB (goal +AP_CLIMB_GOAL_RATE b/s until prop
--                  demand hits AP_CLIMB_TOP=13 -> goal freezes -> settle at
--                  it), then TURN onto the bearing (PD, no overshoot, wait
--                  stable) — cruise only after both
--   cruise (CRUISE) bank-to-turn heading hold + rear taper (anti-overshoot)
--   correct (CRUISE) off-course: reverse-brake to ~AP_CORRECT_SPEED,
--                   bank back onto bearing, then re-accelerate
--   arrive (CRUISE) reverse-brake down onto the waypoint XZ
--   align  (HOVER)  rotate onto wp.heading (<= AP_ALIGN_TOL)
--   land           auto-land -> full powerOff on touchdown
-- Short hop (inside AP_HOVER_RANGE — at enable or any time later): the
-- travel legs (cruise/correct/arrive) run in HOVER — yaw-stick steer +
-- binary tilt drive, rear never spins up, no bank.
-- Off-course uses roll-bank only (sustained bank -> yaw). If your ship
-- does NOT bank-yaw in-game, AP_BANK_SIGN / physics check required.
-- ============================================================
local AP_AIM_DEADBAND = 3   -- deg: stop yawing when this close to bearing
local AP_AIM_TOL = 5        -- deg: "facing target" to leave aim phase
local AP_OFFCOURSE = 10     -- deg: heading error that triggers slow+correct
local AP_CORRECT_SPEED = 10 -- m/s: slow down to before re-accelerating
local AP_CORRECT_TOL = 5    -- deg: heading good enough to re-accelerate
local AP_ARRIVE_R = 4       -- m: reached the waypoint XZ position
local AP_BRAKE_R = 12       -- m: leave cruise / start braking here (anti-overshoot)
local AP_ALIGN_TOL = 2      -- deg: aligned to wp.heading before auto-land
local AP_STOP_SPEED = 0.6   -- m/s: considered stationary
local AP_LEVEL_PER = 5      -- m of distance per rear speed level (taper)
local AP_MAX_LEVEL = 15
local AP_YAW_SIGN = 1       -- aim/align yaw_cmd sign: +1 maps a left bearing to
                            -- the stick direction that turns left. Flip if the
                            -- ship faces AWAY from the waypoint.
local AP_BANK_SIGN = -1     -- cruise bank direction: -1 = positive bearing err
                            -- (target left) banks LEFT. Flip if it banks away.
local AP_BANK_KP = 0.6      -- deg bank per deg heading error
local AP_BANK_MAX = 8       -- deg max bank command
local AP_BANK_DEAD = 1      -- deg heading deadband (no bank correction)
local AP_BANK_ALT_FADE = 4    -- m: altitude error over which the bank
                            -- command fades to zero (climb first)
local AP_BANK_RATE_LEAD = 0.6 -- s: back off the bank command by yaw_rate so
                            -- the turn bleeds off instead of coasting through
                            -- the bearing (rate lead = angle - k * rate)
local AP_STAB_OUT = 6       -- max cruise attitude speed-diff units (pitch+roll);
                            -- matches the hover high-angle cap (6). 10 slashed a
                            -- side to 0 and rolled violently. Raise for more.
local AP_YAW_GAIN = 30      -- deg err for full yaw stick (aim)
local AP_ALIGN_GAIN = 12    -- deg err for full yaw stick (align, finer)
local AP_YAW_LEAD = 2       -- PD lead: restores the open-loop turn rate that
                            -- the rate-damping term takes away
local AP_YAW_RATE_DAMP = 35 -- deg/s of turn rate per full stick (must match
                            -- rotationControl's rate_target scale)
local AP_YAW_STILL = 2      -- deg/s: rotation counts as settled (codebase
                            -- treats <1.5 as stationary, see rotationControl)
local AP_YAW_EXIT_RATE = 4  -- deg/s: max rotation to leave aim/align (hand
                            -- over to bank-only cruise with no spin left)
-- Yaw-tilt disturbance decoupling. The props do NOT counter-rotate, so
-- vertical thrust cannot yaw the ship: yaw IS the left/right tilt
-- differential (a pure couple — the two pairs push fore/aft against each
-- other at mirrored lever arms, so net force is zero and yaw is the only
-- moment). But the hull turns about an axis AFT of the centre of mass (big
-- rear fins), so the same manoeuvre also rolls and pitches it. The
-- stabiliser used to discover that as a disturbance and chase it, which is
-- the visible rock-through-every-turn. These estimate the coupling so the
-- levelling PIDs aim at the compensating attitude in the SAME tick.
-- Reduction only (never raise a prop above base) — at max altitude there is
-- no thrust headroom to give back.
-- Yaw-compensation trim: deg of roll/pitch the stabiliser is pre-aimed at per
-- unit of commanded yaw tilt, to offset the attitude the hull picks up while
-- turning about an axis aft of the centre of mass.
--
-- DEFAULT 0, i.e. DISABLED, and that is a decision rather than an omission.
-- These were never measured -- they were guesses -- and the guess turns out to
-- be conceptually wrong for THIS ship. It yaws by pitching and rolling, so a
-- commanded roll offset is not a disturbance to be trimmed away, it is more
-- yaw input: the feedforward and the heading controller then both steer, and
-- they steer against each other. The cost of leaving a wrong guess enabled is
-- a permanent fight during the aim phase, which is the wobble on the way to
-- facing a waypoint. Set them from measurement, one axis at a time, or leave
-- them at 0 and let the heading controller own yaw on its own.
local AP_YAW_ROLL_COUPLING = 0.0   -- overridable per-ship via limits.*
local AP_YAW_PITCH_COUPLING = 0.0
local AP_YAW_FF_MAX = 3.0     -- deg: ceiling on the yaw-compensation trim
-- Physical tilt. The prop block only has two positions -- rotated
-- AP_TILT_ANGLE forward, or AP_TILT_ANGLE backward -- and its analog input is
-- NOT proportional, so the tilt command is a request for a direction, not a
-- magnitude. (Analog tilt would be a nice future mod feature; until then every
-- code path that reasons about tilt must go through tiltPhysicalAngle below,
-- or it will silently assume a proportional actuator that does not exist.)
local AP_TILT_ANGLE = 25 -- deg: the only tilt the block can hold
local AP_TILT_RAD = math.pi / 180
local AP_TILT_DEADBAND = 0.15 -- fraction of tilt_max below which we leave the
                              -- prop LEVEL rather than buzzing it to 25 deg for
                              -- a sliver of thrust (25 deg is not a small thing)
-- A tilt command -> the angle the prop is ACTUALLY at. Anything past the
-- deadband snaps to the full fixed tilt, because that is what the block does.
local function tiltPhysicalAngle(command, tilt_max)
    if math.abs(command) < (tilt_max or 12) * AP_TILT_DEADBAND then return 0 end
    return command > 0 and AP_TILT_ANGLE or -AP_TILT_ANGLE
end
local AP_CLIMB_GOAL_RATE = 60 -- m/s: aim climb goal rise. The goal is CLAMPED
                            -- at the target, so a fast rise just means the
                            -- approach law gets the full height error sooner;
                            -- it cannot itself cause overshoot.
local AP_CLIMB_TOP = 13       -- prop demand cap near the goal (settle band),
                            -- = 2 under max rpm so the ship can still hold
local AP_CLIMB_SETTLE_BAND = 40 -- m: inside this much height error, drop to
                            -- AP_CLIMB_TOP so the ship settles; outside it,
                            -- climb on the full authority available
local AP_CLIMB_KP = 0.6       -- prop units per m/s of velocity error
local AP_CLIMB_APPROACH = 0.6 -- 1/s: v_des = APPROACH * height error (the brake
                            -- law that settles the ship AT the frozen goal)
local AP_CLIMB_MAX_V = 60     -- m/s: clamp on |v_des|. Thrust, not this, is the
                            -- real limit -- the clamp only stops a huge height
                            -- error from demanding an absurd rate
local AP_CLIMB_TOL = 2        -- m: one-sided gap: at/above goal - tol counts
                            -- as arrived (paired with |climb_rate| stop)
local AP_CLIMB_STILL = 0.5    -- m/s: climb rate that counts as settled
-- OPERATING CEILING, DISCOVERED RATHER THAN ASSUMED.
-- The old 285 was a guess: it came from a wiki thrust curve for THIS ship at
-- 256 rpm and 12.8*sqrt(sails) airflow, but the ship gets shared, the props get
-- re-tuned, and other people's servers have different build limits. A hardcoded
-- number is wrong on all three counts.
--
-- So the ship finds its own ceiling. y280 is a FLOOR, not a ceiling: cruise
-- travel never happens below it, but it is not the stopping point either.
-- Above the floor the ship watches the one number that reveals the ceiling --
-- the prop speed the hover feedforward needs to hold station. While that is
-- UNDER AP_CEIL_LIFT there is thrust in hand, so it keeps climbing; when it
-- reaches AP_CEIL_LIFT, 2 of 15 are all that remain, and that altitude is the
-- ceiling. Those 2 units ARE the safety margin, which is why the target is
-- the discovered altitude itself and not something below it.
--
-- This is what makes one build work on any world. On a flat world the props
-- are already near max at y280, demand crosses 13 almost immediately, and the
-- ship cruises on its floor. Where the player has terrain and builds high the
-- air is denser up there, the props may still be turning at ~5 on reaching
-- y280, and the ship keeps going up -- potentially a very long way -- until
-- the props come back down to 13.
local AP_CEIL_FLOOR = 280  -- m: cruise never goes below this; climb here first
local AP_CEIL_LIFT = 13    -- prop speed (of hover_max_speed) at which the climb
                            -- stops. 13 leaves 2 in hand: enough to level and
                            -- to absorb a gust without sinking.
local AP_CEIL_HARD = 450   -- m: absolute guard. Physics should stop the probe
                           -- long before this; it only catches a mis-tuned
                           -- hover_throttle, never a real ship.
-- While the ship still has altitude to make up, attitude correction only gets
-- a SLICE of the thrust headroom, so the climb can actually happen. Without
-- this the two fight over the same units and attitude wins every time (it is
-- the faster loop): the ship held 35 m under its target forever, spending the
-- entire climb budget on levelling. Once it is ON altitude the band below
-- stops applying and attitude gets the whole remainder again, so the settled
-- cruise still levels properly and low-altitude handling is unchanged.
local AP_CLIMB_MIN_GAIN = 5   -- m: climb must gain this much ...
local AP_CLIMB_MIN_PT = 3     -- s: ... within this long, else HOLD the
                            -- current altitude and go to the TURN step
local AP_STOP_TAU = 0.4     -- s: EMA time constant of the climb-stop detector
                            -- (the ship bobs around the goal: thrust collapses
                            -- with climb rate and recovers as it falls, so the
                            -- INSTANTANEOUS rate never sits still at 0.5)
local AP_STOP_HOLD = 0.2    -- s: settle must hold this long before TURN
local AP_PHASE_TIMEOUT = 45 -- s failsafe per phase (no-drag ships coast forever)
local AP_HOVER_RANGE = 500  -- m: inside this (at enable or ANY time later,
                            -- incl. mid-cruise) the trip runs on HOVER
                            -- travel — tilt drive + yaw steer, no cruise
                            -- mode, no rear thrust at all
local AP_HOVER_SPEED = 20   -- m/s: speed cap for hover tilt travel
local AP_HOVER_ACCEL = 5    -- m/s^2: full-tilt accel/brake estimate for the
                            -- braking curve (v^2 <= 2*a*room)
local AP_HOVER_BAND = 2     -- m/s: hysteresis band (coast between actions)

-- Auto-land roll strengthening (speed-diff only: A/D roll is pitch/yaw here)
local LAND_ROLL_DEAD = 1    -- deg roll deadband while auto-landing (vs 2 normal)
local LAND_ROLL_CAP = 5     -- max roll correction units while landing (vs 4 normal)

-- atan2 with a Lua-version-safe fallback (CC provides either form)
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- ============================================================
-- Prop-thrust physics feedforward (Create:Aeronautics, wiki-verified):
--   pressure(H) = e^(-0.004 * (H - 63))   -- DimensionPhysics.java
--   thrust      = pressure(H) * (s/6) * (1 - v/airflow) * weight
-- The altitude PID used a FIXED hover feedforward (limits.hover_throttle),
-- which is only correct near sea level: at y260 props make 45% thrust and a
-- fast climb eats another 30-40%. That is why cruise entry sank (y260 ->
-- y160: demand maxed at 13 < the 13.2 needed to even hover) and why the
-- climb bobbed around the goal. Scale the feedforward so prop speed is
-- weight-equivalent at every height and vertical rate:
--   s = hover * e^(0.004*(H-63)) / (1 - v/airflow)
-- ============================================================
local AP_PRESS_K = 0.004   -- pressure falloff per metre (wiki)
local AP_PRESS_REF = 63    -- sea-level reference (world Y)
local AP_AIRFLOW = 25      -- m/s through the prop ~= 12.8*sqrt(sail count)
                           -- at 256 rpm (wiki: thrust = ...*(1-v/airflow)).
                           -- Climb still sags at speed -> raise; overshoots
                           -- -> lower. Clamped to den 0.3..3 either way.
local function hoverFF(limits, state)
    local base = (limits or {}).hover_throttle or 6
    local den = 1 - ((state or {}).climb_rate or 0) / AP_AIRFLOW
    if den < 0.3 then den = 0.3 elseif den > 3 then den = 3 end
    local h = (state or {}).altitude
    if h == nil then h = AP_PRESS_REF end
    local kh = math.exp(AP_PRESS_K * (h - AP_PRESS_REF))
    -- second return: kh (pressure factor); third: den (climb-rate thrust
    -- factor, clamped) — attitude scheduling needs BOTH (kh/den).
    return base * kh / den, kh, den
end

function Flight.new(config, hardware)
    local self = setmetatable({}, Flight)
    self.config = config
    self.hw = hardware

    self.mode = Flight.MODE_HOVER

    self.pid = {
        altitude = PID.new(config.pid.altitude),
        pitch    = PID.new(config.pid.pitch),
        roll     = PID.new(config.pid.roll),
        yaw      = PID.new(config.pid.yaw),
    }

    self.targets = {
        altitude = 0,
        pitch = 0,
        roll = 0,
        yaw = 0,
        move_forward = 0,
        yaw_cmd = 0,
        speed = 0, -- rear speed level: 0 = off, cruise 1..15 (W/S steps it)
    }

    self.estop = false        -- latched by X until reset (R / altitude / mode)

    -- Manual Q/E stick forwarded by os_main every tick. The autopilot's
    -- aim/align phases add it to their own yaw_cmd; cruise/correct/arrive
    -- ignore it (bank-to-turn owns the heading there).
    self.pilot_yaw = 0

    -- Stability pulse train + auto-unflip state
    self.stab_phase = 0   -- 0..1 duty window for time-domain stability pulses
    self.inv_time = 0     -- seconds spent near-or-at 180 (auto-unflip trigger)
    self.inv_cooldown = 0 -- seconds left before auto-unflip detection re-arms
    self.unflip = nil     -- active auto-unflip sequence table, if any

    -- Cruise W/S step state: +1 on press, +1 every 0.2 s held
    self.cruise_w_held = false
    self.cruise_s_held = false
    self.cruise_w_ticks = 0
    self.cruise_s_ticks = 0

    -- Explicit heading-hold state (0 is a valid heading — do not use as sentinel)
    self.heading_valid = false
    self.yaw_rate_dps = 0

    -- Waypoint AUTOPILOT state (nil = idle); wp_event is a one-shot
    -- { kind = "arrived"|"cancelled", name, reason } consumed by os_main
    -- for both autopilot start and finish notifications.
    self.ap = nil
    self.wp_event = nil

    self.state = {
        altitude = 0,
        pitch = 0,
        roll = 0,
        yaw = 0,
        speed = 0,
        climb_rate = 0,
        angularVelocity = { x = 0, y = 0, z = 0 },
        velocity = { x = 0, y = 0, z = 0 },
        forward = { x = 0, y = 0, z = 0 },
        position = { x = 0, y = 0, z = 0 },
        pitch_rate = 0,
        roll_rate = 0,
        yaw_rate = 0,
    }

    -- signed tilt (translation/yaw) + per-prop thrust 0..15 (altitude + attitude)
    self.outputs = {
        speed = 0,
        FL_speed = 0, FR_speed = 0, RL_speed = 0, RR_speed = 0,
        FL_tilt = 0, FR_tilt = 0, RL_tilt = 0, RR_tilt = 0,
        rear_fw = 0, rear_bw = 0, rear_rev = 0,
        -- legacy aliases used by HUD
        tilt_fwd = 0, tilt_bwd = 0,
    }

    self.landed = false
    self.gear_down = false
    self.gear_settle = 0
    self.auto_land = false
    self.land_state = Flight.LAND_IDLE
    self.land_heading = nil -- heading recorded when auto-land fires
    self.fa_phase = 0       -- fore/aft correction pulse window (0..1)
    self.shutdown_request = nil -- set by safeguards; os_main acts on it
    self.proximity = 0
    self._ground_ticks = 0 -- consecutive landed_thr hits (debounced latch)
    self.shift_level = 0
    self.shift_armed = true -- allow next toggle after release

    self.last_update = os.clock()
    self.update_count = 0
    self.tick_rate = 0.05
    self.last_sable_error = nil

    return self
end

function Flight:captureHeading()
    self.targets.yaw = self.state.yaw
    self.heading_valid = true
    self.pid.yaw:reset()
end

function Flight:setMode(mode)
    if mode == self.mode then return false end

    local old_mode = self.mode
    self.mode = mode
    self.estop = false

    -- NOTE (autopilot): setMode no longer cancels travel. The autopilot
    -- OWNS the mode and switches HOVER<->CRUISE itself; a manual mode
    -- change while autopilot is active is blocked upstream in os_main.

    for _, pid in pairs(self.pid) do
        pid:reset()
    end

    self.targets.altitude = self.state.altitude
    if mode == Flight.MODE_CRUISE then
        -- Rear props come up at speed level 1 (cruise minimum, signal 14);
        -- W/S steps the goal bar. Hover puts them back to level 0 (signal 15).
        self.targets.speed = 1
        self.cruise_w_held = false
        self.cruise_s_held = false
        self.cruise_w_ticks = 0
        self.cruise_s_ticks = 0
    elseif mode == Flight.MODE_HOVER then
        self.targets.speed = 0
    end
    self:captureHeading()

    return true, old_mode, mode
end

function Flight:toggleMode()
    if self.mode == Flight.MODE_HOVER then
        return self:setMode(Flight.MODE_CRUISE)
    else
        return self:setMode(Flight.MODE_HOVER)
    end
end

-- Rising-edge mode toggle for held redstone (shift key).
-- Returns true when a toggle actually fired.
function Flight:pollShift(shift_value)
    local level = (shift_value or 0) > 0 and 1 or 0
    local toggled = false
    if level == 1 and self.shift_armed and self.shift_level == 0 then
        if not self.ap then -- autopilot owns the mode; do not fight it
            self:toggleMode()
            toggled = true
        end
        self.shift_armed = false
    elseif level == 0 then
        self.shift_armed = true
    end
    self.shift_level = level
    return toggled
end

-- The altitude the ship should actually CRUISE at.
--
-- The probe stops the climb while 2 of 15 are still in hand, so the altitude
-- it discovers is already the safe one to fly at and no extra margin is owed
-- on top of it. The only floor applied here is AP_CEIL_FLOOR: an alt-less
-- waypoint cruises at the discovered ceiling, and never below y280.
function Flight:ceilingTarget()
    local learned = tonumber((self.config.limits or {}).ceiling)
    -- >= not >: a ceiling learned exactly ON the floor is a real answer. With
    -- > it fell through to AP_CEIL_HARD and the ship re-probed to 450 forever.
    if learned and learned >= AP_CEIL_FLOOR then
        -- No margin to subtract: the probe already stopped 2 prop units short
        -- of max, so the discovered altitude is itself the safe one.
        return learned
    end
    return AP_CEIL_HARD
end

-- Ceiling probe. Returns true while there is still spare thrust (keep
-- climbing), false once the feedforward has pinned at max (that is the
-- ceiling, so stop asking for more). Only probes above AP_CEIL_FLOOR: below
-- that there is obviously thrust to spare and probing would be pointless.
function Flight:ceilingProbe(altitude, hmax)
    -- Below the floor there is nothing to decide: go up.
    if altitude < AP_CEIL_FLOOR then return true end
    -- The prop speed needed to hold station here with no climb rate. (Parens
    -- matter: hoverFF(...)[1] would index the returned NUMBER, since Lua
    -- truncates the call to one value first.)
    local need = hoverFF(self.config.limits, { altitude = altitude })
    -- Demand has reached the stopping speed, so this altitude is the ceiling.
    -- Clamped to just under hmax so a raised AP_CEIL_LIFT can never leave the
    -- probe unable to terminate.
    local stop_at = math.min(AP_CEIL_LIFT, hmax - 0.05)
    if need >= stop_at then
        local lim = self.config.limits or {}
        if not lim.ceiling or lim.ceiling > altitude then
            lim.ceiling = altitude
        end
        return false
    end
    return true
end

function Flight:adjustAltitude(delta)
    if self.auto_land and self.land_state ~= Flight.LAND_IDLE then
        return false
    end
    self.estop = false -- pilot input cancels e-stop latch
    local limits = self.config.limits or {}
    local lo = limits.min_altitude or 0
    -- max_altitude is an OPERATOR safety cap, not the flight ceiling: the
    -- ceiling is discovered at runtime and can be far higher. Falling back to
    -- the retired 285 here would quietly cap manual commands -- and therefore
    -- cruise -- below the very altitude the probe is trying to reach.
    local hi = tonumber(limits.max_altitude) or AP_CEIL_HARD
    self.targets.altitude = clamp(self.targets.altitude + delta, lo, hi)
    if self.landed and delta > 0 then
        -- command climb off ground
        self.landed = false
        if self.land_state == Flight.LAND_DONE or self.land_state == Flight.LAND_TOUCH then
            self.land_state = Flight.LAND_IDLE
            self.auto_land = false
        end
    end
    return true
end

function Flight:setAutoLand(on)
    on = not not on
    if on and self.landed then
        self.auto_land = false
        self.land_state = Flight.LAND_DONE
        return false, "ALREADY LANDED"
    end
    self.auto_land = on
    if on then
        -- NOTE (autopilot): no longer cancels travel here. When the
        -- autopilot's align phase fires setAutoLand(true) it must NOT
        -- self-cancel. Manual L is blocked upstream in os_main while
        -- the autopilot is active.

        self.land_state = Flight.LAND_ARMED
        -- Record the heading the moment auto-landing fires: the whole
        -- sequence holds this heading even if the ship rotates later.
        self.land_heading = self.state.yaw
        self.heading_valid = true
        self.targets.yaw = self.state.yaw
        self.pid.yaw:reset()
        if not self.gear_down then
            self.gear_down = true
            self.hw.setGear(true)
            self.gear_settle = (self.config.proximity and self.config.proximity.gear_settle_ticks) or 20
        end
        return true, "AUTO-LAND ARMED"
    else
        if self.land_state ~= Flight.LAND_DONE then
            self.land_state = Flight.LAND_IDLE
        end
        return true, "AUTO-LAND OFF"
    end
end

function Flight:toggleAutoLand()
    return self:setAutoLand(not self.auto_land)
end

-- ============================================================
-- Waypoint AUTOPILOT
-- ============================================================

-- Signed bearing error from the nose to the target (deg).
-- cross.y = fz*tl - fx*tz ; sign flipped per-actuator below (yaw vs bank).
function Flight:apBearingError(dist, dx, dz)
    local state = self.state
    local fwd = state.forward or { x = 1, y = 0, z = 0 }
    local fl = math.sqrt((fwd.x or 0) ^ 2 + (fwd.z or 0) ^ 2)
    if fl < 1e-6 then fl = 1 end
    local fx, fz = (fwd.x or 0) / fl, (fwd.z or 0) / fl
    local tl, tz = 0, 1
    if dist > 0.001 then tl, tz = dx / dist, dz / dist end
    local dot = fx * tl + fz * tz
    local cross = fz * tl - fx * tz
    return math.deg(atan2(cross, dot))
end

-- Yaw stick from a heading error (deg) + RATE FEEDBACK (PD): P maps the
-- error to stick (gain = deg err for full stick), D subtracts the measured
-- turn rate scaled to rotationControl's deg/s-per-stick, so the ship starts
-- BRAKING well before reaching the bearing instead of coasting through it
-- at full rate (pure-P overshoot: the deadband went hands-off = no yaw
-- actuation at all, leaving only the current rotation to carry it past).
-- sign maps through AP_YAW_SIGN.
function Flight:apYawCmd(err, gain, dead)
    if math.abs(err) <= dead and math.abs(self.state.yaw_rate or 0) <= AP_YAW_STILL then
        return 0
    end
    -- PD: lead = P on the angle error (sign-wrapped), damp = D on the turn
    -- rate (ship frame, NOT wrapped — wrapping both makes the inner rate
    -- loop degenerate at AP_YAW_SIGN=-1). The inner loop maps stick to rate
    -- at 35 deg/s per stick, so with lead = 2*err/gain the steady state is
    -- rate = 35*err/gain — identical to the old pure-P turn rate, but the
    -- damp term brakes the rotation as the bearing is approached instead of
    -- coasting through it (the old deadband went hands-off = no yaw
    -- actuation at all, leaving the ship to swing past on momentum).
    local lead = AP_YAW_LEAD * clamp(err / gain, -1, 1)
    local damp = (self.state.yaw_rate or 0) / AP_YAW_RATE_DAMP
    -- lead can reach AP_YAW_LEAD (2) before the rate builds; clamp the
    -- final stick so rotationControl never sees |stick| > 1 (35 deg/s cap).
    return clamp(AP_YAW_SIGN * lead - damp, -1, 1)
end

function Flight:startAutopilot(wp)
    if self.estop then return false, "E-STOP LATCHED" end
    if self.unflip then return false, "UNFLIP RUNNING" end
    if self.auto_land then return false, "AUTO-LAND ACTIVE" end
    if self.ap then return false, "AUTOPILOT ACTIVE" end
    if self.landed then return false, "TAKE OFF FIRST" end
    if type(wp) ~= "table" or tonumber(wp.x) == nil or tonumber(wp.z) == nil then
        return false, "BAD WAYPOINT"
    end
    -- Normalise to HOVER (from CRUISE too): the aim phase then owns the mode.
    if self.mode == Flight.MODE_CRUISE then self:setMode(Flight.MODE_HOVER) end
    local pos = self.state.position or { x = 0, y = 0, z = 0 }
    local dx, dz = tonumber(wp.x) - (pos.x or 0), tonumber(wp.z) - (pos.z or 0)
    local start_dist = math.sqrt(dx * dx + dz * dz)
    if start_dist <= AP_ARRIVE_R then return false, "ALREADY THERE" end

    local limits = self.config.limits or {}
    local alt_now = self.state.altitude or 0
    -- Operative ceiling for this run: a learned one if we have probed it,
    -- otherwise the absolute guard so the climb may go find out.
    local ceiling = self:ceilingTarget()
    -- CLIMB TARGET. The goal used to ramp toward the AP *ceiling* on every
    -- trip, because the waypoint's own altitude was never read: a level
    -- waypoint still sent the ship climbing, froze the goal near the top of
    -- its authority and then fought a ~200 m height error (the climb bob and
    -- the sag after the turn). The target is the waypoint's own altitude when
    -- it supplies one. When it does NOT, the ship climbs to its operating
    -- ceiling instead -- at least AP_CEIL_FLOOR, higher if the props allow --
    -- because "no altitude given" means "take me to cruising height", and
    -- "hold exactly here" was what turned every short hop into a 200 m climb.
    -- The learned ceiling is stable once probed, so re-running a route does
    -- not re-climb; only a genuinely higher ceiling (different props, higher
    -- build limit) moves the goal again.
    local goal_alt = tonumber(wp.alt)
    if not goal_alt or goal_alt ~= goal_alt then goal_alt = ceiling end
    goal_alt = clamp(goal_alt, 0, ceiling)

    self.ap = {
        name = tostring(wp.name or "WP"),
        x = tonumber(wp.x),
        z = tonumber(wp.z),
        heading = ((tonumber(wp.heading) or 0) % 360 + 360) % 360,
        phase = "aim",
        pt = 0,          -- seconds in current phase (timeout failsafe)
        paused = false,  -- unflip pause; resumes where it left off
        brake_reverse = false, -- flag; written after mode rear outputs (Flight:update)
        start_dist = start_dist,
        dist = start_dist,
        err = 0,
        progress = 0,
        eta = nil,
        speed = 0,
        alt = self.state.altitude or 0,  -- captured flight altitude (all phases)
        step = "climb",  -- aim sub-step: climb first (always), then turn
        goal_alt = goal_alt,        -- m: altitude the climb converges on
        needs_climb = goal_alt > alt_now + AP_CLIMB_TOL, -- else skip to TURN
        climb_goal = alt_now,      -- rises toward goal_alt, then freezes there
        climb_alt0 = alt_now,      -- for the stall failsafe
        climb_frozen = false,      -- at goal_alt (or demand hit AP_CLIMB_TOP)
        rate_ema = nil,   -- EMA of climb_rate (bobbing-proof stop detector)
        stop_hold = 0,    -- s the settle condition has held continuously
        ceil = ceiling,
        hover_only = start_dist < AP_HOVER_RANGE, -- short hop: hover travel
    }
    if not self.heading_valid then self:captureHeading() end
    self.wp_event = nil
    return true, "AUTOPILOT: " .. self.ap.name
end

-- The ONLY way to stop an autopilot besides the on-screen CANCEL button:
-- e-stop and shutdown keep working as emergencies.
function Flight:cancelAutopilot(reason)
    if not self.ap then return false end
    local nm = self.ap.name
    self.ap = nil
    self.outputs.rear_fw = 0
    self.outputs.rear_bw = 0
    self.outputs.rear_rev = 0
    self.targets.yaw_cmd = 0
    self.targets.move_forward = 0
    -- free the ship: drop back to hover (rear off) if we were cruising
    if self.mode == Flight.MODE_CRUISE and not self.landed then
        self:setMode(Flight.MODE_HOVER)
    end
    self.targets.speed = 0
    if reason then
        self.wp_event = { kind = "cancelled", name = nm, reason = reason }
    end
    return true
end

-- rear output helper: level 0..15, optional reverse-face activation
function Flight:apRear(level, rev)
    self.outputs.rear_fw = level
    self.outputs.rear_bw = level
    self.outputs.rear_rev = (rev and 1) or 0
end

-- Hover-only travel drive (ap.hover_only): W/S-style binary tilt toward the
-- waypoint. want = the speed the distance-to-go can still absorb at full
-- tilt (v^2 <= 2*a*room, capped at AP_HOVER_SPEED); bang-bang with
-- AP_HOVER_BAND hysteresis, coast in between so the ship does not surge
-- (no drag: coasting holds speed). Braking compares the SIGNED speed along
-- the nose, so backward drift gets forward tilt instead of runaway reverse.
function Flight:apHoverDrive(dist)
    local v = self.state.velocity or {}
    local f = self.state.forward or {}
    local fwd_speed = (v.x or 0) * (f.x or 0) + (v.z or 0) * (f.z or 0)
    local room = math.max(dist - AP_ARRIVE_R, 0)
    local want = math.min(AP_HOVER_SPEED, math.sqrt(2 * AP_HOVER_ACCEL * room))
    local step = (self.config.limits or {}).hover_speed or 2
    if fwd_speed > want + AP_HOVER_BAND
        or (want <= AP_STOP_SPEED and fwd_speed > AP_STOP_SPEED) then
        self.targets.move_forward = -step -- reverse tilt: brake / back off
    elseif fwd_speed < want - AP_HOVER_BAND then
        self.targets.move_forward = step  -- nose toward the waypoint
    else
        self.targets.move_forward = 0     -- on the profile: coast
    end
end

function Flight:updateAutopilot(dt)
    local ap = self.ap
    if not ap then return end
    local state = self.state

    -- Unflip pause: hold phase, resume cleanly when the ship is upright.
    if self.unflip then
        ap.paused = true
        return
    end
    if ap.paused then
        ap.paused = false
        ap.pt = 0
    end

    -- Emergencies / outside interference end the run.
    if self.estop then self:cancelAutopilot("e-stop") return end
    if self.auto_land and ap.phase ~= "land" then
        self:cancelAutopilot("auto-land") return
    end

    -- Geometry: horizontal distance + signed bearing error (deg).
    local pos = state.position or { x = 0, y = 0, z = 0 }
    local dx, dz = ap.x - (pos.x or 0), ap.z - (pos.z or 0)
    local dist = math.sqrt(dx * dx + dz * dz)
    local err = self:apBearingError(dist, dx, dz)
    local speed = state.speed or 0
    local limits = self.config.limits or {}
    local hover = hoverFF(limits, state) -- height/rate-scaled prop feedforward
    local hmax = limits.hover_max_speed or 15

    ap.dist = dist
    ap.err = err
    ap.speed = speed
    if ap.start_dist > 1 then
        ap.progress = math.max(0, math.min(1, (ap.start_dist - dist) / ap.start_dist))
    end
    ap.eta = (speed > 0.5) and (dist / speed) or nil

    ap.pt = (ap.pt or 0) + dt
    local function setPhase(ph)
        if ap.phase ~= ph then
            ap.phase = ph
            ap.pt = 0
        end
    end
    local function timedOut()
        return ap.pt > AP_PHASE_TIMEOUT
    end
    -- Rear props spool at limits.cruise_ramp (level/s) instead of jumping to
    -- the target: an instant 0->15 kick at cruise entry pitches the nose over
    -- before the pitch stab can answer (the y260 -> y160 entry dive). Only
    -- RISES are ramped — braking/crawl drops stay instant.
    local function rearRamp(want)
        local cur = self.targets.speed or 0
        if want > cur then
            want = math.min(want, cur + (limits.cruise_ramp or 8) * dt)
        end
        self.targets.speed = want
    end

    -- Autopilot owns these axes; manual inputs are gated off upstream.
    self.targets.move_forward = 0
    ap.brake_reverse = false

    -- Live upgrade: inside AP_HOVER_RANGE the rest of the run switches to
    -- hover travel (yaw-steer + tilt drive) — INCLUDING mid-cruise, so a
    -- long run drops to hover 500 m out and brakes on the tilt profile.
    if not ap.hover_only and ap.dist < AP_HOVER_RANGE then
        ap.hover_only = true
    end

    -- SHORT HOP (ap.hover_only): the travel legs run with HOVER controls
    -- only — yaw-stick steer + binary tilt drive (apHoverDrive). No cruise
    -- mode, no rear thrust, no bank; steering is continuous (no off-course
    -- detour) and the braking curve v^2 <= 2*a*room handles arrival.
    if ap.hover_only and (ap.phase == "cruise" or ap.phase == "correct"
        or ap.phase == "arrive") then
        if self.mode ~= Flight.MODE_HOVER then self:setMode(Flight.MODE_HOVER) end
        self.targets.speed = 0
        self.targets.altitude = ap.alt
        self.targets.yaw_cmd = clamp(
            self:apYawCmd(err, AP_YAW_GAIN, AP_AIM_DEADBAND), -1, 1)
        self:apHoverDrive(dist)
        if ap.phase == "correct" and math.abs(err) <= AP_CORRECT_TOL then
            setPhase("cruise")
        end
        if dist <= AP_BRAKE_R then
            setPhase("arrive")
        end
        if dist <= AP_ARRIVE_R and speed <= AP_STOP_SPEED then
            self.targets.yaw_cmd = 0
            self.targets.move_forward = 0
            setPhase("align")
        elseif ap.phase ~= "cruise" and timedOut() then
            -- correct/arrive failsafe only — cruise never times out
            self.targets.move_forward = 0
            if ap.phase == "arrive" then
                self.targets.yaw_cmd = 0
                setPhase("align")
            else
                setPhase("cruise") -- correct gave up: resume hover travel
            end
        end
        return
    end

    if ap.phase == "aim" then
        -- HOVER, two steps — CLIMB FIRST (always, even for short hops), then
        -- TURN onto the bearing. Cruise only once both are done.
        if self.mode ~= Flight.MODE_HOVER then self:setMode(Flight.MODE_HOVER) end

        -- CEILING PROBE, every phase, every tick. It has to run here rather
        -- than inside the climb step: the climb finishes as soon as the ship is
        -- steady at its target, so a climb-only probe never saw the ship
        -- actually sitting at its ceiling and never learned anything (the
        -- ceiling stayed unset and the ship cruised on the hard guard).
        -- Holding station is the best place to measure thrust headroom anyway.
        --
        -- Once the lift props are down to AP_CEIL_LIFT there is nothing left
        -- to climb with, so that altitude IS the ceiling -- record it and
        -- cruise there. The 2 units of thrust still in hand are the margin, so
        -- no extra subtraction is applied. This is what replaces the hardcoded
        -- 285, and it re-derives itself for different props, a denser world,
        -- or a re-tuned engine.
        if self:ceilingProbe(state.altitude or 0, hmax) then
            if not tonumber((limits or {}).ceiling) then
                ap.ceil = AP_CEIL_HARD -- still searching: keep looking
            end
        else
            ap.ceil = self:ceilingTarget()
            ap.goal_alt = math.min(ap.goal_alt, ap.ceil)
            ap.climb_goal = math.min(ap.climb_goal, ap.ceil)
            if ap.alt and ap.alt > ap.ceil then ap.alt = ap.ceil end
        end

        if ap.step ~= "turn" then
            -- STEP 1 — CLIMB toward ap.goal_alt (the waypoint's altitude, or
            -- simply hold where we are). The goal rises at
            -- AP_CLIMB_GOAL_RATE but is CLAMPED AT THE TARGET, so the height
            -- error the approach law has to service stays bounded instead of
            -- growing to the ceiling.
            if not ap.needs_climb then
                -- Already at (or above) the target altitude: no climb at all.
                -- Hand straight to the turn step instead of "settling" a climb
                -- that was never needed.
                ap.alt = ap.goal_alt
                ap.step = "turn"
                ap.climb_demand = nil
                ap.pt = 0
            end
            if ap.step == "climb" then
                if not ap.climb_frozen then
                    ap.climb_goal = math.min(
                        ap.climb_goal + AP_CLIMB_GOAL_RATE * dt,
                        math.min(ap.goal_alt, ap.ceil))
                    -- reached the target: freeze, the law below settles it there
                    if ap.climb_goal >= ap.goal_alt - 1e-6 then
                        ap.climb_frozen = true
                    end
                end
                -- Stop detector: thrust collapses as the ship climbs (rate term)
                -- and recovers as it falls, so it BOBS around the goal and the
                -- instantaneous rate flickers through 0.5 m/s over and over.
                -- EMA the rate (tau AP_STOP_TAU) and require the settle condition
                -- to hold AP_STOP_HOLD seconds before starting the turn.
                local rate = state.climb_rate or 0
                ap.rate_ema = (ap.rate_ema or rate)
                    + (rate - (ap.rate_ema or rate)) * math.min(1, dt / AP_STOP_TAU)
                local h_err = ap.climb_goal - state.altitude
                local vdes = clamp(
                    AP_CLIMB_APPROACH * h_err, -AP_CLIMB_MAX_V, AP_CLIMB_MAX_V)
                -- Feedforward scales with height and current rate (hoverFF), so
                -- the law still means what it says at altitude: freeze exactly
                -- when prop demand reaches AP_CLIMB_TOP, hold up to hover_max_speed
                -- (15) on the freeze tick instead of clipping BELOW what the ship
                -- needs to hover — the old 0..13 clip under-thruster at y260 and
                -- the stall failsafe then bailed out of the climb.
                -- RATE GAIN MUST EXCEED THE FEEDFORWARD'S OWN RATE SLOPE or the
                -- climb loses its damping and bobs. hover() carries 1/(1 -
                -- rate/25), so it RISES with climb rate at d(hover)/d(rate) =
                -- hover/25. At y280 that slope is 0.57, which almost exactly
                -- cancels the 0.60 KP and leaves ~0 net damping -- that is why
                -- the climb did ups and downs, and why it got worse the higher
                -- it went. Folding hover/25 back into the gain makes the net
                -- rate feedback a constant -AP_CLIMB_KP at EVERY altitude.
                local k_rate = AP_CLIMB_KP + hover / AP_AIRFLOW
                local raw = hover + k_rate * (vdes - rate)
                -- Full authority in transit, and NO freeze on demand while in
                -- transit. raw >= hmax only means the climb is asking for more
                -- than the props can deliver, which is what every fast climb
                -- does -- clipping is the correct response, not giving up
                -- (freezing there stopped the climb dead at y118 on the first
                -- test, with 8 prop units still unused). Whether the ship has
                -- actually run out of thrust is a question about the HOVER
                -- demand, not the climb demand, and that is what
                -- ceilingProbe below answers.
                --
                -- "Close" is measured against the FINAL target, not the ramping
                -- goal: the goal rises far faster than the ship, so
                -- climb_goal - altitude stays small all the way up and a band
                -- on it would pin the ship at 13/15 immediately.
                local remain = (math.min(ap.goal_alt, ap.ceil) or ap.climb_goal)
                    - (state.altitude or 0)
                if remain <= AP_CLIMB_SETTLE_BAND and raw >= AP_CLIMB_TOP then
                    ap.climb_frozen = true
                end
                local demand = clamp(raw, 0, hmax)
                ap.climb_demand = demand -- updateHover applies it as base speed
                self.targets.altitude = ap.climb_goal
                self.targets.yaw_cmd = clamp(self.pilot_yaw or 0, -1, 1) -- Q/E only
                local stalled = ap.pt >= AP_CLIMB_MIN_PT
                    and (state.altitude - (ap.climb_alt0 or 0)) < AP_CLIMB_MIN_GAIN
                local settle = ap.climb_frozen
                    and math.abs(ap.rate_ema) <= AP_CLIMB_STILL
                    -- "stopped climbing" = vertical motion is gone AND we are
                    -- at/above the goal band (ONE-sided: the abs check used to
                    -- fail at the overshoot peak and wait out another slow
                    -- cycle) or the climb has simply run long enough.
                    and (h_err <= AP_CLIMB_TOL or ap.pt >= AP_CLIMB_MIN_PT)
                ap.stop_hold = (settle and not stalled)
                    and ((ap.stop_hold or 0) + dt) or 0
                if stalled then
                    -- STALLED CLIMB (gained < 5 m in 3 s): hold here — freeze
                    -- the goal at the current altitude and move on to the
                    -- heading phase instead of waiting out the phase timeout.
                    ap.climb_goal = state.altitude
                    ap.alt = state.altitude -- hold THIS during the turn (once!)
                    ap.step = "turn"
                    ap.climb_demand = nil -- props back to the altitude PID
                    ap.pt = 0 -- the rotation gets its own timeout window
                elseif (settle and ap.stop_hold >= AP_STOP_HOLD) or timedOut() then
                    -- Hold the TARGET altitude, not wherever the ship happened
                    -- to be when the climb gave up: capturing state.altitude
                    -- froze the cruise at the overshoot peak and the ship then
                    -- sank through the turn. The altitude PID converges the
                    -- remainder while the turn is already running.
                    ap.alt = ap.climb_frozen and ap.goal_alt or state.altitude
                    ap.step = "turn"
                    ap.climb_demand = nil -- hand the props back to the altitude PID
                    ap.pt = 0 -- the rotation gets its own timeout window
                end
            end
        else
            -- STEP 2 — TURN: HOLD the altitude captured once when the climb
            -- ended (ap.alt). Re-capturing here would let the goal follow
            -- the ship down through any rotation sag instead of holding it.
            -- Auto PD stick + manual Q/E assist (pilot_yaw), clamped so
            -- rotationControl never sees |stick| > 1.
            self.targets.altitude = ap.alt
            self.targets.yaw_cmd = clamp(
                self:apYawCmd(err, AP_YAW_GAIN, AP_AIM_DEADBAND) + (self.pilot_yaw or 0),
                -1, 1)
            -- Exit only when the rotation has actually died (PD braking):
            -- handing over to bank-only cruise mid-spin = off the bearing.
            local facing = math.abs(err) <= AP_AIM_TOL
                and math.abs(self.state.yaw_rate or 0) <= AP_YAW_EXIT_RATE
            if facing or timedOut() then
                self.targets.yaw_cmd = 0
                if ap.hover_only then
                    -- short hop: the travel legs stay in HOVER (rear never on)
                    self.targets.speed = 0
                else
                    self:setMode(Flight.MODE_CRUISE) -- freezes altitude at current
                    rearRamp(AP_MAX_LEVEL) -- spool at cruise_ramp (no kick-dive)
                end
                setPhase("cruise")
            end
        end

    elseif ap.phase == "cruise" then
        -- CRUISE: bank-to-turn heading hold + rear taper (anti-overshoot).
        if self.mode ~= Flight.MODE_CRUISE then
            self:setMode(Flight.MODE_CRUISE)
            rearRamp(AP_MAX_LEVEL) -- spool at cruise_ramp (no kick-dive)
        end
        self.targets.yaw_cmd = 0
        self.targets.altitude = ap.alt
        if math.abs(err) > AP_OFFCOURSE then
            setPhase("correct")
        elseif dist <= AP_BRAKE_R then
            setPhase("arrive")
        else
            rearRamp(clamp(math.floor(dist / AP_LEVEL_PER), 1, AP_MAX_LEVEL))
        end

    elseif ap.phase == "correct" then
        -- Off-course: stay in cruise, reverse-brake to ~AP_CORRECT_SPEED,
        -- bank back onto the bearing, then re-accelerate.
        if self.mode ~= Flight.MODE_CRUISE then self:setMode(Flight.MODE_CRUISE) end
        self.targets.yaw_cmd = 0
        self.targets.altitude = ap.alt
        local slow = speed <= AP_CORRECT_SPEED
        if slow then
            self.targets.speed = 1 -- crawl so we can still turn
        else
            self.targets.speed = 0 -- level 0 = brake wire
            -- reverse face only if the hardware has it; apRear with a forward
            -- level would otherwise ACCELERATE us on ships lacking it
            ap.brake_reverse = self:hasFeature("rear_reverse")
        end
        if slow and math.abs(err) <= AP_CORRECT_TOL then
            ap.brake_reverse = false
            rearRamp(AP_MAX_LEVEL) -- re-accelerate on the ramp, not a kick
            setPhase("cruise")
        elseif dist <= AP_BRAKE_R then
            ap.brake_reverse = false
            setPhase("arrive")
        elseif timedOut() then
            ap.brake_reverse = false
            rearRamp(AP_MAX_LEVEL)
            setPhase("cruise")
        end

    elseif ap.phase == "arrive" then
        -- CRUISE: brake down onto the waypoint XZ (anti-overshoot).
        if self.mode ~= Flight.MODE_CRUISE then self:setMode(Flight.MODE_CRUISE) end
        self.targets.yaw_cmd = 0
        self.targets.altitude = ap.alt
        local room = math.max(dist - AP_ARRIVE_R, 0)
        local want = math.min(AP_MAX_LEVEL, math.sqrt(room * 3)) -- v^2 <= 2*a*d
        if speed > want + 1 then
            self.targets.speed = 0
            ap.brake_reverse = self:hasFeature("rear_reverse")
        else
            rearRamp(clamp(math.floor(want), 0, AP_MAX_LEVEL))
        end
        if (dist <= AP_ARRIVE_R and speed <= AP_STOP_SPEED) or timedOut() then
            ap.brake_reverse = false
            self.targets.speed = 0
            self:setMode(Flight.MODE_HOVER)
            setPhase("align")
        end

    elseif ap.phase == "align" then
        -- HOVER: rotate onto the stored heading (<= AP_ALIGN_TOL).
        if self.mode ~= Flight.MODE_HOVER then self:setMode(Flight.MODE_HOVER) end
        self.targets.speed = 0
        local herr = angleError(ap.heading, state.yaw or 0)
        -- Manual Q/E assist allowed here too (above the waypoint: turning
        -- onto the saved heading before auto-land).
        self.targets.yaw_cmd = clamp(
            self:apYawCmd(herr, AP_ALIGN_GAIN, AP_ALIGN_TOL) + (self.pilot_yaw or 0),
            -1, 1)
        -- Same rotation gate as aim: don't start auto-land while still spinning.
        local aligned = math.abs(herr) <= AP_ALIGN_TOL
            and math.abs(self.state.yaw_rate or 0) <= AP_YAW_EXIT_RATE
        if aligned or timedOut() then
            self.targets.yaw_cmd = 0
            -- may report ALREADY LANDED; the "land" phase handles both cases
            self:setAutoLand(true)
            setPhase("land")
        end

    elseif ap.phase == "land" then
        -- auto-land is running; its own runaway failsafe handles stalls.
        self.targets.yaw_cmd = 0
        self.targets.speed = 0
        if self.landed or self.land_state == Flight.LAND_DONE then
            local nm = ap.name
            self.ap = nil
            self.wp_event = { kind = "arrived", name = nm }
            self.shutdown_request = "autopilot landed"
            return
        end
    end

    -- The reverse brake write itself lives in Flight:update(): this
    -- function now runs BEFORE the mode function, so the flag it sets here
    -- is consumed there, after the mode/auto-land rear outputs.
end

function Flight:updateState()
    local state = self.hw.getShipState()
    self.state.altitude = state.altitude
    self.state.pitch = state.pitch
    self.state.roll = state.roll
    self.state.yaw = state.yaw
    self.state.speed = state.speed
    self.state.climb_rate = state.climb_rate
    self.state.velocity = state.velocity or { x = 0, y = 0, z = 0 }
    self.state.forward = state.forward or { x = 0, y = 0, z = 0 }
    self.state.position = state.position or { x = 0, y = 0, z = 0 }
    self.state.angularVelocity = state.angularVelocity or { x = 0, y = 0, z = 0 }
    -- Ship local X = LONGITUDINAL axis: av.x = roll rate, av.z = pitch rate.
    -- pitch+ = nose down = negative Z rotation, so d(pitch)/dt = -av.z.
    -- yaw+ = turning left = +Y rotation.
    self.state.pitch_rate = -rateDps(self.state.angularVelocity.z)
    self.state.yaw_rate = rateDps(self.state.angularVelocity.y)
    self.state.roll_rate = rateDps(self.state.angularVelocity.x)
    self.yaw_rate_dps = self.state.yaw_rate
    if state.sable_error then
        self.last_sable_error = state.sable_error
    end
    return state
end

-- Sample attitude + outputs to stab_log.txt (0.5 s) while banked or pitched.
function Flight:debugAttitude(dt)
    self._dbg_t = (self._dbg_t or 0) + dt
    if self._dbg_t < 0.5 then return end
    self._dbg_t = 0
    local st = self.state
    if math.abs(st.roll or 0) < 1 and math.abs(st.pitch or 0) < 1 then return end
    pcall(function()
        local f = fs.open("stab_log.txt", "a")
        if not f then return end
        local o = self.outputs or {}
        f.writeLine(string.format(
            "t=%.1f pitch=%.1f roll=%.1f base=%s FL=%s FR=%s RL=%s RR=%s rear=%s/%s",
            os.clock(), st.pitch or 0, st.roll or 0,
            tostring(o.speed),
            tostring(o.FL_speed), tostring(o.FR_speed),
            tostring(o.RL_speed), tostring(o.RR_speed),
            tostring(o.rear_fw), tostring(o.rear_bw)))
        f.close()
    end)
end

function Flight:hasFeature(name)
    local f = self.config and self.config.features
    if f and f[name] ~= nil then
        return not not f[name]
    end
    if self.hw and self.hw.hasFeature then
        return self.hw.hasFeature(name)
    end
    return true
end

function Flight:processInputs(keys)
    local limits = self.config.limits

    if self.mode == Flight.MODE_HOVER then
        local move_speed = limits.hover_speed

        if keys.W and keys.W > 0 then
            self.targets.move_forward = move_speed
        elseif keys.S and keys.S > 0 then
            self.targets.move_forward = -move_speed
        else
            self.targets.move_forward = 0
        end

        -- Q/E yaw stick (-1..1): Q left, E right
        local yaw = 0
        if keys.Q and keys.Q > 0 then yaw = -1
        elseif keys.E and keys.E > 0 then yaw = 1 end
        self.targets.yaw_cmd = yaw

    elseif self.mode == Flight.MODE_CRUISE then
        -- Heading stick integrates a wrapped hold target (dt applied in update)
        local yaw = 0
        if keys.Q and keys.Q > 0 then yaw = -1
        elseif keys.E and keys.E > 0 then yaw = 1 end
        self.targets.yaw_cmd = yaw

        -- W/S step the 0..15 rear goal bar: +1 on press, +1 every 0.2 s
        -- while held (4 ticks at 20 Hz). Release holds the goal.
        local repeat_ticks = math.max(1, math.floor(0.2 / (self.tick_rate or 0.05)))
        local step = 0
        if keys.W and keys.W > 0 then
            if not self.cruise_w_held then
                self.cruise_w_held = true
                self.cruise_w_ticks = 0
                step = step + 1
            else
                self.cruise_w_ticks = self.cruise_w_ticks + 1
                if self.cruise_w_ticks >= repeat_ticks then
                    self.cruise_w_ticks = 0
                    step = step + 1
                end
            end
        else
            self.cruise_w_held = false
        end
        if keys.S and keys.S > 0 then
            if not self.cruise_s_held then
                self.cruise_s_held = true
                self.cruise_s_ticks = 0
                step = step - 1
            else
                self.cruise_s_ticks = self.cruise_s_ticks + 1
                if self.cruise_s_ticks >= repeat_ticks then
                    self.cruise_s_ticks = 0
                    step = step - 1
                end
            end
        else
            self.cruise_s_held = false
        end
        if step ~= 0 then
            -- Cruise floor is speed level 1 (can't go lower); estop/mode
            -- changes can still put the goal at 0 (props stopped).
            self.targets.speed = clamp((self.targets.speed or 0) + step, 1, 15)
        end

        self.targets.move_forward = 0
    end
end

-- Rotation stabilizer:
--  - Pilot stick: rate command + gyro damp, integrates heading hold target
--  - Stick centered: hold capture heading with wrapped-error PID + rate damp
--  - Returns prop yaw tilt (-tilt_max..tilt_max); rear thrusters are not
--    steered anymore (single W/S speed level only)
function Flight:rotationControl(dt, yaw_stick, tilt_max)
    local state = self.state
    local rate = self.yaw_rate_dps
    local yaw_tilt = 0

    if math.abs(yaw_stick) > 0.05 then
        -- Rate command while stick held (deg/s), damp toward that rate
        local rate_target = yaw_stick * 35
        local rate_err = rate_target - rate
        local damp = clamp(rate_err / 45, -1, 1) * tilt_max * 0.4
        local direct = yaw_stick * tilt_max * 0.6
        yaw_tilt = clamp(direct + damp, -tilt_max, tilt_max)

        -- Keep hold target tracking so release does not snap
        if not self.heading_valid then
            self:captureHeading()
        end
        self.targets.yaw = wrapDeg(self.targets.yaw + yaw_stick * 30 * dt)
        self.pid.yaw:reset()
        return yaw_tilt
    end

    -- Hands-off: no prop-tilt stabilisation (tilt is piloting-only for now;
    -- heading autopilot via tilt may come later).
    if not self.heading_valid then
        self:captureHeading()
    end

    local err = angleError(self.targets.yaw, state.yaw)
    local pid = self.pid.yaw

    local p = pid.kp * err
    pid.integral = clamp(pid.integral + err * dt, -pid.integral_limit, pid.integral_limit)
    local i = pid.ki * pid.integral
    -- Damp absolute rotation (positive yaw rate = turning left/increasing yaw)
    local d = -pid.kd * rate

    yaw_tilt = 0
    local out = clamp(p + i + d, -pid.output_limit, pid.output_limit)

    -- Deadband: avoid micro-wiggle when nearly on heading and still
    if math.abs(err) < 0.35 and math.abs(rate) < 1.5 then
        yaw_tilt = 0
        pid.integral = pid.integral * 0.9
    end

    return yaw_tilt
end

function Flight:update()
    -- Fixed 20 Hz control period (timer is started at 0.05s)
    local dt = self.tick_rate
    if dt <= 0 then dt = 0.05 end
    self.last_update = os.clock()
    self.update_count = self.update_count + 1

    self:updateState()
    self:debugAttitude(dt)

    self.proximity = self.hw.getProximity() or 0
    local prox_cfg = self.config.proximity or {}
    local landed_thr = prox_cfg.landed_threshold or 15
    local deploy_thr = prox_cfg.gear_deploy_threshold or 1

    -- Laser under/near the gear: any detection at or above the deploy
    -- threshold forces gear down. Re-assert every tick (not just on the
    -- rising edge) so a missed setGear / state desync cannot stick.
    if self:hasFeature("gear") and self.proximity >= deploy_thr then
        if not self.gear_down then
            self.gear_settle = prox_cfg.gear_settle_ticks or 20
            self._prox_deployed = true
            if self.onGearAutoDeploy then
                pcall(self.onGearAutoDeploy, self.proximity)
            end
        end
        self.gear_down = true
        self.hw.setGear(true)
    end
    if self.gear_down then
        if self.gear_settle and self.gear_settle > 0 then
            self.gear_settle = self.gear_settle - 1
        end
    else
        self.gear_settle = 0
        self._prox_deployed = false
    end

    -- Ground contact: latch only after LAND_GROUND_TICKS consecutive ticks
    -- at/above the landed threshold (filters single-sensor spikes).
    -- Gearless ships: no gear to settle, so ground contact is immediate
    local gear_ready = (not self:hasFeature("gear"))
        or (self.gear_down and (not self.gear_settle or self.gear_settle <= 0))
    if self.proximity >= landed_thr and gear_ready then
        self._ground_ticks = (self._ground_ticks or 0) + 1
        if not self.landed and self._ground_ticks >= LAND_GROUND_TICKS then
            self.landed = true
            if self.land_state == Flight.LAND_DESCEND or self.land_state == Flight.LAND_ARMED then
                self.land_state = Flight.LAND_TOUCH
            elseif self.land_state == Flight.LAND_IDLE then
                self.land_state = Flight.LAND_DONE
            end
        end
    else
        self._ground_ticks = 0
        if self.landed and self.proximity < (landed_thr - 1) and self.targets.altitude > self.state.altitude + 1 then
            -- climbing away
    self.landed = false
    self.land_position = nil -- world coords recorded at touchdown
            if self.land_state == Flight.LAND_DONE or self.land_state == Flight.LAND_TOUCH then
                self.land_state = Flight.LAND_IDLE
                self.auto_land = false
            end
        end
    end

    -- E-stop latch first: outputs are cut while latched.
    if self.estop then
        self:cutPropsSoft()
        self:applyOutputs()
        return self.outputs
    end

    -- Waypoint AUTOPILOT FIRST: it reads only state/targets/land_state (no
    -- outputs) and computes mode, yaw/altitude/speed targets, phases and the
    -- reverse-brake flag for THIS tick — so the mode function below checks
    -- the position AND applies the correction inside the same 20 Hz tick
    -- (the old AP-last order deferred every correction by one full tick).
    self:updateAutopilot(dt)

    if self.mode == Flight.MODE_HOVER then
        self:updateHover(dt)
    elseif self.mode == Flight.MODE_CRUISE then
        self:updateCruise(dt)
    end

    self:updateAutoLand(dt)

    -- Reverse brake must be written AFTER the mode function wrote the rear
    -- outputs (updateHover zeroes them; updateCruise writes level) and after
    -- auto-land's pulsed rear writes — exactly where the AP block used to
    -- sit when it ran last. The flag itself is computed above, same tick.
    if self.ap and self.ap.brake_reverse then
        local brk = clamp(math.ceil((self.state.speed or 0) * 3), 1, 8)
        self:apRear(brk, true)
    end

    if self.landed and not self.auto_land then
        -- idle on ground: creep + anti-drift (unless pilot already commanded climb)
        local climbing = self.targets.altitude > self.state.altitude + 0.5
        if not climbing then
            self:updateLandedIdle(dt)
        end
    end

    self:runUnflip(dt)

    self:applyOutputs()
    return self.outputs
end

-- Parked: uniform creep speed (slow-down wire 14). No tilt, no leveling.
function Flight:updateLandedIdle(dt)
    local limits = self.config.limits or {}
    local creep = limits.landed_creep or 1

    self.pid.altitude:reset()
    self:setUniformSpeed(creep)
    self.outputs.FL_tilt = 0
    self.outputs.FR_tilt = 0
    self.outputs.RL_tilt = 0
    self.outputs.RR_tilt = 0
    self.outputs.tilt_fwd = 0
    self.outputs.tilt_bwd = 0
    self.outputs.rear_fw = 0
    self.outputs.rear_bw = 0
    self.outputs.rear_rev = 0
end

-- Auto-landing: fore-aft drift hold with the rear thrusters. Damps
-- longitudinal velocity (drifting forward -> reverse link ON + normal
-- thrust pushes backward; backward drift -> thrust alone). The fore/aft
-- axis is the ship's NOSE direction from the orientation quaternion, so
-- the projection cannot pick up yaw-convention sign errors. Reverse needs
-- mapping.rev (REAR relay top face) wired.
function Flight:landingAssist(dt)
    if self.estop then return end
    local state = self.state
    local vel = state.velocity or { x = 0, y = 0, z = 0 }
    local fwd = state.forward or { x = 0, y = 0, z = 0 }
    local fwd_vel = (vel.x * fwd.x + vel.y * fwd.y + vel.z * fwd.z)
        * LAND_FA_SIGN
    -- Gentle pulsed corrections: strength is a coarse number, so trim with
    -- time instead — short bursts on a fixed window whose duty grows with
    -- the excess velocity but never exceeds LAND_FA_DUTY (split-second
    -- corrections, not a continuous shove).
    self.fa_phase = ((self.fa_phase or 0)
        + (dt or 0.05) / LAND_FA_PERIOD) % 1
    local level, rev = 0, false
    local a = math.abs(fwd_vel)
    if a > LAND_FA_DEAD then
        rev = fwd_vel > 0 -- moving forward -> reverse + thrust = push back
        local rev_ok = (not rev) or self:hasFeature("rear_reverse")
        local duty = math.min((a - LAND_FA_DEAD) / LAND_FA_FULL, 1)
            * LAND_FA_DUTY
        if rev_ok and self.fa_phase < duty then
            level = clamp(a * LAND_FA_KP, 0, 15)
        end
        if not rev_ok then rev = false end
    end
    self.outputs.rear_fw = level
    self.outputs.rear_bw = level
    self.outputs.rear_rev = rev and 1 or 0
end

function Flight:updateAutoLand(dt)
    if not self.auto_land then
        if self.land_state == Flight.LAND_TOUCH or self.land_state == Flight.LAND_DESCEND then
            -- finished or aborted mid-way handled elsewhere
        end
        return
    end

    if self.land_state == Flight.LAND_ARMED then
        self.gear_down = true
        self.hw.setGear(true)
        self:landingAssist(dt)
        local armed_ready = (not self:hasFeature("gear"))
            or (not self.gear_settle or self.gear_settle <= 0)
        local armed_land_thr = (self.config.proximity or {}).landed_threshold or 15
        if armed_ready and self.proximity >= armed_land_thr then
            self.land_state = Flight.LAND_TOUCH
        elseif armed_ready then
            self.land_state = Flight.LAND_DESCEND
            -- start slightly above current and walk target down
            self.targets.altitude = self.state.altitude
        end
        -- else: gear still settling, stay ARMED until it finishes
    end

    -- Hold the fire-time heading for the whole sequence: if the ship
    -- rotates, the hands-off yaw law drives it back to the recorded value.
    if self.land_heading then
        self.targets.yaw = self.land_heading
        self.heading_valid = true
    end

    if self.land_state == Flight.LAND_DESCEND then
        -- Runaway-goal safety: the goal kept walking down after the ship
        -- stopped (ground latch never fired). Freeze the goal and ask
        -- os_main for a full shutdown (clutch decouple + splash). The
        -- climb-rate guard keeps a mid-air catch-up (fast fall, big error)
        -- from tripping it.
        local alt_err = self.state.altitude - self.targets.altitude
        if alt_err > LAND_ALT_ERR_SHUTDOWN
            and (self.state.climb_rate or 0) > -3 then
            self.targets.altitude = self.state.altitude
            if not self.shutdown_request then
                self.shutdown_request =
                    string.format("land alt error %.0f m", alt_err)
            end
        end

        local rate = (self.config.limits and self.config.limits.land_descent_rate) or 12.0
        local land_thr = (self.config.proximity or {}).landed_threshold or 15
        -- Freeze the walking target once the sensor says touchdown range:
        -- the debounced ground-contact latch below finishes the landing.
        if self.proximity < land_thr and not self.shutdown_request then
            self.targets.altitude = self.targets.altitude - rate * dt
            if self.targets.altitude < 0 then
                self.targets.altitude = 0
            end
        end
        self:landingAssist(dt)
        if not self.heading_valid then
            self:captureHeading()
        end
    end

    if self.land_state == Flight.LAND_TOUCH then
        self.landed = true
        self.land_state = Flight.LAND_DONE
        self.targets.altitude = self.state.altitude
        -- touchdown coordinates: reference point for future autopilot work
        local p = self.state.position
        self.land_position = { x = p.x, y = p.y, z = p.z }
        -- keep gear down
        self.gear_down = true
        self.hw.setGear(true)
    end

    if self.land_state == Flight.LAND_DONE then
        self.auto_land = false
    end
end

function Flight:cutPropsSoft()
    self.outputs.speed = 0
    self.outputs.FL_speed = 0
    self.outputs.FR_speed = 0
    self.outputs.RL_speed = 0
    self.outputs.RR_speed = 0
    self.outputs.FL_tilt = 0
    self.outputs.FR_tilt = 0
    self.outputs.RL_tilt = 0
    self.outputs.RR_tilt = 0
    self.outputs.rear_fw = 0
    self.outputs.rear_bw = 0
    self.outputs.rear_rev = 0
end

function Flight:setUniformSpeed(v)
    v = clamp(v or 0, 0, 15)
    self.outputs.speed = v
    self.outputs.FL_speed = v
    self.outputs.FR_speed = v
    self.outputs.RL_speed = v
    self.outputs.RR_speed = v
end

function Flight:updateHover(dt)
    local state = self.state
    local targets = self.targets
    local limits = self.config.limits
    local tilt_max = limits.tilt_max or 12
    local hover, kh, den = hoverFF(limits, state) -- height/rate-scaled feedforward
    local hmin = limits.hover_min_speed or 0
    local hmax = limits.hover_max_speed or 15

    -- Parked: update() applies creep via updateLandedIdle
    if self.landed and not self.auto_land
        and not (targets.altitude > state.altitude + 0.5) then
        self.pid.pitch:reset()
        self.pid.roll:reset()
        return
    end

    -- Sticks as -1..1
    local fwd = 0
    if targets.move_forward > 0 then fwd = 1
    elseif targets.move_forward < 0 then fwd = -1 end

    local yaw_stick = targets.yaw_cmd or 0

    -- Auto-landing owns the heading: pilot Q/E forced to center so the same
    -- hands-off law (rotationControl with stick 0) holds the current heading.
    if self.auto_land and (self.land_state == Flight.LAND_ARMED
        or self.land_state == Flight.LAND_DESCEND) then
        yaw_stick = 0
    end

    local yaw_tilt = self:rotationControl(dt, yaw_stick, tilt_max)

    -- Tilt is TRANSLATION, not angle control. The props only vector fore/aft
    -- (tilt_fwd/tilt_bwd), so:
    --   collective  = all four props the same angle -> forward/back thrust.
    --                 Only wanted when the ship is otherwise stationary;
    --                 asking for translation and yaw at once fights over the
    --                 same actuator.
    --   yaw_tilt    = left pair one way, right pair the other -> a pure yaw
    --                 couple (see AP_YAW_ROLL_COUPLING).
    -- Angle control (pitch/roll) is PROP SPEED, below, never tilt.
    local collective = -fwd * tilt_max
    -- Yaw gets priority on the shared tilt authority. Sharing it outright let
    -- a hard turn saturate the sum and CANCEL forward thrust (collective at
    -- -tilt_max plus yaw at +tilt_max clamps one side to 0), so the ship
    -- lost all drive mid-turn. Fade the collective as the yaw demand grows:
    -- full yaw = no translation request, which is the intended behaviour.
    if math.abs(yaw_tilt) > 0.01 then
        collective = collective * (1 - math.min(1, math.abs(yaw_tilt) / tilt_max))
    end

    -- Stability via prop speed REDUCTION only (never tilt, never speeding a
    -- prop above the altitude-PID base): PID leveling + gyro damp toward 0
    -- deg attitude, stepped cap by attitude error: 0 below 2 deg (deadband;
    -- larger = the ship leans and strafes off-course, smaller = wobble/
    -- overshoot returns), 2 units at 2-6 deg, 4 at 6-12 deg, 6 above 12 deg
    -- (high-angle authority — 4 was "not strong enough, ship goes into weird
    -- angles"). STABILITY ALWAYS WINS under the autopilot: only a MANUAL
    -- W/S stick fades the pitch axis (the pilot's angle-maneuver override);
    -- AP-driven forward tilt does NOT fade it. PIDs update every tick so the
    -- derivative state stays fresh under override.
    -- Yaw is not a free manoeuvre: the hull turns about an axis AFT of the
    -- centre of mass (rear fin drag), so commanding yaw also rolls and
    -- pitches it. Previously the levelling PIDs only saw that as a
    -- disturbance and chased it, which is the rock/wiggle through every
    -- turn. Estimate the coupling from the commanded tilt and aim the PIDs at
    -- the compensating attitude instead, so the correction lands in the same
    -- tick. Still reduction-only: raising a prop above base has no headroom
    -- at altitude.
    -- Both terms are bounded. They compensate for the attitude the hull picks
    -- up while yawing about an axis aft of the centre of mass, so they are a
    -- TRIM, and a trim is small. AP_YAW_ROLL_COUPLING is still an unmeasured
    -- guess: unclamped, full yaw asked the stabiliser to hold 0.55*12 = 6.6
    -- deg of bank and 3.6 deg of pitch, which is not a correction any more --
    -- it is a hard turn command, and with the cap correctly keyed to the error
    -- the stabiliser now obeys it hard enough to fly the ship off its bearing.
    -- Bounding it means a too-small guess under-corrects (the stabiliser still
    -- trims a little) instead of commanding an attitude that wrecks the turn.
    -- Read from config so the trim can be calibrated per ship and per world
    -- without editing code, and so a test can exercise the enabled case.
    local yc = self.config.limits or {}
    local k_roll = tonumber(yc.yaw_roll_coupling)
    local k_pitch = tonumber(yc.yaw_pitch_coupling)
    if k_roll == nil then k_roll = AP_YAW_ROLL_COUPLING end
    if k_pitch == nil then k_pitch = AP_YAW_PITCH_COUPLING end
    local yaw_roll_ff = clamp(-k_roll * yaw_tilt, -AP_YAW_FF_MAX, AP_YAW_FF_MAX)
    local yaw_pitch_ff = clamp(-k_pitch * yaw_tilt, -AP_YAW_FF_MAX, AP_YAW_FF_MAX)
    local pitch_out = self.pid.pitch:update(0, state.pitch - yaw_pitch_ff, dt)
    local roll_out = self.pid.roll:update(0, state.roll - yaw_roll_ff, dt)
    local pitch_auth = (self.ap and 1) or (1 - math.min(1, math.abs(fwd)))
    local function stabCap(att)
        local a = math.abs(att)
        if a < 2 then return 0 end
        if a <= 6 then return 2 end
        if a <= 12 then return 4 end
        return 6
    end
    -- Auto-land roll strengthening (speed-diff only: A/D roll-via-tilt is not
    -- a roll here — tilt is pitch/yaw — so we tighten the differential-stabiliser
    -- deadband and raise its cap while landing so the ship stays levelled).
    -- CRITICAL: keep this; without it touchdown can be made on a leaning hull.
    local roll_dead = self.auto_land and LAND_ROLL_DEAD or 2
    local roll_top = self.auto_land and LAND_ROLL_CAP or 4
    local function rollCap(att)
        local a = math.abs(att)
        if a < roll_dead then return 0 end
        if a <= 6 then return math.max(1, math.floor(roll_top / 2 + 0.5)) end
        if a <= 12 then return roll_top end
        return roll_top + 2
    end
    -- The cap is a gain limit on "how far is the ship from where it should
    -- be", so it has to be keyed to the PID ERROR, not to the measured
    -- attitude. Those are the same quantity only while the setpoint is level
    -- -- and it no longer is, because the yaw feedforward above aims the PIDs
    -- at a compensating attitude of up to 0.55*12 = 6.6 deg of roll and
    -- 0.30*12 = 3.6 deg of pitch.
    --
    -- Keyed to the attitude, a ship sitting near level mid-turn measured
    -- |roll| < 2 and was handed a cap of ZERO: stabilisation switched itself
    -- off at the exact moment the error was largest. It then had its gain
    -- doubled crossing 6 deg on the way to its own 6.6 deg target, and
    -- retriggered every breakpoint again as the converging bearing walked the
    -- setpoint back down through them. Stepping loop gain while the error is
    -- still live is what turns a turn into a rock.
    --
    -- These are the same errors the PIDs compute internally (their setpoint is
    -- 0, their measurement is state.X - ff), so the cap and the correction
    -- can no longer disagree. With no yaw command -- every level, climb and
    -- landing case the caps were tuned on -- ff is 0, the error equals the
    -- attitude, and the schedule is bit-for-bit the old one.
    local pitch_err = yaw_pitch_ff - (state.pitch or 0)
    local roll_err = yaw_roll_ff - (state.roll or 0)
    local pitch_cap = stabCap(pitch_err) * pitch_auth
    local roll_cap = rollCap(roll_err)
    -- Pressure- + climb-rate-scheduled authority (scale = kh/den): prop
    -- speed DIFS make thrust pressure-scaled AND cut by the (1 - v/airflow)
    -- factor while the ship climbs, but the disturbance (gravity on an
    -- off-centre hull) does neither — at y260 the caps only deliver 45% of
    -- their sea-level moment, and a climb at v=8 cuts the correction
    -- another 32% (the hull noses up and the weak diff never arrives).
    -- Multiplying corr + cap by kh/den restores ground-equivalent authority
    -- at any height AND climb rate (kh=1, den=1 near the ground and in
    -- level flight, so takeoff/landing/level behaviour is untouched).
    local scale = kh / den
    local pitch_corr = clamp((pitch_out - 0.25 * (state.pitch_rate or 0)) * scale,
        -pitch_cap * scale, pitch_cap * scale)
    local roll_corr = clamp((roll_out - 0.25 * (state.roll_rate or 0)) * scale,
        -roll_cap * scale, roll_cap * scale)

    -- Time-domain precision: strength is quantized, so trim with duration —
    -- a pulse train (STAB_PERIOD window) whose duty grows 0 -> 0.5 -> 1.0
    -- across the 2 deg deadband and the 2-10 deg band (floor raised from
    -- 0.3: at low error the old train was off 70% of the time, which read
    -- as "not correcting" during a climb). Above 10 deg the capped
    -- correction holds continuously. Zero duty (deadband or stick override
    -- via pitch_auth) gates the axis off entirely.
    self.stab_phase = (self.stab_phase + dt / STAB_PERIOD) % 1
    local function stabDuty(att)
        local a = math.abs(att)
        if a < 2 then return 0 end
        if a > 10 then return 1 end
        return 0.5 + 0.5 * (a - 2) / 8
    end
    local function rollDuty(att)
        local a = math.abs(att)
        if a < roll_dead then return 0 end
        if a > 10 then return 1 end
        if self.auto_land then
            return 0.6 + 0.4 * (a - roll_dead) / (10 - roll_dead) -- stronger, sooner
        end
        return 0.5 + 0.5 * (a - 2) / 8
    end
    -- Same reasoning as the caps above: the deadband here means "am I already
    -- where I was told to be", so it has to be measured against the PID error.
    -- Keyed to the raw attitude it reads a trimmed ship as perfectly level and
    -- gates the axis off. Under the autopilot this is currently masked (the
    -- override below forces continuous correction), but in manual flight a
    -- yaw trim would be silently discarded, and the day that override is
    -- revisited the bug returns. With no trim -- the default -- the error
    -- equals the attitude and this is the original schedule unchanged.
    local pitch_duty = stabDuty(pitch_err) * pitch_auth
    local roll_duty = rollDuty(roll_err)
    if self.ap then
        -- Under the autopilot the pulse train is OFF: duty 0.5-1.0 halves
        -- attitude authority and rings the hull through long climbs ("tips
        -- up, wobbles"). The caps + deadband still bound the correction —
        -- this only makes it CONTINUOUS (cruise has run continuous all
        -- along and the pilot called it perfect). Manual flight unchanged.
        pitch_duty = pitch_auth
        roll_duty = 1
    end
    if self.stab_phase >= pitch_duty then pitch_corr = 0 end
    if self.stab_phase >= roll_duty then roll_corr = 0 end

    local FL_tilt = clamp(collective + yaw_tilt, -tilt_max, tilt_max)
    local FR_tilt = clamp(collective - yaw_tilt, -tilt_max, tilt_max)
    local RL_tilt = clamp(collective + yaw_tilt, -tilt_max, tilt_max)
    local RR_tilt = clamp(collective - yaw_tilt, -tilt_max, tilt_max)

    -- TILT IS A BINARY ACTUATOR. The block rotates each prop a fixed
    -- AP_TILT_ANGLE (25 deg) forward or backward and leaves it level otherwise;
    -- the analog level is not proportional, so a command of 6 and a command of
    -- 12 tilt by exactly the same 25 deg. Consequences:
    --
    --  * Tilting REDUCES vertical thrust to cos(25 deg) = 0.906 of level, i.e.
    --    the ship loses 9.4% of its lift the moment it translates or yaws.
    --    mean_tilt_lift below is what is left, and the altitude channel scales
    --    its demand by 1/mean_tilt_lift to pay it back. Without this the ship
    --    sags every time it moves.
    --  * A collective value that is merely SMALL does not mean "a little
    --    thrust" -- it still means a full 25 deg. So the fade above is only
    --    meaningful in that it snaps one side to level, which trades thrust for
    --    yaw. tiltVerticalFactor quantises explicitly so the model and the
    --    code agree on what the block actually does.
    local tilt_vert = 0
    for _, tv in ipairs({ FL_tilt, FR_tilt, RL_tilt, RR_tilt }) do
        tilt_vert = tilt_vert + math.cos(tiltPhysicalAngle(tv, tilt_max) * AP_TILT_RAD)
    end
    local mean_tilt_lift = clamp(tilt_vert / 4, 0.1, 1)

    -- Altitude: mean prop speed (attitude uses per-prop speed differentials).
    -- D uses climb rate (measurement) so altitude steps do not kick.
    local alt_output = self.pid.altitude:update(targets.altitude, state.altitude, dt, state.climb_rate)
    local base_speed = 0
    local flying = false

    if not self.landed then
        base_speed = clamp((hover + alt_output) / mean_tilt_lift, hmin, hmax)
        flying = true
    elseif targets.altitude > state.altitude + 0.5 then
        base_speed = clamp((hover + alt_output) / mean_tilt_lift, hmin, hmax)
        flying = true
    else
        base_speed = 0
        FL_tilt, FR_tilt, RL_tilt, RR_tilt = 0, 0, 0, 0
        self.pid.altitude:reset()
    end

    if not flying then
        base_speed = 0
    end

    -- A/P aim CLIMB step: the autopilot owns the uniform prop speed with
    -- the velocity-profile demand computed in updateAutopilot, so the ship
    -- settles AT the frozen goal instead of sailing past it (no drag).
    -- Attitude stabilisation (reduce-only, above) stays active on top.
    if flying and self.ap and self.ap.phase == "aim" and self.ap.climb_demand then
        base_speed = clamp(self.ap.climb_demand, hmin, hmax)
    end

    -- LAND_DESCEND uses the same hover+PID law as normal flight: the walking
    -- altitude target alone produces the descent command. (A reduced
    -- feedforward here made the ship free-fall below the path.)
    if flying then
        -- ATTITUDE CORRECTION MUST NOT SPEND THE LIFT.
        --
        -- The stabiliser is reduce-only, so a correction costs altitude
        -- directly. High up, hover already wants 14.3 of 15, leaving under one
        -- unit of margin: a routine attitude correction spent it, the mean prop
        -- speed dropped below hover, the ship started sinking, and the
        -- stabiliser then kept cutting to chase an attitude it no longer had
        -- the thrust to correct -- it fell 180 m and parked there, roll and
        -- pitch frozen at 16 degrees on 7/15 thrust. That feedback loop is
        -- exactly the "climb does ups and downs" symptom.
        --
        -- Correction is DIFFERENTIAL, so only its COMMON-MODE part costs lift:
        -- the mean prop speed after the cut is
        --     base - (|pitch_corr| + |roll_corr|) / 2
        -- (one of p_front/p_rear is always zero, likewise left/right). Cap that
        -- loss at the headroom above hover, scaling both axes together so the
        -- attitude correction stays in proportion and simply gets gentler as
        -- the lift budget runs out. Altitude wins; attitude gets whatever is
        -- left, instead of attitude winning and the ship falling out of the sky.
        -- NOTE: attitude correction is deliberately NOT budgeted against
        -- hover thrust here. It was tempting to cap it by the spare thrust
        -- above hover, on the grounds that a levelling correction must not
        -- steal the climb's lift. Measured against the two test models that
        -- idea is wrong, and in the trusted vertical model it is actively
        -- harmful: mid-climb the stabiliser legitimately asks for ~6.8 units
        -- of differential with only ~0.1 spare, and uncapped it still climbs
        -- and still holds pitch inside 6 deg -- which is exactly the 22/22
        -- green baseline, and the behaviour the shipped cruise was tuned on.
        -- Budgeting it collapsed pitch to 23 deg (limit 6) and a hard cap at
        -- the top of the climb also pinned mean thrust at 7 against a hover
        -- demand of 13.5. The vertical model and the 0-15 Create model also
        -- do not share thrust scaling, so a fraction tuned on one is simply
        -- wrong on the other. Allocation stays uncapped; the altitude/attitude
        -- interaction is handled by the climb's own rate gain instead.
        local mean_loss = (math.abs(pitch_corr) + math.abs(roll_corr)) / 2
        if mean_loss < 0 then mean_loss = 0 end
        self.outputs.speed = base_speed
        local p_front = math.max(pitch_corr, 0)
        local p_rear = math.max(-pitch_corr, 0)
        local r_left = math.max(-roll_corr, 0)
        local r_right = math.max(roll_corr, 0)
        self.outputs.FL_speed = clamp(base_speed - p_front - r_left, 0, 15)
        self.outputs.FR_speed = clamp(base_speed - p_front - r_right, 0, 15)
        self.outputs.RL_speed = clamp(base_speed - p_rear - r_left, 0, 15)
        self.outputs.RR_speed = clamp(base_speed - p_rear - r_right, 0, 15)
    else
        self:setUniformSpeed(0)
    end
    self.outputs.FL_tilt = FL_tilt
    self.outputs.FR_tilt = FR_tilt
    self.outputs.RL_tilt = RL_tilt
    self.outputs.RR_tilt = RR_tilt
    self.outputs.tilt_fwd = math.max(0, collective)
    self.outputs.tilt_bwd = math.max(0, -collective)

    -- Hover: rear thrusters always off (cruise only)
    self.outputs.rear_fw = 0
    self.outputs.rear_bw = 0
    self.outputs.rear_rev = 0 -- never inherit a stale reverse (e.g. after landing)
end

function Flight:updateCruise(dt)
    local state = self.state
    local targets = self.targets
    local limits = self.config.limits or {}
    local hover, kh, den = hoverFF(limits, state) -- height/rate-scaled prop feedforward
    local hmin = limits.hover_min_speed or 0
    local hmax = limits.hover_max_speed or 15

    if self.landed and not self.auto_land
        and not (targets.altitude > state.altitude + 0.5) then
        return
    end

    local alt_output = self.pid.altitude:update(targets.altitude, state.altitude, dt, state.climb_rate)

    -- Cruise flies wings-level: all prop tilt is zeroed further down, so there
    -- is no tilt lift loss to pay back and mean_tilt_lift is exactly 1. Kept as
    -- a named value so both flight modes share one demand formula.
    local mean_tilt_lift = 1

    local base_speed = 0
    local flying = false
    if not self.landed then
        base_speed = clamp((hover + alt_output) / mean_tilt_lift, hmin, hmax)
        flying = true
    elseif targets.altitude > state.altitude + 0.5 then
        base_speed = clamp((hover + alt_output) / mean_tilt_lift, hmin, hmax)
        flying = true
    else
        base_speed = 0
        self.pid.altitude:reset()
    end

    if not flying then
        base_speed = 0
    end

    self:setUniformSpeed(base_speed)

    -- Sustained bank for heading control + PITCH LEVELLING (AUTOPILOT
    -- cruise phases only): drive the roll PID to a NON-ZERO setpoint so the
    -- ship banks and the bank's tilted lift vector yaws it onto the bearing,
    -- and drive the pitch PID to 0 so rear thrust along the nose cannot
    -- pitch the ship into a dive (R1: cruise had ZERO attitude control, so
    -- autopilot spiralled into the ground and unflip then bailed on the
    -- landed check). No stabCap/stabDuty here (those gate toward level);
    -- both axes hold continuously, capped at AP_STAB_OUT per axis.
    -- If your ship does NOT bank->yaw, flip AP_BANK_SIGN first, then physics.
    if self.ap and not self.ap.paused
        and (self.ap.phase == "cruise" or self.ap.phase == "correct"
             or self.ap.phase == "arrive") then
        local err = self.ap.err or 0
        -- Rate lead: while the bank yaws the ship onto the bearing, subtract
        -- the ongoing yaw rate from the error so the command starts easing
        -- BEFORE the bearing is reached — no overshoot / coast-through.
        local eff = err - AP_BANK_RATE_LEAD * (state.yaw_rate or 0)
        local roll_target = 0
        if math.abs(eff) > AP_BANK_DEAD then
            roll_target = clamp(AP_BANK_KP * eff, -AP_BANK_MAX, AP_BANK_MAX) * AP_BANK_SIGN
        end
        -- Bank-to-turn is a luxury the ship cannot always afford. A bank is
        -- paid for out of the MEAN thrust (the differential is reduce-only),
        -- so climbing while banked can stall: measured on the 0-15 model, the
        -- ship sat 35 m under target holding a 6.8 deg bank, because the
        -- levelling correction and the climb were competing for the same
        -- units and attitude -- the faster loop -- kept winning.
        --
        -- So fade the bank out as the altitude error grows and bring it back
        -- once the ship is on altitude. The recovery climb is then flown
        -- level, and heading control resumes at the target. This attenuates
        -- the DEMAND rather than capping thrust, which is why it does not
        -- disturb the levelling authority the vertical tests pin down.
        local alt_err = math.abs((targets.altitude or 0) - (state.altitude or 0))
        if alt_err > 1e-6 then
            roll_target = roll_target * (1 - clamp(alt_err / AP_BANK_ALT_FADE, 0, 1))
        end
        local roll_out = self.pid.roll:update(roll_target, state.roll, dt)
        local pitch_out = self.pid.pitch:update(0, state.pitch, dt)
        -- Same kh/den authority scheduling as updateHover (pressure AND
        -- climb-rate cut the prop DIFS but not the hull disturbance);
        -- scale=1 at sea level in level flight -> cruise feel unchanged.
        local scale = kh / den
        local roll_corr = clamp((roll_out - 0.15 * (state.roll_rate or 0)) * scale,
            -AP_STAB_OUT * scale, AP_STAB_OUT * scale)
        local pitch_corr = clamp((pitch_out - 0.15 * (state.pitch_rate or 0)) * scale,
            -AP_STAB_OUT * scale, AP_STAB_OUT * scale)
        -- Same lift-budget cap as updateHover: a reduce-only attitude
        -- correction costs altitude, and near the ceiling there is no altitude
        -- to spend. Without this the correction drives the mean prop speed
        -- below hover and the ship sinks out from under itself.
        -- NOTE: attitude correction is deliberately NOT budgeted against
        -- hover thrust here. It was tempting to cap it by the spare thrust
        -- above hover, on the grounds that a levelling correction must not
        -- steal the climb's lift. Measured against the two test models that
        -- idea is wrong, and in the trusted vertical model it is actively
        -- harmful: mid-climb the stabiliser legitimately asks for ~6.8 units
        -- of differential with only ~0.1 spare, and uncapped it still climbs
        -- and still holds pitch inside 6 deg -- which is exactly the 22/22
        -- green baseline, and the behaviour the shipped cruise was tuned on.
        -- Budgeting it collapsed pitch to 23 deg (limit 6) and a hard cap at
        -- the top of the climb also pinned mean thrust at 7 against a hover
        -- demand of 13.5. The vertical model and the 0-15 Create model also
        -- do not share thrust scaling, so a fraction tuned on one is simply
        -- wrong on the other. Allocation stays uncapped; the altitude/attitude
        -- interaction is handled by the climb's own rate gain instead.
        local mean_loss = (math.abs(pitch_corr) + math.abs(roll_corr)) / 2
        if mean_loss < 0 then mean_loss = 0 end
        local p_front = math.max(pitch_corr, 0)
        local p_rear = math.max(-pitch_corr, 0)
        local r_left = math.max(-roll_corr, 0)
        local r_right = math.max(roll_corr, 0)
        self.outputs.FL_speed = clamp((self.outputs.FL_speed or base_speed) - p_front - r_left, 0, 15)
        self.outputs.FR_speed = clamp((self.outputs.FR_speed or base_speed) - p_front - r_right, 0, 15)
        self.outputs.RL_speed = clamp((self.outputs.RL_speed or base_speed) - p_rear - r_left, 0, 15)
        self.outputs.RR_speed = clamp((self.outputs.RR_speed or base_speed) - p_rear - r_right, 0, 15)
    end

    self.outputs.FL_tilt = 0
    self.outputs.FR_tilt = 0
    self.outputs.RL_tilt = 0
    self.outputs.RR_tilt = 0
    self.outputs.tilt_fwd = 0
    self.outputs.tilt_bwd = 0

    if self.landed then
        self.outputs.rear_fw = 0
        self.outputs.rear_bw = 0
        self.outputs.rear_rev = 0
        return
    end

    -- Back thrusters: ONE speed level (0 = off, cruise 1..15), controlled
    -- only by the W/S goal bar. Both relay faces get the same level; the
    -- hardware layer sends signal = 15 - level (level 15 = signal 0 =
    -- reduction off; level 0 = signal 15 = stopped). No differential or
    -- any other rear control. Reverse (future autopilot) = redstone on
    -- the relay top.
    local level = clamp(targets.speed or 0, 0, 15)
    self.outputs.rear_fw = level
    self.outputs.rear_bw = level
    self.outputs.rear_rev = 0 -- cruise has no brake; wp travel sets this AFTER this tick
end

function Flight:applyOutputs()
    local hw = self.hw

    hw.setPropellerOutput("FL", "speed", self.outputs.FL_speed or self.outputs.speed or 0)
    hw.setPropellerOutput("FR", "speed", self.outputs.FR_speed or self.outputs.speed or 0)
    hw.setPropellerOutput("RL", "speed", self.outputs.RL_speed or self.outputs.speed or 0)
    hw.setPropellerOutput("RR", "speed", self.outputs.RR_speed or self.outputs.speed or 0)

    hw.setPropellerOutput("FL", "tilt_fwd", math.max(0, self.outputs.FL_tilt))
    hw.setPropellerOutput("FL", "tilt_bwd", math.max(0, -self.outputs.FL_tilt))

    hw.setPropellerOutput("FR", "tilt_fwd", math.max(0, self.outputs.FR_tilt))
    hw.setPropellerOutput("FR", "tilt_bwd", math.max(0, -self.outputs.FR_tilt))

    hw.setPropellerOutput("RL", "tilt_fwd", math.max(0, self.outputs.RL_tilt))
    hw.setPropellerOutput("RL", "tilt_bwd", math.max(0, -self.outputs.RL_tilt))

    hw.setPropellerOutput("RR", "tilt_fwd", math.max(0, self.outputs.RR_tilt))
    hw.setPropellerOutput("RR", "tilt_bwd", math.max(0, -self.outputs.RR_tilt))

    hw.setRearOutput("fw", self.outputs.rear_fw)
    hw.setRearOutput("bw", self.outputs.rear_bw)
    hw.setRearReverse((self.outputs.rear_rev or 0) > 0)
end

-- ============================================================
-- Auto-unflip: lift props reversed (redstone link on the computer's back)
-- + opposite-side cut kick, then a violent righting drive back to 0 deg.
-- ============================================================
function Flight:runUnflip(dt)
    local state = self.state
    self.inv_cooldown = math.max(0, self.inv_cooldown - dt)

    if self.unflip then
        local u = self.unflip
        if self.landed or self.estop then
            self:finishUnflip()
            return
        end
        u.t = u.t + dt
        local att = math.max(math.abs(state.pitch), math.abs(state.roll))
        -- kick -> rise (pure ascent, uniform full thrust) -> drive. The rise
        -- phase keeps reversed full thrust on longer so the ship gains
        -- altitude while inverted; skipped if already past halfway.
        if u.phase == "kick" and u.t >= INV_KICK then
            u.phase = att >= INV_REVERSE_OFF and "rise" or "drive"
        elseif u.phase == "rise"
            and (u.t >= INV_KICK + INV_RISE or att < INV_REVERSE_OFF) then
            u.phase = "drive"
        end
        if att <= INV_DONE or u.t >= INV_TIMEOUT then
            self:finishUnflip() -- done, or hard abort after INV_TIMEOUT
            return
        end

        -- Reverse stays on while inverted; drops past halfway so reversed
        -- thrust can never press a levelled ship down.
        local reverse = att >= INV_REVERSE_OFF
        self.hw.setLiftReverse(reverse)

        -- Full thrust either way; no tilt, no rear during the sequence.
        self:setUniformSpeed(15)
        self.outputs.FL_tilt = 0
        self.outputs.FR_tilt = 0
        self.outputs.RL_tilt = 0
        self.outputs.RR_tilt = 0
        self.outputs.tilt_fwd = 0
        self.outputs.tilt_bwd = 0
        self.outputs.rear_fw = 0
        self.outputs.rear_bw = 0

        if u.phase == "kick" then
            -- Opposite pair cut: raw asymmetric reversed-thrust kick.
            if u.cut == "left" then
                self.outputs.FL_speed = 0
                self.outputs.RL_speed = 0
            elseif u.cut == "right" then
                self.outputs.FR_speed = 0
                self.outputs.RR_speed = 0
            elseif u.cut == "front" then
                self.outputs.FL_speed = 0
                self.outputs.FR_speed = 0
            elseif u.cut == "rear" then
                self.outputs.RL_speed = 0
                self.outputs.RR_speed = 0
            end
        elseif u.phase == "drive" then
            -- Drive: violent reduce-only righting from full speed. While the
            -- props run reversed the torque polarity flips, hence `pol`.
            local pol = 1
            if reverse then pol = UNFLIP_DRIVE_POL end
            local v_pitch = pol * clamp(-(UNFLIP_KP * state.pitch
                + UNFLIP_KD * (state.pitch_rate or 0)), -15, 15)
            local v_roll = pol * clamp(-(UNFLIP_KP * state.roll
                + UNFLIP_KD * (state.roll_rate or 0)), -15, 15)
            local p_front = math.max(v_pitch, 0)
            local p_rear = math.max(-v_pitch, 0)
            local r_left = math.max(-v_roll, 0)
            local r_right = math.max(v_roll, 0)
            self.outputs.FL_speed = clamp(15 - p_front - r_left, 0, 15)
            self.outputs.FR_speed = clamp(15 - p_front - r_right, 0, 15)
            self.outputs.RL_speed = clamp(15 - p_rear - r_left, 0, 15)
            self.outputs.RR_speed = clamp(15 - p_rear - r_right, 0, 15)
        end
        return
    end

    -- Detection: near-or-at 180 for INV_HOLD seconds (airborne, no e-stop,
    -- cooldown elapsed).
    local inverted = math.abs(state.pitch) >= INV_ATT
        or math.abs(state.roll) >= INV_ATT
    if inverted and not self.landed and not self.estop
        and self.inv_cooldown <= 0 then
        self.inv_time = self.inv_time + dt
        if self.inv_time >= INV_HOLD then
            self.inv_time = 0
            self.unflip = {
                t = 0,
                phase = "kick",
                cut = pickUnflipCut(state.pitch, state.roll),
            }
        end
    else
        self.inv_time = 0
    end
end

function Flight:finishUnflip()
    self.unflip = nil
    self.inv_time = 0
    self.inv_cooldown = INV_COOLDOWN
    self.hw.setLiftReverse(false)
    self.pid.pitch:reset()
    self.pid.roll:reset()
    self.pid.yaw:reset()
end

function Flight:emergencyStop()
    self.auto_land = false
    self.land_state = Flight.LAND_IDLE
    self.heading_valid = false
    self.targets.yaw_cmd = 0
    self.targets.speed = 0 -- do not retain a cruise speed target across e-stop
    self.estop = true
    self:cancelAutopilot(nil) -- e-stop also aborts the autopilot (no event: estop announces itself)
    self.wp_event = nil       -- do not replay a stale arrived/cancelled event after reboot
    self.unflip = nil       -- cutAllOutputs below also drops the reverse link
    self.inv_time = 0
    self.inv_cooldown = 0
    self.shutdown_request = nil
    self.hw.cutAllOutputs()
    self:cutPropsSoft()
    for _, pid in pairs(self.pid) do
        pid:reset()
    end
end

function Flight:getStatus()
    return {
        mode = self.mode,
        altitude = self.state.altitude,
        target_altitude = self.targets.altitude,
        pitch = self.state.pitch,
        roll = self.state.roll,
        yaw = self.state.yaw,
        heading_target = self.targets.yaw,
        heading_valid = self.heading_valid,
        yaw_rate = self.yaw_rate_dps,
        speed = self.state.speed,
        target_speed = self.targets.speed,
        climb_rate = self.state.climb_rate,
        outputs = self.outputs,
        landed = self.landed,
        gear_down = self.gear_down,
        auto_land = self.auto_land,
        land_state = self.land_state,
        proximity = self.proximity,
        sable_error = self.last_sable_error,
        estop = self.estop,
        unflip = self.unflip ~= nil,
        position = self.state.position,
        land_position = self.land_position,
        ap = self.ap and {
            name = self.ap.name,
            phase = self.ap.phase,
            dist = self.ap.dist,
            progress = self.ap.progress,
            eta = self.ap.eta,
            speed = self.ap.speed,
            paused = self.ap.paused,
        } or nil,
        pid_gains = {
            altitude = self.pid.altitude:getGains(),
            pitch = self.pid.pitch:getGains(),
            roll = self.pid.roll:getGains(),
            yaw = self.pid.yaw:getGains(),
        },
    }
end

return Flight
