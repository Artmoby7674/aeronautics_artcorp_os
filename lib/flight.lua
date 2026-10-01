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
--   aim   (HOVER)  two steps: CLIMB (fixed target, constant-rate transit,
--                  braked arrival with ~zero speed and never above the
--                  goal), then TURN onto the bearing (PD, no overshoot, wait
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
local AP_RECOURSE = 45      -- deg: heading error too big to chip away at —
                            -- re-enter ROTATE (phase 2) instead. The phase
                            -- machine had NO cruise/correct -> aim edge at all,
                            -- so once a run left the first rotation it could
                            -- never re-aim; a large error could only be fed
                            -- to `correct`, which is a brake-and-hold, not a
                            -- re-aim. Was 90 (the comment above it said 60, so
                            -- the two had drifted apart), which left a 90 deg
                            -- error trying to be banked out at AP_BANK_MAX 8
                            -- deg of authority. 45 is outside the bank's useful
                            -- authority but inside "spin round and try again".
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
local AP_BANK_SIGN = 1      -- cruise bank direction. This was -1, and it was
                            -- the "ship tries to yaw right in fast travel"
                            -- report: -1 banks AWAY from the bearing, which is
                            -- positive feedback, not a wrong-way turn.
                            -- The chain, end to end (config/atlas.lua:116 FL
                            -- x=-3 / FR x=+3 => +x is right; hardware.lua:296
                            -- "roll + = right down"; right wing down tilts the
                            -- lift vector right => turns right; and
                            -- apBearingError returns POSITIVE for a target on
                            -- +x, i.e. on the right). Closing a positive error
                            -- therefore needs roll POSITIVE, so the sign is +1.
                            -- With -1 the ship banked left to reach a target
                            -- on its right: error grew, bank grew harder, and
                            -- the leg spiralled away — which is why it read as
                            -- a steady pull to one side rather than a turn that
                            -- failed to converge. Not measurable in the test
                            -- plant (cruise zeroes tilt => fz = 0 => no
                            -- bank->yaw coupling at all), so it is pinned by
                            -- asserting the commanded ROLL sign, below.
local AP_BANK_KP = 0.6      -- deg bank per deg heading error
local AP_BANK_MAX = 8       -- deg max bank command
local AP_BANK_DEAD = 1      -- deg heading deadband (no bank correction)
local AP_BANK_ALT_FADE = 4    -- m: altitude error over which the bank
                            -- command fades to zero (climb first)
local AP_BANK_RATE_LEAD = 0.6 -- s: back off the bank command by yaw_rate so
                            -- the turn bleeds off instead of coasting through
                            -- the bearing (rate lead = angle - k * rate)
local AP_BANK_MIN_SPEED = 6  -- m/s: a bank yaws a ship ONLY by tilting the lift
                            -- vector, so it needs airspeed. Below this the
                            -- bank produces NO yaw while still costing mean
                            -- thrust and rolling the hull — i.e. it can only
                            -- make things worse. Never decelerate below it.
local AP_COURSE_MIN_SPEED = 3 -- m/s: below this the velocity vector is too
                            -- noisy/short to define a course, so the bank
                            -- falls back to the nose heading
local AP_BANK_RATE_FADE = 3  -- m/s: |climb_rate| over which the bank fades out.
                            -- AP_BANK_ALT_FADE keys the bank on altitude
                            -- POSITION error only, which closes up a limit
                            -- cycle rather than damping it: bank -> lift
                            -- vector tilts -> vertical lift drops -> ship
                            -- sinks -> position error grows -> bank fades ->
                            -- ship climbs -> bank re-engages -> sinks again.
                            -- That loop is the slow -3..-30 wiggle, and it
                            -- runs away into the deep dive when the bank is
                            -- large at low thrust margin. The rate term
                            -- breaks it in the same tick the sink starts.
local AP_STAB_OUT = 6       -- max cruise attitude speed-diff units (pitch+roll);
                            -- matches the hover high-angle cap (6). 10 slashed a
                            -- side to 0 and rolled violently. Raise for more.
local AP_STAB_RATE = 1.5    -- max HOVER rate (momentum) term, speed-diff units.
                            -- Deliberately independent of the attitude cap and
                            -- the 2 deg deadband: the deadband gates the
                            -- PROPORTIONAL term so a trimmed hull is left
                            -- alone, but the rate term is what stops the hull
                            -- carrying its own correction through the deadband
                            -- and out the far side. Small -- it only bleeds off
                            -- the momentum the P term just created, it does
                            -- not steer.
local AP_STAB_RATE_K = 0.25  -- rate feedback gain (1/s) shared by hover and
                            -- cruise. Cruise previously ran 0.15, i.e. the hull
                            -- it was trying to stabilise was fed back at less
                            -- than 2/3 the strength, which is why the ringing
                            -- read as "cruise never damps".
local AP_STAB_ADAPT_KNEE = 0.5 -- prop headroom (as a fraction of hmax) below
                            -- which attitude authority starts tapering. Full
                            -- authority while the props have room to give.
local AP_STAB_ADAPT_MIN = 0.2  -- taper floor: corrections shrink as the props
                            -- approach max speed but never vanish, so the hull
                            -- can always be caught.
                            --
                            -- The floor has to be LOW on purpose. scale is
                            -- kh/den * adapt, and kh is itself proportional to
                            -- the prop speed (both go as 1/pressure), so a mild
                            -- taper LOSES to the kh term and corrections still
                            -- grow with altitude -- the exact wiggle that was
                            -- reported. At 0.4 the net scale was 1.15 at y270
                            -- against 1.07 at y80, i.e. still rising. At 0.2 the
                            -- product turns over: 1.07 at y80 (adapt=1, low
                            -- altitude untouched), 1.27 at y150, 0.78 at y270.
                            -- The peak sits in the mid climb, where the ship
                            -- still has plenty of headroom to give.
-- AP_BANK_GIVEUP / AP_BANK_HEADROOM / AP_BANK_AFFORD were REMOVED.
-- They gated bank-to-turn on spare hover headroom, keyed on (hmax - hover) --
-- a quantity that is 0.0 at the ceiling BY CONSTRUCTION. So they switched
-- heading control off exactly where the ship spends the whole leg and handed
-- the bearing back to the hover turn, putting 83% of a nominal cruise through
-- hover tilt-yaw ("cruise still uses hover yaw control"). The justification
-- was a fabricated measurement: this test plant has NO bank->yaw coupling at
-- all -- cruise zeroes prop tilt, so fz = 0 for every prop and the yaw couple
-- YAW_SIGN*x*fz is identically zero, and a pure roll differential held for 100
-- ticks moves yaw_rate by 0.000 deg/s. The "8 deg of bank = 44 deg/s of yaw"
-- figure was read off a correlation, never a cause. A bank does cost mean
-- thrust, and that cost is already paid for by AP_BANK_ALT_FADE and by
-- stabAdapt's taper -- neither switches the heading controller off.
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
-- CLIMB LAW: constant-rate transit, then brake to arrive with ~zero speed.
--
-- The old law chased a goal that ROSE AT 60 m/s while the ship climbed at
-- ~5 m/s. The height error was therefore always enormous, v_des sat on its
-- +-60 clamp for the whole climb, and the collective was pinned at 15/15.
-- At the end the error flipped sign and the collective collapsed to 0: the
-- ship was thrown at the ceiling with no braking authority, fell back, and
-- the cycle repeated. That is the "brutal, slams to max, then to zero,
-- falls like a brick, overshoots again" behaviour.
--
-- What replaces it is standard and boring, which is the point:
--   1. FIXED target. The goal does not move. There is no racing setpoint.
--   2. LINEAR transit. Far from the goal the ship holds ONE modest climb
--      rate (AP_CLIMB_V), so the collective sits at a steady moderate value
--      instead of slamming between the stops.
--   3. BRAKING PROFILE. v_des = min(V, sqrt(2*a_brake*remaining)), i.e. the
--      fastest rate from which the ship can still decelerate to zero exactly
--      at the goal. This is what makes arrival smooth AND makes overshoot
--      structurally impossible rather than merely unlikely.
--   4. NEVER UP past the goal. Once altitude >= goal the climb setpoint is
--      pinned at 0 (never positive) and the collective is capped at hover, so
--      the ship coasts to a stop ON the goal instead of sailing through it.
--      Overshoot prevention is deliberately asymmetric: braking is
--      authoritative, climbing is not.
--   5. A velocity PID closes the loop on MEASURED climb rate
--      (sublevel.getLinearVelocity), and a slew limiter caps how far the
--      collective may move per tick so the props can no longer jump 0 <-> 15.
local AP_CLIMB_V = 8          -- m/s: cruise climb rate in transit. Raised from
                              -- 5 once the measured climb was steady and
                              -- smooth: the headroom cost is paid by
                              -- stabAdapt() tapering attitude authority as the
                              -- props speed up, not by crawling. The v^2 brake
                              -- curve means a higher target costs nothing near
                              -- the goal -- only the mid-climb transit speeds up.
local AP_CLIMB_BRAKE = 0.9    -- m/s^2: assumed braking capability, used only
                              -- to shape v_des. The velocity PID absorbs any
                              -- error between this guess and the real ship, so
                              -- it does not need to be accurate -- only safe
                              -- (start braking early rather than late).
local AP_CLIMB_KP = 0.8       -- prop units per (m/s) of climb-rate error
local AP_CLIMB_KI = 0.10      -- prop units per (m/s) of integrated rate error
                              -- (trims the steady-state so the ship actually
                              -- settles ON the goal instead of near it)
local AP_CLIMB_VLIM = 12      -- m/s: hard clamp on |v_des|
local AP_CLIMB_TOL = 1.0      -- m: arrival band. Deliberately tight and
                              -- one-sided, because the user's priority is
                              -- "never go over the goal"
local AP_CLIMB_STILL = 0.4    -- m/s: |climb rate| that counts as stopped
-- How close the CLIMB phase has to get before it hands over to the turn.
-- This is the height-validation gate, and it is deliberately a DISTANCE, not
-- a "stopped on the goal" test.
--
-- The v^2 brake profile approaches its target as sqrt(remaining), so the last
-- few blocks are always a crawl: measured, the final 20 blocks cost 6.55 s and
-- the final 10 cost 4.85 s, out of a 28.7 s climb. Requiring |rate| <= 0.4 m/s
-- before leaving the phase serialised that crawl in front of the rotation.
--
-- The altitude POSITION PID closes the last blocks far better, and the turn
-- step already runs it (self.targets.altitude = ap.alt) with the rotation, so
-- validating the height here overlaps the two instead of queueing them. At 10
-- blocks out the ship is arriving at ~5.5 m/s, and arresting that needs about
-- 7.6 m of the 10 available (2.0 m/s^2 of real braking at this height) -- just
-- enough margin to hand over without sailing over. That is also what removed a
-- 2.87 block overshoot: the old gate let the ship run the brake profile all
-- the way to remain <= 0 carrying 5+ m/s, where the "never push past the goal"
-- cap on the collective turned a hot arrival into a ballistic one.
local AP_CLIMB_VALIDATE = 10  -- m: hand over to the turn this far out
local AP_CLIMB_BRAKE_GRACE = 6.0 -- s: after the height is validated and the
                              -- phase advances to the turn, the climb law
                              -- keeps flying the braked arrival for this long
                              -- (or until the ship is genuinely settled on the
                              -- goal, whichever comes first). Free: the
                              -- rotation uses yaw, not the collective.
local AP_CLIMB_HANDOVER_SLEW = 2.5 -- s: after the climb hands over, keep the
                              -- slow release rate limiting the collective for
                              -- this long, so the first PID command ramps in
                              -- from the last climb demand instead of stepping
                              -- (see the handover note in the climb step)
-- Slew limit on the collective (prop units per second). The props are a
-- 0..15 actuator that the game integrates; a step change of 15 units in one
-- tick is an enormous impulse and is what made the ship lurch. Limiting the
-- rate of change turns the old bang-bang into a ramp. Release is slow
-- (4/s) so a demand that drops -- e.g. the collective being handed back to
-- the altitude PID -- cannot cut the lift in one tick and drop the ship.
-- Attack is fast (20/s) so genuine disturbances are still answered promptly.
local AP_CLIMB_SLEW_ATTACK = 20  -- prop/s allowed when demand is RISING
local AP_CLIMB_SLEW_RELEASE = 4  -- prop/s allowed when demand is FALLING
local AP_CLIMB_SETTLE_HOLD = 0.4 -- s: arrival must hold this long before the
                              -- turn step begins
local AP_CLIMB_STALL_GAIN = 5   -- m: climb must gain this much ...
local AP_CLIMB_STALL_PT = 3     -- s: ... within this long, else HOLD the
                              -- current altitude and go to the TURN step
local AP_CLIMB_TIMEOUT = 180   -- s: dedicated climb-phase failsafe. The generic
                              -- AP_PHASE_TIMEOUT (45 s) is a TURN failsafe --
                              -- a rotation that never settles. It is far too
                              -- short for a climb: a gentle 5 m/s ascent from
                              -- the ground to a high ceiling legitimately needs
                              -- a minute or more, and cutting it off mid-ascent
                              -- handed the ship to the turn below its target and
                              -- skipped the ceiling probe entirely. The climb is
                              -- really bounded by the ceiling probe (physical
                              -- limit) and the stall failsafe (no progress);
                              -- this is only a last-resort backstop.
-- NOTE: there is no AP_CLIMB_KD_CUT any more. The velocity loop is PI (see
-- the climb block); a derivative fade was computed once and never applied.
-- OPERATING CEILING, DISCOVERED RATHER THAN ASSUMED.
-- The old 285 was a guess: it came from a wiki thrust curve for THIS ship at
-- 256 rpm and 12.8*sqrt(sails) airflow, but the ship gets shared, the props get
-- re-tuned, and other people's servers have different build limits. A hardcoded
-- number is wrong on all three counts.
--
-- So the ship finds its own ceiling. y250 is the MINIMUM FLIGHT HEIGHT, not a
-- ceiling: the plan starts there and only ever rises to a measured ceiling.
-- travel never happens below it, but it is not the stopping point either.
-- Above the floor the ship watches the one number that reveals the ceiling --
-- the prop speed the hover feedforward needs to hold station. While that is
-- UNDER AP_CEIL_LIFT there is thrust in hand, so it keeps climbing; when it
-- reaches AP_CEIL_LIFT, 2 of 15 are all that remain, and that altitude is the
-- ceiling. Those 2 units ARE the safety margin, which is why the target is
-- the discovered altitude itself and not something below it.
--
-- this is what makes one build work on any world. On a flat world the props
-- are already near max at y250, demand crosses 13 almost immediately, and the
-- ship cruises on its floor. Where the player has terrain and builds high the
-- air is denser up there, the props may still be turning at ~5 on reaching
-- y250, and the ship keeps going up -- potentially a very long way -- until
-- the props come back down to 13.
local AP_CEIL_FLOOR = 250  -- m: minimum flight height. The plan for an alt-less
                            -- waypoint starts here and rises only if the ship
                            -- proves it has the thrust to get higher.
local AP_CEIL_LIFT = 13    -- prop speed (of hover_max_speed) at which the climb
                            -- stops. 13 leaves 2 in hand: enough to level and
                            -- to absorb a gust without sinking.
local AP_CEIL_HARD = 450   -- m: absolute guard on the DISCOVERY CLIMB. It is
                            -- what the ship climbs toward while it is still
                            -- finding out where its ceiling is. It is never an
                            -- altitude goal: see ceilingTarget() below.
local AP_PHASE_TIMEOUT = 45 -- s failsafe per phase (no-drag ships coast forever)
local AP_HOVER_RANGE = 500  -- m: inside this (at enable or ANY time later,
                            -- incl. mid-cruise) the trip runs on HOVER
                            -- travel — tilt drive + yaw steer, no cruise
                            -- mode, no rear thrust at all
local AP_HOVER_SPEED = 20   -- m/s: speed cap for hover tilt travel
local AP_HOVER_ACCEL = 5    -- m/s^2: full-tilt accel/brake estimate for the
                            -- braking curve (v^2 <= 2*a*room)
local AP_HOVER_BAND = 2     -- m/s: hysteresis band (coast between actions)
local AP_APPROACH_TOL = 20  -- deg: bearing error the ship must be inside
                            -- before apHoverDrive is allowed to thrust
                            -- FORWARD. Thrusting across a large bearing is
                            -- what carried the ship past the point while it
                            -- was still turning; past the point the radial
                            -- distance STARTS GROWING, so the v^2 braking
                            -- profile asks for MORE thrust and the bearing
                            -- flips ~180 deg — that is the orbit, and it is
                            -- why phase 4 never arrived. Rotate first, close
                            -- second.

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

    -- One-shot: on the next update() (i.e. the first tick after the boot
    -- sequence powers on), re-capture the altitude goal from freshly read
    -- telemetry. See resyncAltitudeTarget().
    self.recapture_alt = false

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

--- Re-capture the altitude goal from the CURRENT measured altitude.
---
--- Why this is needed: setMode() stamps targets.altitude from state.altitude,
--- and powerOff() runs setMode(HOVER). While the splash/boot screens are up,
--- controlTick returns before flight:update(), so state is never re-read and
--- the sampled altitude FROZEN at the power-off value. Move the ship while the
--- splash is up and that stale goal is still in force on power-up: the first
--- real tick sees the live altitude against a goal from before the move and
--- flies the ship back to it. That is the reported "it tries to get back to the
--- altitude you were at when in the splash screen".
---
--- So the goal has to be re-stamped from fresh telemetry AFTER power returns,
--- not at the moment the boot button is pressed (state is still stale then).
--- os_main sets flight.recapture_alt = true in beginBoot(); update() consumes
--- the flag right after updateState(), so it happens exactly once, on the first
--- powered tick, using a real reading. The altitude PID is reset so no integral
--- wind-up from before the boot survives the re-stamp.
function Flight:resyncAltitudeTarget()
    self.targets.altitude = self.state.altitude
    local ap = self.pid and self.pid.altitude
    if ap then ap:reset() end
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

--- Rising-edge detect for the OFF button (engine relay left face input).
--- Returns true on the tick the button goes from released to pressed, so a
--- held button fires ONCE, not on all 50 subsequent ticks.
---
--- This lives here rather than inline in os_main for the same reason
--- pollShift does: the latch is stateful across ticks and is easy to write
--- backwards (assign the new level, then compare it -- which never fires) or
--- to drop entirely (which fires every tick while held). Both bugs are
--- invisible from the cockpit and trivial to assert here. os_main acts on the
--- returned edge.
function Flight:pollOff(value)
    local level = (value or 0) > 0 and 1 or 0
    local fired = (level == 1 and self.off_armed and self.off_level == 0)
    if level == 0 then
        self.off_armed = true
    end
    self.off_level = level
    return fired == true
end

-- The altitude the ship PLANS to cruise at, and the number shown as the goal.
--
-- This used to fall back to AP_CEIL_HARD, which made the 450 m guard a real
-- altitude goal: a waypoint with no `alt` was sent to y450 and the HUD showed
-- y450, because "aim high and see where the props fall short" had leaked out
-- of the probe and into the plan. On a world with thin air the props never do
-- fall short, so that goal could also sit at 450 indefinitely.
--
-- The plan now starts at AP_CEIL_FLOOR -- the minimum flight height -- and is
-- only ever RAISED by a ceiling the ship has actually measured. The discovery
-- climb is a separate question, answered by ceilingSeek() below.
function Flight:ceilingTarget()
    local learned = tonumber((self.config.limits or {}).ceiling)
    -- >= not >: a ceiling learned exactly ON the floor is a real answer. With
    -- > it would be discarded and the ship would re-probe every run.
    if learned and learned >= AP_CEIL_FLOOR then
        -- No margin to subtract: the probe already stopped 2 prop units short
        -- of max, so the discovered altitude is itself the safe one.
        return learned
    end
    return AP_CEIL_FLOOR
end

-- What to climb TOWARD while the ceiling is still unknown. The hard guard is
-- correct here and only here: it is a search bound, not a destination. Once
-- the probe measures a real ceiling this stops being used.
function Flight:ceilingSeek()
    local learned = tonumber((self.config.limits or {}).ceiling)
    if learned and learned >= AP_CEIL_FLOOR then return learned end
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

--- Signed angle from the ship's COURSE (its velocity vector) to the target, in
--- the same convention as apBearingError. Returns nil when the ship is too slow
--- for a course to mean anything, so the caller can fall back to nose heading.
---
--- A bank does not point the NOSE at the target: it tilts the lift vector,
--- which curves the ship's path -- its COURSE. The nose only follows the course
--- afterwards, via the fin weathervane, one step of lag later. Steering the bank
--- on the nose-heading error therefore closes the loop on a variable the
--- actuator does not control, with lag in front of it, and the loop diverges:
--- bank -> sideslip -> fin yaws the nose -> nose-heading error grows -> more
--- bank. That is the in-game "wiggle/wobble" and, with a large bank at low
--- thrust margin, the runaway dive. Course error puts the controlled variable
--- first, which is both correct and stable.
function Flight:apCourseError(dist, dx, dz)
    local v = self.state.velocity or {}
    local vl = math.sqrt((v.x or 0) ^ 2 + (v.z or 0) ^ 2)
    if vl < AP_COURSE_MIN_SPEED then return nil end
    local ux, uz = (v.x or 0) / vl, (v.z or 0) / vl
    local tl, tz = 0, 1
    if dist > 0.001 then tl, tz = dx / dist, dz / dist end
    local dot = ux * tl + uz * tz
    local cross = uz * tl - ux * tz
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

-- ADAPTIVE STABILISER GAIN. The attitude correction is a reduce-only prop
-- speed DIFFERENTIAL, so the room it has to work in is the headroom left above
-- hover. Near the ceiling hover is already ~14.3 of 15, and the old law scaled
-- corrections UP with kh (1/pressure) to restore angular authority. That hands
-- a big differential to a prop that has almost nothing to give: the
-- differential eats mean thrust, the hull drops, the altitude loop pushes back,
-- and the ship rocks. That is the high-altitude wiggle.
--
-- So scale authority by the headroom instead: untouched while the props have
-- room, tapering to a floor as hover eats into hmax.
--
-- The headroom MUST be keyed on the STATIC hover (base * kh), not on the
-- live `hover` feedforward. The live value carries the 1/den climb-rate term,
-- so keying on it ties attitude gain to climb rate: at y150 a climb at 8 m/s
-- reads hover=12.5 against 8.5 level, and tapers the gain to 0.6 while level
-- flight kept 0.92 -- a 0.65 multiplier on the climb's attitude correction.
-- That is exactly the moment invariance the vertical test pins (it failed at
-- ratio 0.652). Callers pass hover*den, which cancels the climb term and
-- leaves the altitude-only part.
--
-- This is a GAIN taper with a floor, NOT the hard lift-budget cap that was
-- tried and reverted -- that pinned mean thrust at 7 against a 13.5 hover
-- demand and collapsed pitch to 23 deg. AP_STAB_ADAPT_MIN deliberately keeps
-- real authority so a leaning hull is still caught.
local function stabAdapt(static_hover, hmax)
    local span = math.max(hmax or 0, 0.001)
    local headroom = clamp((span - (static_hover or 0)) / span, 0, 1)
    if headroom >= AP_STAB_ADAPT_KNEE then return 1 end
    return AP_STAB_ADAPT_MIN
        + (1 - AP_STAB_ADAPT_MIN) * (headroom / AP_STAB_ADAPT_KNEE)
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
    -- Two different altitudes, deliberately:
    --   ceiling -- the PLAN: the altitude we intend to cruise at. A learned
    --               one if we have measured it, otherwise the minimum flight
    --               height. This is what the HUD shows as the goal.
    --   seek    -- the DISCOVERY CLIMB: what to climb toward while the real
    --               ceiling is still unknown. The hard guard belongs here and
    --               only here, so the probe has room to work without the
    --               guard ever being displayed or held as a destination.
    local ceiling = self:ceilingTarget()
    local seek = self:ceilingSeek()
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
    --
    -- alt_less records WHICH of those two we are doing, because only the
    -- alt-less case may let the discovery raise the goal later; an explicit
    -- waypoint altitude is honoured and never overridden.
    local goal_alt = tonumber(wp.alt)
    local alt_less = (not goal_alt) or goal_alt ~= goal_alt
    if alt_less then
        goal_alt = ceiling
    else
        -- An explicit altitude is the operator's decision, so it is guarded
        -- against absurd values but NOT clamped down to the operating ceiling:
        -- asking for y400 in a world that allows it must still mean y400.
        goal_alt = clamp(goal_alt, 0, AP_CEIL_HARD)
    end

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
        climb_alt0 = alt_now,      -- for the stall failsafe
        climb_vi = 0,              -- leaky integral of climb-rate error
        stop_hold = 0,    -- s the arrival condition has held continuously
        ceil = seek,
        alt_less = alt_less,
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
function Flight:apHoverDrive(dist, err)
    local v = self.state.velocity or {}
    local f = self.state.forward or {}
    local fwd_speed = (v.x or 0) * (f.x or 0) + (v.z or 0) * (f.z or 0)
    local step = (self.config.limits or {}).hover_speed or 2

    -- ROTATE FIRST, CLOSE SECOND. What says whether forward thrust points at
    -- the waypoint is the BEARING, not the distance: `dist` is radial, so a
    -- ship that has already passed the point and is receding has exactly the
    -- same `room` as one still approaching, and the v^2 profile below then
    -- asks for MORE thrust — driving it further past, where the bearing flips
    -- ~180 deg, `correct` brakes to a crawl, and it orbits the point. That is
    -- the reported overshoot-and-circle, and it is why phase 4 never arrived:
    -- `align` needs dist <= 4 AND speed <= 0.6 in the same tick, which an
    -- orbiting ship never satisfies. So forward thrust is only permitted once
    -- the bearing is roughly on the point; outside that, brake the run-on once
    -- and rotate in place. Coasting, not reversing — a sustained reverse tilt
    -- would walk the ship backwards away from the point.
    if err and math.abs(err) > AP_APPROACH_TOL then
        if fwd_speed > AP_STOP_SPEED then
            self.targets.move_forward = -step -- kill the run-on, once
        else
            self.targets.move_forward = 0     -- coast to a stop and rotate
        end
        return
    end

    local room = math.max(dist - AP_ARRIVE_R, 0)
    local want = math.min(AP_HOVER_SPEED, math.sqrt(2 * AP_HOVER_ACCEL * room))
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
    -- Re-run the initial rotation from a travel leg. Before this the phase
    -- machine had NO cruise/correct -> aim edge: `aim` was reachable only from
    -- `idle`, so once a run handed over to phase 3 it could never re-aim and
    -- a large heading error could only be chipped at by `correct`, which is a
    -- brake-and-hold rather than a re-aim. That is the "once it's in phase 3
    -- it can't go back to phase 2" report.
    --
    -- The climb is deliberately skipped: `needs_climb` is false and the step
    -- goes straight to "turn", because the ship is already holding its cruise
    -- altitude and re-running the climb would drop it out of the sky. MODE_HOVER
    -- is required because the yaw steer is tilt-driven and cruise zeroes prop
    -- tilt, so a rotation is not possible in cruise mode.
    local function recourseToAim()
        ap.phase = "aim"
        ap.pt = 0
        ap.needs_climb = false
        ap.step = "turn"
        ap.climb_demand = nil
        ap.climb_brake = 0
        ap.climb_rr = 0
        ap.stop_hold = 0
        ap.brake_reverse = false
        self.targets.speed = 0
        if self.mode ~= Flight.MODE_HOVER then self:setMode(Flight.MODE_HOVER) end
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
        self:apHoverDrive(dist, err)
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
            -- Still has thrust in hand, so it is still climbing to find out
            -- where the ceiling is. Keep seeking toward the hard guard: that is
            -- the search, and the guard is never shown as the goal.
            ap.ceil = self:ceilingSeek()
        else
            -- Measured: this altitude IS the ceiling (2 prop units still in
            -- hand, so no margin is subtracted). Adopt it as the operative
            -- ceiling, and -- for an alt-less waypoint only -- as the plan, so
            -- the ship cruises where it discovered it can fly. An explicit
            -- waypoint altitude is the operator's decision and is left alone.
            ap.ceil = self:ceilingTarget()
            if ap.alt_less then
                ap.goal_alt = ap.ceil
                if ap.alt and ap.alt > ap.ceil then ap.alt = ap.ceil end
            elseif ap.goal_alt > ap.ceil then
                -- An explicit altitude ABOVE what the ship can actually reach
                -- (9999, or 400 in a thin world) converges on the measured
                -- ceiling now that we know it. An explicit altitude at or
                -- below it is untouched, so "land at y90" still means y90.
                ap.goal_alt = ap.ceil
            end
        end

        if ap.step ~= "turn" then
            -- STEP 1 — CLIMB toward ap.goal_alt (the waypoint's altitude, or
            -- the discovered ceiling). The target is FIXED: it does not move
            -- while the ship flies to it, so the law closes the loop on
            -- measured climb rate instead of chasing a receding goal.
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
                -- === CLIMB: fixed target, constant-rate transit, braked arrival ===
                -- Which altitude the climb is chasing depends on which of the
                -- two questions this waypoint asked:
                --   alt-less  -> chase ap.ceil, the DISCOVERY climb. While the
                --                 ceiling is unknown that is the hard guard, so
                --                 the ship keeps rising until the props come
                --                 back down to 13; the moment a ceiling is
                --                 measured, ap.ceil becomes it and the climb
                --                 settles there. This is the only path on
                --                 which the 450 guard is ever a target.
                --   explicit  -> chase ap.goal_alt, the operator's altitude,
                --                 untouched by any of the above.
                local target = ap.alt_less and ap.ceil or ap.goal_alt
                local rate = state.climb_rate or 0
                local remain = target - (state.altitude or 0)
                self:apClimbVertical(dt, target, hmax)
                self.targets.yaw_cmd = clamp(self.pilot_yaw or 0, -1, 1) -- Q/E only

                -- (4) ARRIVAL. The height is validated as a DISTANCE (see
                --     AP_CLIMB_VALIDATE): inside that band the climb step is
                --     done, and the altitude position PID finishes the last
                --     blocks while the turn is already rotating. No rate gate
                --     here on purpose -- requiring the ship to be stopped
                --     first is what produced the multi-second crawl.
                local arrived = remain <= AP_CLIMB_VALIDATE
                ap.stop_hold = arrived
                    and ((ap.stop_hold or 0) + dt) or 0

                local stalled = ap.pt >= AP_CLIMB_STALL_PT
                    and (state.altitude - (ap.climb_alt0 or 0)) < AP_CLIMB_STALL_GAIN
                -- Hand the collective over SMOOTHLY. The climb law's
                -- collective is slew-limited (AP_CLIMB_SLEW_*); the altitude
                -- PID that takes over is not, and it is not the only
                -- discontinuity -- the climb flies wings-level while the turn
                -- yaws with tilted props, so the SAME logical demand is a
                -- different prop speed once mean_tilt_lift < 1. Validating the
                -- height at AP_CLIMB_VALIDATE means the handover happens while
                -- the ship is still doing ~5 m/s, and stepping straight across
                -- measured a 4.1 prop-unit slam in one tick: exactly the lurch
                -- the slew limiter exists to prevent. So keep releasing the
                -- last climb demand into the PID's first command, at the slow
                -- release rate, for a short window.
                if (ap.stop_hold >= AP_CLIMB_SETTLE_HOLD)
                    or stalled or ap.pt >= AP_CLIMB_TIMEOUT then
                    -- The height is validated, so the phase advances -- but the
                    -- COLLECTIVE does not change hands yet. The climb law keeps
                    -- flying the last blocks (ap.climb_brake) while the turn
                    -- rotates, and only gives the props to the altitude PID
                    -- once the ship has actually settled on the goal or the
                    -- grace window runs out. Slewing the handover keeps the
                    -- last limited demand and the first PID command continuous.
                    ap.climb_brake = AP_CLIMB_BRAKE_GRACE
                    ap.slew_prev = ap.climb_demand
                    ap.slew_ttl = AP_CLIMB_HANDOVER_SLEW
                end

                if stalled then
                    -- STALLED CLIMB (gained < AP_CLIMB_STALL_GAIN m in
                    -- AP_CLIMB_STALL_PT s): hold here -- freeze the goal at the
                    -- current altitude and move on to the heading phase instead
                    -- of waiting out the phase timeout.
                    ap.alt = state.altitude -- hold THIS during the turn (once!)
                    ap.step = "turn"
                    ap.climb_demand = nil -- props back to the altitude PID
                    ap.pt = 0 -- the rotation gets its own timeout window
                elseif (ap.stop_hold >= AP_CLIMB_SETTLE_HOLD)
                    or ap.pt >= AP_CLIMB_TIMEOUT then
                    -- Hold the TARGET altitude, not wherever the ship happened
                    -- to be when the climb gave up: capturing state.altitude
                    -- froze the cruise at the overshoot peak and the ship then
                    -- sank through the turn. The altitude PID converges the
                    -- remainder while the turn is already running.
                    ap.alt = target
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
            -- Keep the climb's braked arrival running through the rotation
            -- (see Flight:apClimbVertical). Handing the collective to the
            -- altitude PID at 5 m/s is what pushed the ship 3.47 blocks past
            -- the goal; letting the brake finish first costs nothing, because
            -- the rotation is using the yaw axis, not the collective.
            local braking_live = (ap.climb_brake or 0) > 0
            if braking_live then
                local btarget = ap.alt_less and ap.ceil or ap.goal_alt
                local bremain = btarget - (state.altitude or 0)
                local brate = state.climb_rate or 0
                if bremain <= AP_CLIMB_TOL and math.abs(brate) <= AP_CLIMB_STILL then
                    ap.climb_brake = 0        -- settled on the goal: let the PID have it
                    ap.climb_demand = nil
                else
                    ap.climb_demand = self:apClimbVertical(dt, btarget, hmax)
                    ap.climb_brake = ap.climb_brake - dt
                    if ap.climb_brake <= 0 then
                        ap.climb_demand = nil
                    end
                end
            end
            if (ap.climb_demand == nil) then
                self.targets.altitude = ap.alt
            end
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
        -- Steering stays with the bank here, at every altitude, including the
        -- ceiling. An earlier revision gated the bank on spare hover headroom
        -- and handed the bearing back to the hover turn when the margin ran
        -- out. That was WRONG and it is exactly what "cruise still uses hover
        -- yaw control" was: the gate keyed on (hmax - hover), which is 0.0 at
        -- the ceiling BY CONSTRUCTION, so it switched heading control off
        -- precisely where the ship spends the whole leg and dropped the run
        -- back onto hover tilt-yaw for 83% of the cruise (17% in MODE_CRUISE).
        --
        -- It rested on a fabricated measurement. The claim that 8 deg of bank
        -- yawed the hull at 44 deg/s came from this test plant, which has NO
        -- bank->yaw coupling at all: cruise zeroes prop tilt, so fz = 0 for
        -- every prop and the yaw couple YAW_SIGN*x*fz is identically zero. A
        -- pure roll differential held for 100 ticks moves yaw_rate by 0.000
        -- deg/s. The figure was read off a correlation in a diverging trace
        -- and reported as a cause, and the "unrecoverable limit cycle" it
        -- described was the gate itself, not the bank.
        --
        -- A bank genuinely does cost mean thrust (the differential is
        -- reduce-only) and near the ceiling hover is ~14.3 of 15, so that cost
        -- is real -- but it is paid for by AP_BANK_ALT_FADE (fade the bank as
        -- altitude error grows, so a recovery climb is flown level) and by
        -- stabAdapt's taper, neither of which switches the heading controller
        -- off. Slowing the rear ramp does not help; the ceiling is not the
        -- limiter.
        if math.abs(err) > AP_RECOURSE then
            -- Too far off to bank back: re-aim instead. Checked BEFORE the
            -- off-course edge below, because at this error `correct` would
            -- happily sit braking to a hover forever against AP_PHASE_TIMEOUT
            -- and then resume cruise still 60 deg wrong.
            recourseToAim()
        elseif math.abs(err) > AP_OFFCOURSE then
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
        -- NOTE: a revision removed this brake entirely (hold speed, never slow
        -- to a crawl) on the theory that a bank needs airspeed, so braking to
        -- correct cost the only steering authority available. It was reverted:
        -- braking to ~1-2 m/s is what starves the fin weathervane (the plant
        -- only couples yaw above 0.5 m/s of horizontal speed), and removing the
        -- brake let the bearing error integrate away -- 26 correct->cruise
        -- churns and a worse HOVER->CRUISE handover. The "banking while
        -- stationary" harm is addressed at the bank command instead
        -- (AP_BANK_MIN_SPEED), which is where it actually happens and which
        -- leaves the throttle logic alone.
        if slow then
            self.targets.speed = 1 -- crawl so we can still turn
        else
            self.targets.speed = 0 -- level 0 = brake wire
            -- reverse face only if the hardware has it; apRear with a forward
            -- level would otherwise ACCELERATE us on ships lacking it
            ap.brake_reverse = self:hasFeature("rear_reverse")
        end
        if math.abs(err) > AP_RECOURSE then
            -- Banked correction is hopeless at this error; re-aim.
            recourseToAim()
        elseif slow and math.abs(err) <= AP_CORRECT_TOL then
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
    -- First tick after boot: re-stamp the altitude goal from the telemetry we
    -- just read, NOT from whatever setMode captured while the splash was up
    -- (see resyncAltitudeTarget). Must sit after updateState() and before any
    -- mode function reads targets.altitude.
    if self.recapture_alt then
        self.recapture_alt = false
        self:resyncAltitudeTarget()
    end
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
    --
    -- ...and then stabAdapt() scales the whole thing back down as hover eats
    -- the prop-speed headroom. kh/den alone over-corrects up high: it inflates
    -- the differential on a prop that cannot spare it, which is what rings the
    -- hull through a high climb. adapt = 1 until there is less than half the
    -- prop range in hand, then tapers to AP_STAB_ADAPT_MIN.
    local scale = kh / den * stabAdapt(hover * den, hmax)
    -- The RATE term has to survive the deadband, so it is clamped on its own,
    -- not inside the attitude cap.
    --
    -- The deadband exists to stop the P term from chasing a hull that is
    -- already where it was told to be. While the rate term sat inside the same
    -- clamp it inherited that behaviour, and `rollCap`/`stabCap` both return
    -- ZERO inside the deadband -- so the instant the attitude came back within
    -- 2 deg the stabilizer multiplied the *rate* term to zero as well. That is
    -- exactly backwards: the deadband is an attitude gate, and the one moment
    -- the hull absolutely needs damping is the moment it is passing back
    -- through level carrying the angular momentum the correction just gave it.
    -- With the rate term dead the hull coasts straight through the deadband
    -- and out the far side, which is the "PID doesn't dampen the momentum it
    -- gave to correct the roll, so it wiggles again" report.
    --
    -- Measured: from a 6 deg roll the ship was at roll_rate = -8.7 deg/s with
    -- the roll correction at exactly 0.000 for three consecutive ticks.
    --
    -- So: attitude cap the P term only, and let the rate term run on its own
    -- authority (AP_STAB_RATE) so momentum is always opposed. AP_STAB_RATE is
    -- deliberately small -- it only has to bleed off the momentum the
    -- proportional term is generating, not to steer the ship.
    local pitch_corr = clamp(pitch_out * scale, -pitch_cap * scale, pitch_cap * scale)
        + clamp(-AP_STAB_RATE_K * (state.pitch_rate or 0) * scale,
            -AP_STAB_RATE * scale, AP_STAB_RATE * scale)
    local roll_corr = clamp(roll_out * scale, -roll_cap * scale, roll_cap * scale)
        + clamp(-AP_STAB_RATE_K * (state.roll_rate or 0) * scale,
            -AP_STAB_RATE * scale, AP_STAB_RATE * scale)

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
    -- ...but the pulse train must never gate the RATE term either, for the
    -- same reason the deadband cannot: duty 0 inside the deadband would blank
    -- the whole correction and the hull would coast through level unopposed.
    -- Re-add the rate term after the duty gate so momentum damping is
    -- continuous while the proportional correction stays time-quantised.
    if self.stab_phase >= pitch_duty then
        pitch_corr = clamp(-AP_STAB_RATE_K * (state.pitch_rate or 0) * scale,
            -AP_STAB_RATE * scale, AP_STAB_RATE * scale)
    end
    if self.stab_phase >= roll_duty then
        roll_corr = clamp(-AP_STAB_RATE_K * (state.roll_rate or 0) * scale,
            -AP_STAB_RATE * scale, AP_STAB_RATE * scale)
    end

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
    -- Climb->turn handover ramp: bound the rate of change of the collective
    -- for a short window after the climb law hands over, so the first command
    -- from the altitude PID ramps in from the last slew-limited climb demand
    -- instead of stepping. See AP_CLIMB_HANDOVER_SLEW.
    if self.ap and (self.ap.slew_ttl or 0) > 0 then
        local rlim = AP_CLIMB_SLEW_RELEASE * dt
        local sprev = self.ap.slew_prev
        if sprev ~= nil then
            base_speed = clamp(base_speed, sprev - rlim, sprev + rlim)
        end
        self.ap.slew_prev = base_speed
        self.ap.slew_ttl = self.ap.slew_ttl - dt
    end

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

-- The climb law's VERTICAL channel, factored out so that the turn step can
-- keep flying it after the phase has advanced.
--
-- Sequencing and vertical control are different questions and were previously
-- welded together: the climb step ended when the height was validated, and it
-- also handed the collective back to the altitude PID at that same instant.
-- Validating the height early (AP_CLIMB_VALIDATE) therefore also handed the
-- collective over early, while the ship was still doing ~5 m/s -- and the
-- altitude position PID is tuned for station-keeping, not for arresting an
-- approach. Its derivative term sheds only ~0.84 prop units at 5 m/s, needing
-- 8.1 m of run-out when 7.6 m existed, so the ship coasted 3.47 blocks past the
-- goal (2.00 at HEAD). Keeping this law running until the ship is genuinely
-- settled overlaps the braking with the rotation instead of queueing it, which
-- is the whole point of validating the height early, and preserves the braked
-- arrival -- and the "never sail over" property with it.
--
-- `target` is the altitude being chased; sets ap.climb_demand and
-- self.targets.altitude, and returns the commanded collective.
function Flight:apClimbVertical(dt, target, hmax)
    local ap = self.ap
    local state = self.state
    local limits = self.config.limits or {}
    local hover = hoverFF(limits, state)
    local rate = state.climb_rate or 0
    local remain = target - (state.altitude or 0)

    -- (1) VELOCITY SETPOINT.
    --     Transit: a single constant climb rate -> linear altitude
    --     gain, steady moderate collective. Braking: the fastest
    --     rate we could still stop from in `remain`, so the profile
    --     arrives at the goal with ~zero speed. At/above the goal
    --     the setpoint is pinned at 0 and can never go positive:
    --     the ship coasts to a stop ON the goal rather than
    --     carrying momentum through it.
    local vdes
    if remain <= 0 then
        vdes = 0
    else
        local v_brake = math.sqrt(2 * AP_CLIMB_BRAKE * remain)
        vdes = math.min(AP_CLIMB_V, v_brake, AP_CLIMB_VLIM)
    end

    -- (2) VELOCITY PI on MEASURED climb rate. I is a leaky
    --     integrator: it trims the steady-state offset but leaks
    --     whenever the velocity error is small, so it cannot wind
    --     up during the long cruise at rate and then fire on
    --     arrival.
    --
    --     There is deliberately NO D term here. The earlier draft
    --     computed a `kd` that faded over the last AP_CLIMB_KD_CUT
    --     metres, but it was never multiplied into v_out -- the
    --     loop has always been PI. Rather than keep a constant and
    --     a fade that do nothing, the dead code is gone; the final
    --     metres are governed by the v^2 brake profile in (1),
    --     which is what actually settles the arrival. A D term on
    --     v_err would also fight that profile and re-introduce the
    --     last-metre bounce the brake curve exists to prevent.
    local v_err = vdes - rate
    ap.climb_vi = (ap.climb_vi or 0) + v_err * dt
    local leak = math.max(0, 1 - dt / 3.0)
    ap.climb_vi = ap.climb_vi * leak
    local v_out = AP_CLIMB_KP * v_err + AP_CLIMB_KI * ap.climb_vi

    -- (3) COLLECTIVE = feedforward + velocity PID, then the
    --     asymmetric slew limit. The feedforward keeps the law
    --     meaning the same thing at any height; the PID supplies
    --     only the extra (or reduced) thrust that produces the
    --     commanded vertical acceleration.
    local demand = clamp(hover + v_out, 0, hmax)
    if remain <= 0 then
        -- AT OR ABOVE THE GOAL: cap at hover. The ship may coast
        -- and settle down onto the target, but it is never given
        -- more lift than holding station, so it cannot be pushed
        -- back over the goal. This is the "never go over" rule.
        if demand > hover then demand = hover end
    end
    local prev = ap.climb_demand
    if prev ~= nil then
        local rate_lim = (demand > prev) and AP_CLIMB_SLEW_ATTACK
            or AP_CLIMB_SLEW_RELEASE
        local max_step = rate_lim * dt
        demand = clamp(demand, prev - max_step, prev + max_step)
    end
    ap.climb_demand = clamp(demand, 0, hmax)
    self.targets.altitude = target
    self.targets.yaw_cmd = clamp(self.pilot_yaw or 0, -1, 1) -- Q/E only

    ap.climb_demand = clamp(demand, 0, hmax)
    return ap.climb_demand
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

    -- Climb->turn handover ramp: bound the rate of change of the collective
    -- for a short window after the climb law hands over, so the first command
    -- from the altitude PID ramps in from the last slew-limited climb demand
    -- instead of stepping. See AP_CLIMB_HANDOVER_SLEW.
    if self.ap and (self.ap.slew_ttl or 0) > 0 then
        local rlim = AP_CLIMB_SLEW_RELEASE * dt
        local sprev = self.ap.slew_prev
        if sprev ~= nil then
            base_speed = clamp(base_speed, sprev - rlim, sprev + rlim)
        end
        self.ap.slew_prev = base_speed
        self.ap.slew_ttl = self.ap.slew_ttl - dt
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
        -- Steer on COURSE error, not nose-heading error (apCourseError).
        -- Falls back to the heading error when the ship is too slow for a
        -- course to mean anything -- where the bank is gated off anyway.
        local apos = self.ap
        local ppos = self.state.position or { x = 0, y = 0, z = 0 }
        local cdx = apos.x - (ppos.x or 0)
        local cdz = apos.z - (ppos.z or 0)
        local cdist = math.sqrt(cdx * cdx + cdz * cdz)
        local steer_err = self:apCourseError(cdist, cdx, cdz)
        if steer_err == nil then steer_err = err end
        -- Rate lead: while the bank yaws the ship onto the bearing, subtract
        -- the ongoing yaw rate from the error so the command starts easing
        -- BEFORE the bearing is reached — no overshoot / coast-through.
        local eff = steer_err - AP_BANK_RATE_LEAD * (state.yaw_rate or 0)
        local roll_target = 0
        if math.abs(eff) > AP_BANK_DEAD then
            roll_target = clamp(AP_BANK_KP * eff, -AP_BANK_MAX, AP_BANK_MAX) * AP_BANK_SIGN
        end
        -- AIRSPEED GATE. A bank yaws a ship by tilting the lift vector, so it
        -- needs the ship to be moving. Below AP_BANK_MIN_SPEED it produces NO
        -- yaw at all while still costing mean thrust and rolling the hull —
        -- strictly a loss. This is the "tries to roll and pitch to yaw while
        -- stationary" report: in-game the bank is not what yaws the ship, so a
        -- low-speed ship under bank just leans, loses vertical lift and
        -- wanders. Note this plant has no bank->yaw coupling at all (cruise
        -- zeroes tilt, so fz = 0 and the yaw couple is identically zero), so
        -- this gate is NOT testable here — it is a physical precondition,
        -- pinned by asserting the command goes to zero, not by measuring yaw.
        local bank_speed = state.speed or 0
        local bank_frac = clamp((bank_speed - AP_BANK_MIN_SPEED * 0.5)
            / (AP_BANK_MIN_SPEED * 0.5), 0, 1)
        roll_target = roll_target * bank_frac
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
        -- RATE FADE, on top of the position fade above. The position term
        -- alone does not damp, it closes: bank -> lift vector tilts -> vertical
        -- lift drops -> the ship sinks -> |alt_err| grows -> bank fades -> the
        -- ship climbs -> |alt_err| shrinks -> bank returns -> it sinks again.
        -- That is a sustained limit cycle, and the reported -3..-30 m band
        -- with a period of several seconds is its signature. It runs away
        -- into the deep dive when the bank is large at low thrust margin,
        -- because then the sink per degree of bank exceeds what the props can
        -- win back. Keying an additional term to |climb_rate| breaks the loop
        -- in the tick the sink begins instead of after the whole excursion has
        -- developed, and it is a strictly larger fade than the position term
        -- whenever the ship is actually moving vertically.
        local rate_err = math.abs(state.climb_rate or 0)
        if rate_err > 1e-6 then
            roll_target = roll_target * (1 - clamp(rate_err / AP_BANK_RATE_FADE, 0, 1))
        end
        -- No headroom gate on the bank itself. A previous revision faded the
        -- bank out as (hmax - hover) shrank, on the theory that a bank is paid
        -- for out of the mean thrust so an unsustained bank is positive
        -- feedback. The theory was untested -- this plant has no bank->yaw
        -- coupling (cruise zeroes tilt, so fz = 0 and the yaw couple is
        -- identically zero), so the "8 deg of bank = 44 deg/s of yaw" figure
        -- that motivated it was fabricated. In the real game the gate only
        -- switched the heading controller OFF at the ceiling and dropped the
        -- run back onto hover tilt-yaw, which is worse: cruise then had no
        -- heading control at all at altitude. The bank costs mean thrust, and
        -- that is what AP_BANK_ALT_FADE above and stabAdapt's taper already
        -- pay for. Leave the bank command alone.
        local roll_out = self.pid.roll:update(roll_target, state.roll, dt)
        local pitch_out = self.pid.pitch:update(0, state.pitch, dt)
        -- Same kh/den authority scheduling as updateHover (pressure AND
        -- climb-rate cut the prop DIFS but not the hull disturbance);
        -- scale=1 at sea level in level flight -> cruise feel unchanged.
        -- stabAdapt() then tapers it back as hover eats the headroom, so the
        -- differential shrinks the faster the props must spin (see stabAdapt).
        local scale = kh / den * stabAdapt(hover * den, hmax)
        -- Same split as updateHover: the proportional term is attitude-capped,
        -- the RATE term gets its own authority so it is never disarmed. Cruise
        -- had no deadband so nothing zeroed it outright, but it ran 0.15 while
        -- hover ran 0.25 -- the stabilised hull was being fed back at less than
        -- 2/3 the strength, which is what "cruise doesn't dampen it" looked
        -- like. Shared gain now, and the rate term keeps full cruise authority
        -- (AP_STAB_OUT) because unlike hover it has no deadband to protect.
        local roll_corr = clamp(roll_out * scale,
                -AP_STAB_OUT * scale, AP_STAB_OUT * scale)
            + clamp(-AP_STAB_RATE_K * (state.roll_rate or 0) * scale,
                -AP_STAB_OUT * scale, AP_STAB_OUT * scale)
        local pitch_corr = clamp(pitch_out * scale,
                -AP_STAB_OUT * scale, AP_STAB_OUT * scale)
            + clamp(-AP_STAB_RATE_K * (state.pitch_rate or 0) * scale,
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
            -- step matters as well as phase: "aim" covers TWO legs of the
            -- sequence (climb, then turn) and the HUD's phase readout needs to
            -- tell them apart.
            step = self.ap.step,
            dist = self.ap.dist,
            progress = self.ap.progress,
            eta = self.ap.eta,
            speed = self.ap.speed,
            paused = self.ap.paused,
            -- signed bearing error to the waypoint (deg). The HUD shows this
            -- because a bank-to-turn loop that is not tracking the bearing is
            -- the first thing worth looking at when a cruise leg misbehaves.
            err = self.ap.err,
            heading = self.ap.heading,
            alt = self.ap.alt,
            -- The PLAN: the altitude the run intends to cruise at. Exposed
            -- because the vertical law's targets.altitude is fed from the climb
            -- COMMAND, which for an alt-less waypoint is the discovery climb
            -- toward the 450 m guard until a ceiling is measured. Showing that
            -- to the pilot as "target altitude" is the y450 readout this
            -- replaces; the HUD shows goal_alt instead.
            goal_alt = self.ap.goal_alt,
            -- The operative ceiling: the guard while still searching, the
            -- measured altitude once known. Diagnostic only.
            ceil = self.ap.ceil,
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
