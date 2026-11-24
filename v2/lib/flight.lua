-- v2 flight manager: phases, pilot input, landing, gear, e-stop, unflip.
-- Each tick builds one "command" (what the ship should do) from the pilot,
-- the autopilot or the landing sequence, then runs it through ctl.lua.
--
-- Phases:  parked   on the ground, props at creep
--          flying   normal flight (HOVER or CRUISE mode)
--          landing  controlled descent + position hold until touchdown
--          unflip   upside-down recovery
--          estop    everything cut, latched until SPACE or the button
local U = require("util")
local Ctl = require("ctl")
local Est = require("est")

local Flight = {}
Flight.__index = Flight

local REPEAT = 0.4 -- s before a held SPACE/CTRL starts moving the target

function Flight.new(tune, hw, ship)
    local self = setmetatable({}, Flight)
    self.t, self.hw, self.shipcfg = tune, hw, ship
    self.ctl = Ctl.new(tune)
    self.est = Est.new(tune)
    self.levels = {}
    self.phase = "parked"
    self.mode = "hover"
    self.alt_target = 0
    self.heading_target = 0
    self.rear_target, self.rear = 0, 0
    self.gear_down = false
    self.gear_settle = 0
    self.ground_ticks = 0
    self.keys, self.prev = {}, {}
    self.held = {}
    self.msg = nil
    self.events = {}
    self.out = { FL = 0, FR = 0, RL = 0, RR = 0, tilt = { FL = 0, FR = 0, RL = 0, RR = 0 }, rear = 0, rear_rev = false }
    self.inv_t = 0
    self.stats = { max_alt = 0, dist = 0 }
    return self
end

function Flight:notify(text)
    self.msg = { text = text, t = os.clock() }
    -- debug: every pilot message goes to the log too (repeats once a 5 s)
    local now = os.clock()
    if text ~= self.last_note or now - (self.last_note_t or -99) > 5 then
        U.log("message: %s", text)
        self.last_note, self.last_note_t = text, now
    end
end

function Flight:feature(n) return self.hw.feature(n) end

local function pressed(self, k) return (self.keys[k] or 0) > 0 end
local function edge(self, k) return pressed(self, k) and not ((self.prev[k] or 0) > 0) end

-- Height above ground from the gear sensor (whole blocks, low end), nil
-- when the sensor sees nothing.
function Flight:groundHeight()
    local prox = self.prox or 0
    if prox <= 0 then return nil end
    local max = (self.shipcfg.proximity or {}).max_blocks or 15
    return math.max(max - prox - 1, 0)
end

-- Fastest allowed sink at the current height (braking curve onto the ground).
function Flight:sinkLimit()
    local l = self.t.landing
    local h = self:groundHeight()
    local cap = self.t.vertical.sink_max
    if h == nil then return cap end
    return U.clamp(U.brakeSpeed(h, l.decel), l.touch_rate, cap)
end

-- ---------------------------------------------------------------- phases

function Flight:holdHere()
    local s = self.est.s
    self.alt_target = s.alt or 0
    self.heading_target = s.heading or 0
    self.hold_pt = nil
end

function Flight:setMode(mode)
    if mode == self.mode then return end
    if mode == "cruise" and not self:feature("cruise_mode") then return end
    self.mode = mode
    self.ctl:softReset()
    self.heading_target = self.est.s.heading or self.heading_target
    if mode == "cruise" then self.rear_target = math.max(self.rear_target, 1)
    else self.rear_target, self.rear = 0, 0 end
end

function Flight:toggleMode()
    if self.ap then return false, "AUTOPILOT OWNS THE MODE" end
    if self.phase ~= "flying" then return false, "NOT FLYING" end
    self:setMode(self.mode == "hover" and "cruise" or "hover")
    return true, self.mode:upper()
end

