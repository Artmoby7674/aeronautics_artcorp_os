-- v2 control laws. Pure maths: state + setpoints in, actuator demands out.
--
-- The design goals, each a fix for something the original fought with:
--   1. LIFT IS NEVER SPENT ON ATTITUDE. Pitch/roll corrections move props in
--      pairs, one up and one down, so the mean lift stays put. Only when a
--      prop would pass 0 or 15 is the mean shifted, by at most `reserve`.
--   2. TILT IS PAID FOR PER PROP. A tilted prop keeps cos(25) of its lift, so
--      exactly that prop spins faster. Turning no longer sinks the ship.
--   3. ALTITUDE IS A CLIMB-RATE LOOP. Altitude error picks a climb rate (with
--      a braking curve), and a PI loop on the measured climb rate picks the
--      lift. Same law for climbs, holds and landings.
--   4. TILT IS ON/OFF, SO IT IS MODULATED IN TIME. Any signal gives the full
--      25 deg; a sigma-delta modulator with a minimum dwell turns a 0..1
--      demand into the right fraction of time tilted.
--   5. CONSTANT DISTURBANCES ARE LEARNED. Small integrators on pitch, roll
--      and yaw rate soak up an off-centre hull, the rear thruster's torque
--      and whatever makes the ship drift right in cruise.
local U = require("util")

local Ctl = {}
Ctl.__index = Ctl

local PROPS = { "FL", "FR", "RL", "RR" }
local FRONT = { FL = 1, FR = 1, RL = -1, RR = -1 }
local LEFT = { FL = 1, FR = -1, RL = 1, RR = -1 }

function Ctl.new(tune)
    local self = setmetatable({}, Ctl)
    self.t = tune
    self.cos_tilt = math.cos(math.rad(tune.physics.tilt_deg))
    self.hover = tune.ship.hover_throttle
    self:reset()
    return self
end

function Ctl:reset()
    self.vi = 0          -- climb-rate integrator (m/s^2)
    self.pi_, self.ri = 0, 0
    self.yi = 0
    -- learned per-rear-level feedforwards (pitch units, yaw duty)
    self.rear_pk = self.rear_pk or 0
    -- which way a correction actually moves the hull: +1 as designed, -1 if
    -- the ship is wired/oriented the other way. Measured at take-off (see
    -- Flight:calibStep) and kept with the learned values.
    self.roll_sign = self.roll_sign or 1
    self.pitch_sign = self.pitch_sign or 1
    self.rear_yk = self.rear_yk or 0
    self.rear_level = 0
    self.sd = { L = { frac = 0 }, R = { frac = 0 }, Y = { out = 0, t = 99 }, F = { out = 0, t = 99 } }
    self.prev_out = nil
    self.sat = 0         -- last allocation: +1 lift capped high, -1 low
    self.margin = 15
end

-- Keep learned trims, forget transient state (used on mode changes).
function Ctl:softReset()
    self.vi = 0
end

-- ------------------------------------------------------------ vertical

-- Climb-rate setpoint toward a target altitude: proportional close in,
-- limited by a braking curve and the climb/sink caps.
function Ctl:rateFor(s, alt_target)
    local v = self.t.vertical
    local e = alt_target - s.alt
    local mag = math.min(v.alt_gain * math.abs(e), U.brakeSpeed(math.abs(e), v.brake_accel))
    if e >= 0 then return math.min(mag, v.climb_max) end
    return -math.min(mag, v.sink_max)
end

-- Lift (mean prop thrust in vertical units, i.e. before tilt compensation)
-- that drives the measured climb rate to vs_sp.
function Ctl:lift(s, dt, vs_sp)
    local v, g = self.t.vertical, self.t.physics.gravity
    local err = vs_sp - s.vs
    local can_int = not ((self.sat > 0 and err > 0) or (self.sat < 0 and err < 0))
    if can_int then
        self.vi = U.clamp(self.vi + v.rate_int * err * dt, -v.int_limit, v.int_limit)
    end
    local a_cmd = U.clamp(v.rate_gain * err + self.vi, -0.8 * g, 0.9 * g)
    local cosatt = math.max(math.abs(s.up_y or 1), 0.5)
    self.vs_sp, self.a_cmd = vs_sp, a_cmd
    return self.hover / (s.press * s.den) * (1 + a_cmd / g) / cosatt
end

-- In-flight hover throttle learning: when the ship is steady, the lift it is
-- actually using IS the hover lift (scaled back to sea level).
function Ctl:learnHover(s, dt, lift_used)
    local v = self.t.vertical
    if not v.hover_learn or not lift_used then return end
    if math.abs(s.vs) > 1.5 or math.abs(s.accel or 0) > 1 then return end
    if math.abs(s.pitch) > 8 or math.abs(s.roll) > 8 or self.sat ~= 0 then return end
    local g = self.t.physics.gravity
    local meas = lift_used * s.press * s.den * math.abs(s.up_y or 1) / (1 + (s.accel or 0) / g)
    local base = self.t.ship.hover_throttle
    meas = U.clamp(meas, base * 0.6, base * 1.5)
    self.hover = U.lowpass(self.hover, meas, dt, v.hover_learn_tau)
