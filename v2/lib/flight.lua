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
        if yaw ~= 0 then
            cmd.yaw_rate = yaw * t.yaw.manual_rate
            self.turning = true
        else
            if self.turning then
                -- predict where the turn coasts to and hold that heading
                local r = s.yaw_rate
                self.heading_target = s.heading + U.sign(r) * r * r / (2 * t.yaw.brake_accel)
                self.turning = false
            end
            cmd.heading = self.heading_target
        end
        if fwd ~= 0 then
            cmd.fwd = fwd
            self.hold_pt = nil
        elseif t.hover.brake then
            -- hold the point where the stick was let go (speed-only damping
            -- lets a frictionless hull creep forever under the pulse
            -- threshold); gentle gains: tilt pulses, then coast back
            -- brake to a stop first, then hold the point where it stopped
            if not self.hold_pt and s.hspeed < 0.5 then self.hold_pt = { s.x, s.z } end
            if self.hold_pt then
                local dx, dz = self.hold_pt[1] - s.x, self.hold_pt[2] - s.z
                local df = dx * s.fwd_x + dz * s.fwd_z
                local dl = dx * -s.fwd_z + dz * s.fwd_x
                cmd.u_sp = U.clamp(0.1 * df, -1.5, 1.5)
                cmd.w_sp = U.clamp(0.1 * dl, -1.5, 1.5)
            else
                cmd.u_sp, cmd.w_sp = 0, 0
            end
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
    local cmd = { heading = l.heading }

    -- wait for the gear to settle (its sensor jumps while it swings down)
    if self.gear_settle > 0 then
        cmd.alt = s.alt
    else
        local want = self:sinkLimit()
        l.rate = math.min(want, l.rate + lt.sink_accel * dt)
        cmd.vs = -l.rate
    end

    -- hold the touchdown point: speed setpoints toward it, body frame
    local dx, dz = l.x - s.x, l.z - s.z
    local df = dx * s.fwd_x + dz * s.fwd_z
    local dl = dx * -s.fwd_z + dz * s.fwd_x
    cmd.u_sp = U.clamp(0.4 * df, -3, 3)
    cmd.w_sp = U.clamp(0.4 * dl, -3, 3)
    cmd.fine = true -- firmer speed/drift correction for the last metres

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
    local vs_sp = cmd.vs or ctl:rateFor(s, cmd.alt or s.alt)
    if self.prox and self.prox > 0 and self.phase ~= "unflip" then
        vs_sp = math.max(vs_sp, -self:sinkLimit())
    end
    local lift = ctl:lift(s, dt, vs_sp)

    ctl.rear_level = self.rear
    local rate_sp = cmd.yaw_rate
    local herr = 0
    if not rate_sp then
        herr = U.wrap180((cmd.heading or s.heading) - s.heading)
        rate_sp = ctl:yawRateFor(herr)
    end
    local yaw = ctl:yaw(s, dt, rate_sp)

    local fwd = 0
    if self.mode == "hover" then
        if cmd.fwd then fwd = cmd.fwd elseif cmd.u_sp then fwd = ctl:fwd(s, cmd.u_sp, cmd.fine) end
    end

    local roll_sp = 0
    if cmd.bank then
        roll_sp = U.clamp(t.cruise.bank_gain * herr, -t.cruise.bank_max, t.cruise.bank_max)
    elseif cmd.w_sp then
        roll_sp = ctl:lateral(s, cmd.w_sp, cmd.fine)
    end
    local dp, dr = ctl:attitude(s, dt, cmd.pitch or 0, roll_sp)
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
    local pitch_off = math.abs(s.pitch - (cmd.pitch or 0)) > 2
    if ctl.sat ~= 0 and pitch_off and self.rear > 0 then
        self.rear_cap = math.max(1, (self.rear_cap or 15) - 4 * dt)
    else
        self.rear_cap = math.min(15, (self.rear_cap or 15) + 0.5 * dt)
    end
    local want = (self.mode == "cruise") and (cmd.rear or self.rear_target) or 0
    want = math.min(want, self.rear_cap)
    if want > self.rear then
        self.rear = math.min(want, self.rear + t.cruise.ramp * dt)
    else
        self.rear = want
    end
    out.rear = self.rear
    out.rear_rev = cmd.rear_rev and self:feature("rear_reverse") or false
    if cmd.rear_rev and self:feature("rear_reverse") then out.rear = cmd.rear or 0 end
    out.reverse = cmd.reverse
    self.cmd = cmd
    self.rate_sp, self.roll_sp = rate_sp, roll_sp
    self:write(out)
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
        hw.setProp(p, out[p])
        hw.setTilt(p, out.tilt[p] or 0)
    end
    hw.setRear(out.rear or 0, out.rear_rev)
    hw.setLiftReverse(out.reverse == true)
    hw.setGear(self.gear_down)
    self.out = out
end

-- Fresh start after boot: decide parked vs flying from the sensor.
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