function Flight:takeoff()
    if self.phase ~= "parked" then return end
    self.phase = "flying"
    self:holdHere()
    self.alt_target = self.est.s.alt + 6
    self.ctl:softReset()
    self:notify("TAKEOFF")
    -- check which way pitch/roll corrections really move the hull, once
    if not ((self.ctl.roll_known or 0) > 0 and (self.ctl.pitch_known or 0) > 0) then
        self.calib = { stage = "wait", t = 0, alt0 = self.est.s.alt }
    end
end

function Flight:setGear(down)
    if not self:feature("gear") then return end
    if down and not self.gear_down then self.gear_settle = 20 end
    self.gear_down = down
end

function Flight:setEstop(on)
    if on then
        if self.ap then self.ap = nil end
        self.phase = "estop"
        self.land = nil
        self:notify("E-STOP")
    elseif self.phase == "estop" then
        self.phase = "flying"
        self:holdHere()
        self.ctl:softReset()
        self:notify("E-STOP CLEARED")
    end
end

-- opts: { x, z, heading, shutdown = bool, from_ap = bool }
function Flight:beginLanding(opts)
    if self.phase == "parked" then return false, "ALREADY LANDED" end
    if self.phase == "estop" then return false, "E-STOP ACTIVE" end
    opts = opts or {}
    local s = self.est.s
    self:setMode("hover")
    self:setGear(true)
    self.phase = "landing"
    self.land = {
        x = opts.x or s.x, z = opts.z or s.z,
        heading = opts.heading or s.heading,
        shutdown = opts.shutdown, from_ap = opts.from_ap,
        rate = math.max(-s.vs, 0), stall = 0, ticks = 0,
    }
    self:notify(opts.shutdown and "LANDING, THEN POWER OFF" or "AUTO-LAND")
    return true
end

function Flight:cancelLanding(why)
    if self.phase ~= "landing" then return end
    self.phase = "flying"
    self.land = nil
    self:holdHere()
    self:notify(why or "LANDING CANCELLED")
end

function Flight:touchdown()
    local l = self.land
    self.phase = "parked"
    self.land = nil
    self.ctl:softReset()
    self.alt_target = self.est.s.alt
    self.parked_t = os.clock()
    self:notify("LANDED")
    local ap = self.ap
    if ap then ap.done = "ARRIVED" self.ap = nil end
    self.events[#self.events + 1] = { kind = "landed", shutdown = l and l.shutdown,
        ap = ap and ap.name }
end

-- ---------------------------------------------------------------- inputs

function Flight:pilot(dt)
    local s, t = self.est.s, self.t
    local cmd = { alt = self.alt_target }

    -- altitude: tap = step, hold = smooth climb/descent
    local step = (self.shipcfg.limits or {}).alt_step or 5
    for key, dir in pairs({ SPACE = 1, CTRL = -1 }) do
        if pressed(self, key) then
            self.held[key] = (self.held[key] or 0) + dt
            if edge(self, key) then
                self.alt_target = self.alt_target + dir * step
            elseif self.held[key] > REPEAT then
                self.alt_target = self.alt_target + dir * 4 * dt
            end
        else
            self.held[key] = nil
        end
    end
    -- the target never runs far from the ship (no wind-up when held)
    self.alt_target = U.clamp(self.alt_target, s.alt - 15, s.alt + 15)
    self.alt_target = math.min(self.alt_target, t.ship.max_altitude)
    cmd.alt = self.alt_target

    local yaw = (pressed(self, "E") and 1 or 0) - (pressed(self, "Q") and 1 or 0)
    local fwd = (pressed(self, "W") and 1 or 0) - (pressed(self, "S") and 1 or 0)

    if self.mode == "hover" then
        -- Hands off = stay level and stop moving fore/aft, nothing more. The
        -- ship cannot strafe (rolling to slide makes the tail fin turn it,
        -- which then needs correcting: a loop), so there is no position or
        -- heading hold. Q/E turn with the tilts; let go and the rotation is
        -- braked to a stop, then the tilts are left alone.
        if yaw ~= 0 then cmd.yaw_rate = yaw * t.yaw.manual_rate end
        if fwd ~= 0 then
            cmd.fwd = fwd               -- W/S: tilt to travel (pilot)
        elseif t.hover.brake then
            cmd.damp_u = 0              -- rear thruster cancels fore/aft drift
        end
    else -- cruise
        if yaw ~= 0 then
            self.heading_target = s.heading
                + U.clamp(U.wrap180(self.heading_target - s.heading) + yaw * t.cruise.manual_turn * dt, -30, 30)
        end
        cmd.heading = self.heading_target
        cmd.bank = true
        -- W/S step the rear level, repeating every 0.2 s while held
        for key, dir in pairs({ W = 1, S = -1 }) do
            if pressed(self, key) then
                self.held[key] = (self.held[key] or 0) + dt
                if edge(self, key) or self.held[key] >= 0.2 then
                    if not edge(self, key) then self.held[key] = 0 end
                    self.rear_target = U.clamp(self.rear_target + dir, 1, 15)
                end
            else
                self.held[key] = nil
            end
        end
        cmd.rear = self.rear_target
    end
    return cmd