end

-- ------------------------------------------------------------ attitude

local function deadband(e, d)
    if e > d then return e - d elseif e < -d then return e + d end
    return 0
end

-- Per-prop differential (prop units) for pitch and roll setpoints.
-- dp > 0 raises the nose (front props up, rear down); dr > 0 rolls right
-- side down (left props up, right down).
function Ctl:attitude(s, dt, pitch_sp, roll_sp)
    local a = self.t.attitude
    local scale = U.clamp(1 / (s.press * s.den), 1, 3)

    local ep = U.wrap180(pitch_sp - s.pitch)
    local er = U.wrap180(roll_sp - s.roll)
    -- rear thrust pitches the hull in proportion to its level: learn that
    -- gain (adaptive feedforward, regressor = rear level) so the correction
    -- arrives with the thrust instead of after the integrator catches up
    local rl = (self.rear_level or 0) / 15
    if math.abs(rl) > 0.1 then
        self.rear_pk = U.clamp(self.rear_pk + a.ki * 4 * ep * rl * dt, -a.max_corr, a.max_corr)
    end
    -- separate roll gains: a long, narrow hull is far harder to pitch than
    -- to roll, and pitch-level damping makes the light roll axis oscillate
    local rk = a.roll or {}
    local dp = a.kp * deadband(ep, a.deadband) - a.kd * s.pitch_rate + self.pi_ + self.rear_pk * rl
    local dr = (rk.kp or a.kp) * deadband(er, rk.deadband or a.deadband) - (rk.kd or a.kd) * s.roll_rate + self.ri
    -- integrate only while the output is not pinned (anti-windup)
    if math.abs(dp) < a.max_corr then
        self.pi_ = U.clamp(self.pi_ + a.ki * ep * dt, -a.int_limit, a.int_limit)
    end
    if math.abs(dr) < a.max_corr then
        self.ri = U.clamp(self.ri + (rk.ki or a.ki) * er * dt, -a.int_limit, a.int_limit)
    end
    dp = U.clamp(dp, -a.max_corr, a.max_corr) * scale
    dr = U.clamp(dr, -a.max_corr, a.max_corr) * scale
    self.att_scale = scale
    return dp * self.pitch_sign, dr * self.roll_sign
end

-- ------------------------------------------------------------ yaw

function Ctl:yawRateFor(heading_err)
    local y = self.t.yaw
    local e = math.abs(heading_err) - y.hold_band
    if e <= 0 then return 0 end
    local brake = 0.7 * (self.yaw_brake or y.brake_accel)
    local mag = math.min(y.heading_gain * e, U.brakeSpeed(e, brake), y.rate_max)
    return U.sign(heading_err) * mag
end

-- Tilt duty -1..1 (+ = turn right) that holds yaw rate at rate_sp.
function Ctl:yaw(s, dt, rate_sp)
    local y = self.t.yaw
    local err = rate_sp - s.yaw_rate
    -- holding still and barely turning: leave the tilts alone (every tilt
    -- change is a small lift transient on that side)
    if rate_sp == 0 and math.abs(s.yaw_rate) < 1 then return 0 end
    local rl = (self.rear_level or 0) / 15
    if math.abs(rl) > 0.1 and math.abs(err) < 4 then
        self.rear_yk = U.clamp(self.rear_yk + y.rate_int * 4 * err * rl * dt, -1, 1)
    end
    local u = y.rate_gain * err + self.yi + self.rear_yk * rl
    -- the integrator learns steady torques, so it only runs near a steady
    -- rate (during a big turn the error is the turn, not a disturbance)
    if math.abs(u) < 1 and math.abs(err) < 4 then
        self.yi = U.clamp(self.yi + y.rate_int * err * dt, -y.int_limit, y.int_limit)
    end
    u = U.clamp(u, -1, 1)
    -- learn how hard the ship can actually brake a turn: full opposite tilt
    -- while still turning, measured from the rate change
    -- (whole braking episodes, averaged: a per-tick derivative is too noisy)
    local r = s.yaw_rate
    local braking = math.abs(u) > 0.95 and u * r < 0 and math.abs(r) > 2
    local ep = self.yaw_ep
    if braking and not ep then
        self.yaw_ep = { t = 0, r0 = math.abs(r) }
    elseif braking then
        ep.t = ep.t + dt
        ep.r1 = math.abs(r)
    elseif ep then
        if ep.t >= 0.6 and ep.r1 and ep.r0 > ep.r1 then
            local decel = (ep.r0 - ep.r1) / ep.t
            local prev = self.yaw_brake or y.brake_accel
            self.yaw_brake = U.clamp(prev + 0.5 * (decel - prev), 0.5, 20)
        end
        self.yaw_ep = nil
    end
    return u
end

-- Fore/aft tilt duty -1..1 (+ = push forward) toward a forward speed.
function Ctl:fwd(s, u_sp, fine)
    local h = self.t.hover
    local e = u_sp - s.u
    if math.abs(e) < h.fwd_dead then return 0 end
    return U.clamp(h.fwd_gain * (fine and 2.5 or 1) * e, -1, 1)
end

-- Bank angle (deg) that cancels sideways drift toward w_sp.
function Ctl:lateral(s, w_sp, fine)
    local h = self.t.hover
    local g, m = h.lat_gain, h.lat_max
    if fine then g, m = g * 2, m * 1.5 end
    return U.clamp(g * ((w_sp or 0) - s.w), -m, m)
end

-- ------------------------------------------------------------ allocation

-- On/off tilt with hysteresis and minimum hold times. A huge hull reacts
-- slowly, so instead of flickering the tilt many times a second (each flip
-- is a big torque kick: the vibration), a side tilts only when the demand
-- is clearly there, stays tilted at least `min_on`, and once released stays
-- level at least `min_off`. Between pulses the ship coasts on momentum.
local function modulate(ch, u, dt, tc)
    ch.t = (ch.t or 0) + dt
    local want = ch.out
    if ch.out == 0 then
        if u >= tc.on then want = 1 elseif u <= -tc.on then want = -1 end
        if want ~= 0 and ch.t < tc.min_off then want = 0 end
    else
        -- keep going while the demand still points the same way
        if u * ch.out < tc.off then want = 0 end
        if ch.t < tc.min_on then want = ch.out end
    end
    if want ~= ch.out then
        ch.out = want
        ch.t = 0
    end
    return ch.out
end

-- lift: mean vertical thrust; dp/dr: differentials; fwd/yaw: tilt duties.
-- moment_sign = -1 while the lift is reversed (unflip). Returns
-- { FL = speed, ..., tilt = { FL = -1|0|1, ... } } and records saturation.
function Ctl:allocate(dt, lift, dp, dr, fwd, yaw, moment_sign)
    local a, y = self.t.attitude, self.t.yaw
    moment_sign = moment_sign or 1
    yaw = (yaw or 0) * y.sign
    fwd = (fwd or 0) * self.t.hover.tilt_sign
    -- Two pulse channels, turn and travel; each side is their sum, so a turn
    -- always tilts both sides at the same instant (pure rotation, no shove).
    local tc = self.t.tilt
    local Y = modulate(self.sd.Y, yaw, dt, tc)
    local F = modulate(self.sd.F, fwd, dt, tc)
    local tl = U.clamp(F + Y, -1, 1)
    local tr = U.clamp(F - Y, -1, 1)

    -- lift compensation follows the mechanism's travel, not the command
    local lag = math.max(self.t.physics.tilt_lag or 0, dt)
    for side, t in pairs({ L = tl, R = tr }) do
        local ch = self.sd[side]
        ch.frac = U.approach(ch.frac, (t ~= 0) and 1 or 0, dt / lag)
    end
    local c, d = {}, {}
    for _, p in ipairs(PROPS) do
        local frac = self.sd[(LEFT[p] > 0) and "L" or "R"].frac
        c[p] = 1 - (1 - self.cos_tilt) * frac
        d[p] = moment_sign * (FRONT[p] * dp + LEFT[p] * dr)
    end

    -- High side: shift the mean down (up to `reserve`), then shrink the
    -- differential. Low side mirrors it. Altitude takes the small hit,
    -- attitude keeps its authority.
    local sat = 0
    local over = -math.huge
    for _, p in ipairs(PROPS) do over = math.max(over, lift + d[p] - 15 * c[p]) end
    if over > 0 then
        sat = 1
        lift = lift - math.min(over, a.reserve)
        local k = 1
        for _, p in ipairs(PROPS) do
            if d[p] > 0 then
                local room = 15 * c[p] - lift
                if lift + d[p] > 15 * c[p] then k = math.min(k, math.max(room, 0) / d[p]) end
            end
        end
        for _, p in ipairs(PROPS) do d[p] = d[p] * k end
    end
    local under = math.huge
    for _, p in ipairs(PROPS) do under = math.min(under, lift + d[p]) end
    if under < 0 then
        sat = -1
        lift = lift + math.min(-under, a.reserve)
        local k = 1
        for _, p in ipairs(PROPS) do
            if d[p] < 0 and lift + d[p] < 0 then k = math.min(k, math.max(lift, 0) / -d[p]) end
        end
        for _, p in ipairs(PROPS) do d[p] = d[p] * k end
    end

    local out = { tilt = {} }
    local margin, used = 15, 0
    -- prop speeds change at most `slew` units/s: smooth thrust changes on a
    -- hull this size instead of step kicks every tick
    local slew = (a.slew or 8) * dt
    local prev = self.prev_out or {}
    self.prev_out = prev
    for _, p in ipairs(PROPS) do
        local v = U.clamp((lift + d[p]) / c[p], 0, 15)
        if prev[p] then v = U.clamp(v, prev[p] - slew, prev[p] + slew) end
        prev[p] = v
        out[p] = v
        out.tilt[p] = (LEFT[p] > 0) and tl or tr
        used = used + v * c[p]
        margin = math.min(margin, 15 - v)
    end
    self.sat, self.margin = sat, margin
    out.lift_used = used / 4
    return out
end

return Ctl