end

-- ---------------------------------------------------------------- landing

function Flight:landingCmd(dt)
    local s, l, lt = self.est.s, self.land, self.t.landing
    -- No position or heading hold on the way down (the ship cannot strafe):
    -- stay level, the rear thruster cancels fore/aft drift, a rotation is
    -- braked to a stop. The autopilot turns onto the waypoint heading BEFORE
    -- starting the descent.
    local cmd = { damp_u = 0, w_sp = 0, tight = true } -- w_sp: roll gently against sideways drift

    -- wait for the gear to settle (its sensor jumps while it swings down)
    if self.gear_settle > 0 then
        cmd.alt = s.alt
    else
        local want = self:sinkLimit()
        l.rate = math.min(want, l.rate + lt.sink_accel * dt)
        cmd.vs = -l.rate
    end

    -- touchdown: the sensor says ground, or the ship stopped moving while it
    -- was being asked to sink (resting on something the sensor can't see)
    local thr = (self.shipcfg.proximity or {}).landed_threshold or 15
    if (self.prox or 0) >= thr then l.ticks = l.ticks + 1 else l.ticks = 0 end
    local stalled = cmd.vs and math.abs(s.vs) < lt.stall_rate and l.rate > lt.touch_rate * 0.5
    l.stall = stalled and l.stall + dt or 0
    local need = lt.stall_time * (((self.prox or 0) > 0) and 1 or 3)
    if l.ticks >= lt.ground_ticks or l.stall >= need then
        self:touchdown()
        return nil
    end
    return cmd
end

-- ---------------------------------------------------------------- unflip

function Flight:unflipCmd(dt)
    local s, u = self.est.s, self.unflip
    u.t = u.t + dt
    if s.up_y > 0.05 or u.t > self.t.unflip.timeout then
        self.unflip = nil
        self.phase = "flying"
        self:holdHere()
        self.ctl:softReset()
        self:notify(u.t > self.t.unflip.timeout and "UNFLIP TIMED OUT" or "UPRIGHT AGAIN")
        return nil
    end
    return { alt = s.alt + 3, heading = s.heading, reverse = true }
end

-- ---------------------------------------------------------------- tick

function Flight:update(dt, keys)
    self.prev, self.keys = self.keys, keys or {}
    local raw = self.hw.ship()
    local s = self.est:update(raw, dt)
    self.prox = self.hw.proximity()

    -- gear: down whenever the sensor sees ground; settle counter after deploy
    local pc = self.shipcfg.proximity or {}
    if self.prox >= (pc.gear_deploy_threshold or 1) then self:setGear(true) end
    if self.gear_settle > 0 then self.gear_settle = self.gear_settle - 1 end

    if not s.valid then
        -- no telemetry: hold the last outputs' lift, no corrections
        self:notify("NO SHIP TELEMETRY")
        self:write(nil)
        return
    end
    if s.alt > self.stats.max_alt then self.stats.max_alt = s.alt end
    if self.last_xz then
        self.stats.dist = self.stats.dist + U.hypot(s.x - self.last_xz[1], s.z - self.last_xz[2])
    end
    self.last_xz = { s.x, s.z }

    -- upside-down detection (any airborne phase)
    if s.inverted and self.phase ~= "parked" and self.phase ~= "estop" and self.phase ~= "unflip" then
        self.inv_t = self.inv_t + dt
        if self.inv_t >= self.t.unflip.detect_time then
            self.ap = nil
            self.land = nil
            self.phase = "unflip"
            self.unflip = { t = 0 }
            self:setMode("hover")
            self:notify("AUTO-UNFLIP")
        end
    else
        self.inv_t = 0
    end

    local cmd
    if self.phase == "estop" then
        if edge(self, "SPACE") then self:setEstop(false) end
    elseif self.phase == "parked" then
        if self.ap then
            -- autopilot asked for takeoff
        elseif edge(self, "SPACE") then
            self:takeoff()
            self.prev.SPACE = 15 -- the same press must not also step the target
            self.held.SPACE = 0
        end
        if edge(self, "SHIFT") then self:notify("TAKE OFF FIRST") end
    end

    if self.phase == "unflip" then
        cmd = self:unflipCmd(dt)
    end
    if self.phase == "landing" then
        if edge(self, "SPACE") and not self.land.from_ap then
            self:cancelLanding("LANDING CANCELLED")
        else
            cmd = self:landingCmd(dt)
        end
    end
    if self.phase == "flying" then
        if self.ap then
            local override = edge(self, "SPACE") or edge(self, "CTRL") or edge(self, "W")
                or edge(self, "S") or edge(self, "Q") or edge(self, "E")
            if override then
                self.ap:cancel("PILOT OVERRIDE")
                self.ap = nil
                self:holdHere()
            end
        end
        if self.ap then
            cmd = self.ap:update(self, s, dt)
            if self.phase ~= "flying" then cmd = nil end
            if self.phase == "landing" then cmd = self:landingCmd(dt) end
        else
            if edge(self, "SHIFT") then
                local ok, m = self:toggleMode()
                self:notify(ok and ("MODE " .. m) or m)
            end
            cmd = self:pilot(dt)
            -- manual descent onto the ground ends as a landing
            local thr = pc.landed_threshold or 15
            if self.prox >= thr and self.alt_target < s.alt then
                self.ground_ticks = self.ground_ticks + 1
                if self.ground_ticks >= self.t.landing.ground_ticks then
                    self.ground_ticks = 0
                    self:touchdown()
                    cmd = nil
                end
            else
                self.ground_ticks = 0
            end
        end
    elseif self.ap and self.phase == "parked" then
        cmd = self.ap:update(self, s, dt)
    end

    if self.phase == "flying" or self.phase == "landing" or self.phase == "unflip" then
        self:run(cmd or { alt = s.alt, heading = s.heading }, dt)
    else
        self:write(nil)
    end
end

-- Run a command through the control laws.
function Flight:run(cmd, dt)
    local s, ctl, t = self.est.s, self.ctl, self.t
    -- Altitude: normally the fixed prop speed that balances at the target
    -- (Ctl:holdLift). The climb-rate controller is kept for what needs a
    -- set descent speed: landing, a sink faster than is safe this close to
    -- the ground, unflip, and explicit climb-rate commands.
    local lift
    local sink_cap = (self.prox and self.prox > 0 and self.phase ~= "unflip") and self:sinkLimit() or nil
    local use_rate = cmd.vs or self.phase ~= "flying" or not t.vertical.throttle_hold
        or (sink_cap and s.vs < -sink_cap)
    if use_rate then
        local vs_sp = cmd.vs or ctl:rateFor(s, cmd.alt or s.alt)
        if sink_cap then vs_sp = math.max(vs_sp, -sink_cap) end
        lift = ctl:lift(s, dt, vs_sp)
    else
        lift = ctl:holdLift(s, cmd.alt or s.alt)
    end

    -- signed: reverse thrust tips (and yaws) the hull the other way
    ctl.rear_level = (self.rear_rev and -1 or 1) * (self.rear or 0)
    -- Heading: a commanded turn rate (Q/E), a heading to hold (autopilot),
    -- or neither: then a rotation is only braked to a stop (hysteresis
    -- 1.5 / 0.5 deg/s) and the tilts are otherwise left alone.
    local rate_sp = cmd.yaw_rate
    local herr = 0
    if not rate_sp and cmd.heading then
        herr = U.wrap180(cmd.heading - s.heading)
        -- a target nearly behind: keep turning the way already chosen.
        -- Otherwise a fraction of a degree flips "the short way" between
        -- left and right every tick and the tilts flap without turning.
        if self.turn_dir and math.abs(herr) > 150 and U.sign(herr) ~= self.turn_dir then
            herr = herr + 360 * self.turn_dir
        end
        if math.abs(herr) > 2 then self.turn_dir = U.sign(herr) end
        rate_sp = ctl:yawRateFor(herr)
    else
        self.turn_dir = nil
    end
    if rate_sp then
        self.yaw_brk = false
    else
        local r = math.abs(s.yaw_rate or 0)
        if r > 1.5 then self.yaw_brk = true elseif r < 0.5 then self.yaw_brk = false end
        if self.yaw_brk then rate_sp = 0 end
    end
    ctl.dbg_yaw = nil
    -- CRUISE: never steer with the prop tilts. At speed a tilt kick goes
    -- through the tail fin into a mess of roll and pitch. The ship steers
    -- like a plane instead: it banks (below) and the fin swings the nose
    -- round smoothly. The tilts are for turning in place, in hover.
    local cruising = self.mode == "cruise" and not cmd.reverse
    if cruising then rate_sp = nil end
    local yaw = rate_sp and ctl:yaw(s, dt, rate_sp) or 0

    local fwd = 0
    if self.mode == "hover" then
        if cmd.fwd then fwd = cmd.fwd elseif cmd.u_sp then fwd = ctl:fwd(s, cmd.u_sp, cmd.fine) end
    end

    local roll_sp = 0
    if cmd.bank then
        -- bank toward the heading wanted, eased off by how fast the nose is
        -- already swinging (so it rolls out before reaching the heading
        -- instead of overshooting it)
        -- Only at real cruise speed: slow, a bank just slides the hull
        -- sideways (the fin needs airspeed to swing the nose round).
        local c = t.cruise
        local v0, v1 = c.bank_v0 or 6, c.bank_v1 or 15
        local k = U.clamp(((s.u or 0) - v0) / math.max(v1 - v0, 1), 0, 1)
        roll_sp = k * (c.bank_sign or 1) * U.clamp(c.bank_gain * herr - (c.bank_damp or 0) * (s.yaw_rate or 0),
            -c.bank_max, c.bank_max)
    elseif cmd.w_sp then
        roll_sp = ctl:lateral(s, cmd.w_sp, cmd.fine)
    end
    local dp, dr = ctl:attitude(s, dt, cmd.pitch or 0, roll_sp)
    if self.calib and self.phase == "flying" then dp, dr = self:calibStep(s, dt, dp, dr) end
    self.last_dp, self.last_dr = dp, dr
    if cmd.reverse then
        -- righting: a hard, simple PD push on whichever way is shorter
        local a, drive = t.attitude, t.unflip.drive
        dr = U.clamp(a.kp * 3 * U.wrap180(-s.roll) - a.kd * s.roll_rate, -drive, drive)
        dp = U.clamp(a.kp * 3 * -s.pitch - a.kd * s.pitch_rate, -drive, drive)
        -- the rotation matters more than height here: leave room for it
        lift = math.min(lift, 15 - drive - 1)
    end

    if s.inverted and not cmd.reverse then
        -- upside down with normal lift = thrust toward the ground: cut it
        -- until the unflip takes over (fall at g, not 2 g)
        lift, dp, dr, fwd, yaw = 0, 0, 0, 0, 0
    end
    local out = ctl:allocate(dt, lift, dp, dr, fwd, yaw, cmd.reverse and -1 or 1)
    ctl:learnHover(s, dt, self.out.lift_used)

    -- rear thruster: ramps up, drops instantly. Its thrust line is off the
    -- centre of mass, so it pitches the hull; when the stabiliser runs out
    -- of prop range holding that (props pinned AND pitch off), the rear cap
    -- backs off instead of letting the ship sink nose-up. That is the
    -- original's "drops out of the sky going from step 2 to 3".
    local pitch_err = math.abs(s.pitch - (cmd.pitch or 0))
    -- the rear thrust tips the hull: ease off while the stabiliser is out of
    -- room, or once the hull is clearly tipped (the stabiliser is gentle on
    -- purpose and needs the thrust to come off to catch up)
    if self.rear > 0 and ((ctl.sat ~= 0 and pitch_err > 2) or pitch_err > 6) then
        self.rear_cap = math.max(1, (self.rear_cap or 15) - 4 * dt)
    else
        self.rear_cap = math.min(15, (self.rear_cap or 15) + 0.5 * dt)
    end
    local want, rev = 0, false
    if cmd.damp_u ~= nil then
        want, rev = self:rearBrake(s, cmd.damp_u, cmd.tight)
    elseif self.mode == "cruise" then
        want = cmd.rear or self.rear_target
        rev = (cmd.rear_rev and self:feature("rear_reverse")) or false
    end
    want = math.min(want, self.rear_cap)
    if rev ~= (self.rear_rev or false) then self.rear = 0 end -- respool in the new direction
    self.rear_rev = rev
    if want > self.rear then
        self.rear = math.min(want, self.rear + t.cruise.ramp * dt)
    else
        self.rear = want
    end
    out.rear = self.rear
    out.rear_rev = rev
    out.reverse = cmd.reverse
    self.cmd = cmd
    self.rate_sp, self.roll_sp = rate_sp, roll_sp
    self:write(out)
end

-- Direction check, run once after a take-off (until both axes are known).
-- A correction that pushes the wrong way turns the stabiliser into an
-- amplifier: on a self-righting hull that shows as roll swings that grow
-- every time. So the ship nudges itself and watches what happens.
-- The real ship answers about a second LATE, so each nudge (+D then -D, a
-- doublet that leaves no spin behind) is followed by a hands-off watch long
-- enough to see the whole answer, then the mirror nudge (-D then +D). The
-- answer is the first swing each one causes; both must agree.
-- Nudges start tiny (the real roll axis reacts strongly) and get firmer
-- only while the answer stays unclear: {prop units, seconds}.
local CAL_STEPS = { { 0.5, 0.4 }, { 1.0, 0.6 }, { 2.0, 1.0 }, { 3.0, 1.5 }, { 4.0, 2.0 } }
local CAL_WATCH = 2.5 -- s hands-off after each nudge (covers the lag)
local CAL_MIN = 0.3   -- deg/s of rate change that counts as an answer

function Flight:calibStep(s, dt, dp, dr)
    local c, ctl = self.calib, self.ctl
    c.t = c.t + dt
    local function rate(axis) return axis == "roll" and s.roll_rate or s.pitch_rate end
    local function nextAxis()
        if (ctl.roll_known or 0) == 0 and not c.done_roll then return "roll" end
        if (ctl.pitch_known or 0) == 0 and not c.done_pitch then return "pitch" end
    end
    -- the nudge rides on top of what the stabiliser was giving when the
    -- ship was still (its trim: dropping that would tip the hull by itself)
    local function out(push)
        push = (c.base or 0) + push
        if c.axis == "roll" then return dp, push end
        return push, dr
    end
    if c.stage == "wait" or c.stage == "settle" then
        -- truly still: level AND not swinging, held for 2 s (v2.9 started
        -- its nudges mid-swing and measured the swing, not the nudge)
        local still = math.abs(s.vs) < 1.5 and math.abs(s.roll) < 4 and math.abs(s.pitch) < 4
            and math.abs(s.roll_rate) < 2 and math.abs(s.pitch_rate) < 2 and s.alt > c.alt0 + 3
        c.still = still and (c.still or 0) + dt or 0
        if c.t > 3 and c.still >= 2 then
            local ax = nextAxis()
            if not ax then self.calib = nil return dp, dr end
            if ax ~= c.axis then c.axis, c.try = ax, 1 end
            c.base = (ax == "roll") and dr or dp
            c.stage, c.t, c.r0, c.pk, c.lock = "plus", 0, rate(c.axis), 0, false
        elseif c.t > 25 then
            U.log("direction check: ship never steady enough, skipped")
            self.calib = nil
        end
        return dp, dr
    end
    -- a nudge that sets the ship moving too much is cut short: answer unclear
    local ang = (c.axis == "roll") and s.roll or s.pitch
    if math.abs(ang) > 5 or math.abs(rate(c.axis)) > 8 then
        U.log("%s direction check: ship moving too much (%.1f deg, %.1f deg/s), stopped the nudge",
            c.axis, ang, rate(c.axis))
        c["done_" .. c.axis] = true
        c.stage, c.t, c.still = "settle", 0, 0
        return dp, dr
    end
    -- the FIRST swing's peak rate change since this nudge began (signed);
    -- once it has clearly passed, the hull's own return swing is ignored
    local d = rate(c.axis) - c.r0
    if not c.lock then
        if math.abs(d) > math.abs(c.pk) then c.pk = d
        elseif math.abs(c.pk) > 0.02 and math.abs(d) < 0.6 * math.abs(c.pk) then c.lock = true end
    end
    local step = CAL_STEPS[c.try or 1]
    local D = step[1] * (ctl.att_scale or 1)
    -- each nudge is a DOUBLET: push for T, then the opposite for T, so the
    -- hull ends with no spin of its own; the first swing it makes (seen up
    -- to a second later) is the answer to the first half
    if c.stage == "plus" or c.stage == "minus" then
        if c.t < step[2] then return out(c.stage == "plus" and D or -D) end
        c.stage, c.t = c.stage .. "2", 0
    end
    if c.stage == "plus2" or c.stage == "minus2" then
        if c.t < step[2] then return out(c.stage == "plus2" and -D or D) end
        c.stage = (c.stage == "plus2") and "watch1" or "watch2"
        c.t = 0
        return out(0)
    end
    if c.t < CAL_WATCH then return out(0) end
    if c.stage == "watch1" then
        c.d1 = c.pk
        c.stage, c.t, c.r0, c.pk, c.lock = "minus", 0, rate(c.axis), 0, false
        return out(-D)
    end
    -- watch2 over: decide
    local d1, d2 = c.d1, c.pk
    local key = c.axis .. "_sign"
    local msg
    local agree = (d1 > 0) ~= (d2 > 0)
    local effect = (d1 - d2) / 2 -- deg/s, + = as designed
    if not agree or math.abs(d1) < CAL_MIN or math.abs(d2) < CAL_MIN then
        msg = string.format("%s direction check: unclear (%.2f / %.2f deg/s) at nudge %d",
            c.axis, d1, d2, c.try or 1)
        if (c.try or 1) < #CAL_STEPS then
            c.try = (c.try or 1) + 1
            U.log(msg .. ", trying a firmer one")
            c.stage, c.t, c.still = "settle", 0, 0
            return dp, dr
        end
        msg = msg .. ", giving up until next take-off"
    else
        local sign = effect > 0 and 1 or -1
        local flipped = sign ~= ctl[key]
        ctl[key] = sign
        ctl[c.axis .. "_known"] = 1
        if flipped then
            if c.axis == "roll" then ctl.ri = 0 else ctl.pi_ = 0 end
        end
        msg = string.format("%s direction check: %s (%.2f deg/s)", c.axis,
            sign == 1 and "as designed" or "REVERSED, corrected", effect)
        self:notify((c.axis .. (sign == 1 and " direction OK" or " direction reversed: fixed")):upper())
    end
    U.log(msg)
    c["done_" .. c.axis] = true
    c.stage, c.t, c.still = "settle", 0, 0
    return dp, dr
end

-- Fore/aft speed hold with the REAR thruster (forward thrust, or reverse
-- to push back). Hysteresis: starts when the speed error passes `rear_on`,
-- stops under `rear_off`, so it is not toggling all the time.
function Flight:rearBrake(s, u_sp, tight)
    local h = self.t.hover
    local e = u_sp - (s.u or 0)
    local a = math.abs(e)
    -- tight: turning in place / descending onto a spot, where a slow creep
    -- adds up; the rear only nudges, so a lower threshold stays smooth
    local on, off = h.rear_on, h.rear_off
    if tight then on, off = on * 0.5, off * 0.5 end
    if self.rb_on then
        if a < off then self.rb_on = false end
    elseif a > on then
        self.rb_on = true
    end
    if not self.rb_on then return 0, false end
    local rev = e < 0 -- moving forward faster than wanted: push back
    if rev and not self:feature("rear_reverse") then return 0, false end
    return U.clamp(h.rear_gain * a, 1, h.rear_max), rev
end

-- Prop speeds are whole redstone levels, but the gentle stabiliser asks for
-- fractions (0.2 of a level is a real correction on this ship): plain
-- rounding threw those away and let the hull lean 2-3 degrees unopposed,
-- sliding sideways. So each prop carries what rounding dropped into the
-- next tick (error diffusion): it steps between two neighbouring levels, and
-- the props, taking about a second to spin up, average that into the speed
-- in between. A change of a whole level or more goes through at once.
function Flight:quantise(p, v)
    local q = self.quant or {}
    self.quant = q
    v = U.clamp(v, 0, 15)
    local st = q[p]
    if not st or math.abs(v - st.lvl) >= 1 then
        st = { lvl = math.floor(v + 0.5), carry = 0 }
        q[p] = st
        return st.lvl
    end
    local e = v + st.carry
    st.lvl = U.clamp(math.floor(e + 0.5), 0, 15)
    st.carry = U.clamp(e - st.lvl, -0.5, 0.5)
    return st.lvl
end

-- Push outputs to the hardware. nil = parked/estop/no telemetry.
function Flight:write(out)
    local hw = self.hw
    if not out then
        local creep = (self.phase == "parked") and self.t.ship.creep or 0
        out = { FL = creep, FR = creep, RL = creep, RR = creep,
            tilt = { FL = 0, FR = 0, RL = 0, RR = 0 }, rear = 0, rear_rev = false }
        if self.phase == "parked" or self.phase == "estop" then self.ctl:softReset() end
    end
    for _, p in ipairs(hw.PROPS) do
        local lvl = self:quantise(p, out[p] or 0)
        self.levels[p] = lvl -- what the relay really got (black box)
        hw.setProp(p, lvl)
        hw.setTilt(p, out.tilt[p] or 0)
    end
    hw.setRear(out.rear or 0, out.rear_rev)
    hw.setLiftReverse(out.reverse == true)
    hw.setGear(self.gear_down)
    self.out = out
end

-- Fresh start after power-on. `where` is decided by the caller:
--   "ground" (engines started from the start screen): parked, gear down, props
--            idle; the pilot takes off (SPACE / TAKE OFF / autopilot).
--   "air"    (the OS was flying when it stopped): take control at once.
-- The ground sensor alone cannot decide this: on this ship it reads 0 while
-- parked, which looks exactly like "nothing below".
function Flight:boot(where, gear)
    local s = self.est:update(self.hw.ship(), 0.05)
    self.prox = self.hw.proximity()
    self.ctl:reset()
    self.ap, self.land, self.unflip = nil, nil, nil
    self.mode = "hover"
    self.rear_target, self.rear = 0, 0
    if where == "air" and s.valid then
        self.phase = "flying"
        self.gear_down = (gear == nil) and (self.prox > 0) or gear
    else
        self.phase = "parked"
        self.gear_down = true
    end
    self:holdHere()
end

return Flight
