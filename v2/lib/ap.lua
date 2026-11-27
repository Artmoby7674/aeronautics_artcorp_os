-- v2 waypoint autopilot. The ship can only push itself forward and back
-- (rear thruster) and turn (tilt); it cannot strafe. So the whole trip is
-- built from straight lines and turns made while stopped:
--
--   depart  climb straight up to the travel altitude (heading left alone);
--           the rear thruster keeps it still
--   turn    up there, turn in place to face the waypoint (also used when
--           cruise drifts more than turn_limit off course)
--   cruise  rear thruster on a speed profile that plans its own stop (rear
--           reverse brakes); heading held toward the waypoint while far out,
--           then left alone for the last `face_r` metres (no sideways fixes)
--   stop    rear thruster brings it to rest; if it ended far from the
--           waypoint it re-aims and creeps back (a couple of times at most)
--   align   turn in place onto the waypoint's saved heading
--   land    descend where it is: level, rear cancels fore/aft drift
--
-- The travel altitude keeps `lift_margin` prop units spare, so turning and
-- stabilising up there never runs out of lift.
local U = require("util")

local AP = {}
AP.__index = AP

AP.PHASES = { "depart", "cruise", "stop", "land" }

function AP.new(fl, wp)
    local s = fl.est.s
    local self = setmetatable({}, AP)
    self.wp = wp
    self.name = wp.name
    self.phase = "depart"
    self.pt = 0
    self.t = fl.t
    local dist = U.hypot(wp.x - s.x, wp.z - s.z)
    self.start_dist = math.max(dist, 1)
    self.hop = dist < fl.t.autopilot.hop_range
    self.start_alt = s.alt
    self.level_i = 0
    self.retries = 0
    self.dist = dist
    self:planAltitude(fl)
    return self
end

-- Highest altitude where hover still leaves lift_margin units free, from
-- the air the ship has measured (atmos.lua; the tuning file's curve until
-- it has flown).
function AP:ceiling(fl)
    local a = self.t.autopilot
    if fl.atmos then
        return fl.atmos:ceiling(a.lift_margin, self.start_alt, self.t.ship.max_altitude)
    end
    local ph = self.t.physics
    local H = fl.ctl.hover
    local need = 15 - a.lift_margin
    if need <= H then return self.start_alt end
    return ph.press_ref + math.log(need / H) / ph.press_k
end

function AP:planAltitude(fl)
    local a = self.t.autopilot
    local ceil = math.min(self:ceiling(fl), self.t.ship.max_altitude)
    if self.hop then
        self.goal_alt = math.min(self.start_alt + a.hop_climb, ceil)
    else
        self.goal_alt = math.min(a.cruise_alt, ceil)
    end
    self.goal_alt = math.max(self.goal_alt, math.min(self.start_alt, ceil))
    self.ceil = ceil
end

function AP:setPhase(p)
    if p ~= "turn" then self.turn_brg = nil end
    U.log("A/P %s: %s -> %s (%.0f m to go, %.0f s in %s)", self.name or "?", self.phase, p,
        self.dist or -1, self.pt or 0, self.phase)
    self.phase = p
    self.pt = 0
end

function AP:cancel(why)
    self.done = why or "CANCELLED"
end

function AP:status()
    return {
        name = self.name, phase = self.phase, dist = self.dist,
        progress = U.clamp(1 - self.dist / self.start_dist, 0, 1),
        eta = self.eta, goal_alt = self.goal_alt, herr = self.herr,
        v_sp = self.v_sp, hop = self.hop, ceil = self.ceil,
    }
end

function AP:update(fl, s, dt)
    local a = self.t.autopilot
    self.pt = self.pt + dt
    -- Cruise has no time limit while it makes progress: a 12 km trip takes
    -- well over 240 s (v2.34: "A/P TIMEOUT IN CRUISE" mid-trip, twice). It
    -- only gives up after stall_timeout s without getting 5 m closer.
    local timed_out = self.pt > a.phase_timeout and self.phase ~= "cruise"
    if self.phase == "cruise" and self.dist then
        if not self.best or self.dist < self.best - 5 then self.best, self.best_t = self.dist, 0 end
        self.best_t = (self.best_t or 0) + dt
        if self.best_t > (a.stall_timeout or 90) then timed_out = true end
    else
        self.best, self.best_t = nil, 0
    end
    if timed_out and not self.locked then
        fl:notify("A/P TIMEOUT IN " .. self.phase:upper())
        self:cancel("TIMEOUT")
        fl.ap = nil
        fl:holdHere()
        return nil
    end
    if fl.phase == "parked" then
        if self.phase ~= "depart" then self:cancel("LANDED") fl.ap = nil return nil end
        fl:takeoff()
        return nil
    end
    -- Gear up once clear of the ground: the gear sensor (range 14 blocks)
    -- has seen nothing for gear_up_after s. It comes back down on its own as
    -- soon as ground is in range again (Flight:update) and for the landing.
    if (fl.prox or 0) == 0 and fl.phase == "flying" then
        self.clear_t = (self.clear_t or 0) + dt
        if fl.gear_down and self.clear_t > (a.gear_up_after or 3) then
            fl:setGear(false)
            fl:notify("GEAR UP")
        end
    else
        self.clear_t = 0
    end

    local wp = self.wp
    local dx, dz = wp.x - s.x, wp.z - s.z
    local dist = U.hypot(dx, dz)
    self.dist = dist
    local brg = U.bearing(dx, dz)
    local herr = U.wrap180(brg - s.heading)
    self.herr = herr
    self.eta = dist / math.max(s.hspeed, 1)

    local df = dx * s.fwd_x + dz * s.fwd_z -- waypoint distance along the nose

    if self.phase == "depart" then
        -- climb straight up first, heading left alone (rotation only braked):
        -- turning happens up at the travel altitude, never near the ground
        fl:setMode("hover")
        local at_alt = math.abs(s.alt - self.goal_alt) < 4 and math.abs(s.vs) < 1.2
        -- the fixed-speed altitude hold can settle a few metres off its
        -- target: holding steady near it for 6 s counts as there (v2.30
        -- flight: it hung 4.6 m low and never turned, for minutes)
        if math.abs(s.vs) < 0.3 and math.abs(s.alt - self.goal_alt) < 12 then
            self.settle_t = (self.settle_t or 0) + dt
        else
            self.settle_t = 0
        end
        if self.settle_t > 6 then at_alt = true end
        -- re-aiming after a near miss: it is already up at travel height
        if self.retries > 0 then at_alt = true end
        if at_alt then
            -- Up at the planned altitude. If the plan was cut short by the
            -- ceiling the air model PREDICTS, check it: hang here until the
            -- air at this height is measured, then predict again. A world
            -- with more air than assumed lets it climb on (and again, each
            -- step measuring more); at the real limit the plan stops moving.
            local capped = not self.hop and self.goal_alt < a.cruise_alt - 5
            if capped and fl.atmos and (self.probes or 0) < 8 then
                self.probe_t = (self.probe_t or 0) + dt
                local here = false
                for _, p in ipairs(fl.atmos:points()) do
                    if math.abs(p.h - s.alt) < 6 then here = true end
                end
                if here or self.probe_t > 30 then
                    self.probe_t, self.probes = 0, (self.probes or 0) + 1
                    local ceil = math.min(fl.atmos:ceiling(a.lift_margin, s.alt, self.t.ship.max_altitude),
                        self.t.ship.max_altitude)
                    local goal = math.min(a.cruise_alt, ceil)
                    if goal > self.goal_alt + 5 then
                        U.log("A/P %s: more air than predicted: climbing on from Y%.0f to Y%.0f", self.name or "?", s.alt, goal)
                        self.goal_alt, self.ceil = goal, ceil
                    else
                        self.probes = 99 -- this is the ceiling: go
                    end
                end
            else
                self:setPhase("turn")
            end
        end
        -- the air ran out before the planned altitude (thinner than measured
        -- so far): stalled, props near the top, for 10 s = this IS the
        -- ceiling. Travel here instead of waiting for a climb that never ends.
        local pinned = (fl.ctl.margin or 15) < a.lift_margin * 0.5
        if s.alt < self.goal_alt - 4 and math.abs(s.vs) < 0.5 and pinned then
            self.stall_t = (self.stall_t or 0) + dt
        else
            self.stall_t = 0
        end
        if self.stall_t > 10 then
            -- the air here has just been measured (hanging still at full
            -- speed): travel where it leaves the lift margin spare
            local goal = s.alt - 3
            if fl.atmos then
                goal = math.min(goal, fl.atmos:ceiling(a.lift_margin, math.min(self.start_alt, s.alt), s.alt))
            end
            U.log("A/P %s: ceiling reached at Y%.0f (planned Y%.0f): flying at Y%.0f", self.name or "?", s.alt, self.goal_alt, goal)
            fl:notify(string.format("CEILING Y%.0f", s.alt))
            self.goal_alt, self.ceil = goal, goal
            self.stall_t, self.probes = 0, 0
        end
        return { alt = self.goal_alt, damp_u = 0 }
    end

    if self.phase == "cruise" then
        if dist > a.face_r and math.abs(herr) > a.turn_limit then
            fl:setMode("hover")
            self:setPhase("turn")
            return { alt = self.goal_alt, heading = brg, damp_u = 0 }
        end
        fl:setMode("cruise")
        local cap = (self.retries > 0) and a.creep_speed or (self.hop and a.hop_speed or a.cruise_speed)
        local room = math.max(df, 0) - a.stop_margin
        local v_sp = math.min(cap, U.brakeSpeed(room, a.cruise_brake))
        -- (no other speed limit: the speed only drops for the approach. A
        -- "15 deg off course = 10 m/s" cap used to live here; at 10 m/s the
        -- bank steering is too weak to fix the heading, so it never lifted.)
        self.v_sp = v_sp
        local cmd = { alt = self.goal_alt }
        if dist > a.face_r then
            cmd.heading, cmd.bank = brg, true
        end -- close in: no steering at all, just the straight line
        local e = v_sp - s.u
        if e < -1 and fl:feature("rear_reverse") then
            cmd.rear_rev = true
            cmd.rear = U.clamp((-e) * 2, 1, 10)
            self.level_i = 0
        else
            self.level_i = U.clamp(self.level_i + a.speed_int * e * dt, 0, 15)
            cmd.rear = U.clamp(self.level_i + a.speed_gain * e, 0, 15)
        end
        -- Nudge: the point is still ahead but the ship has stopped getting
        -- closer (the speed plan asks for less than one rear level, which
        -- the relay rounds to nothing). Pulse the rear thruster at level 1,
        -- 1.5 s on then a coast, until it moves again.
        local stalled = df > a.arrive_r and dist > a.arrive_r and not cmd.rear_rev
            and s.u < (a.nudge_speed or 0.5) and (cmd.rear or 0) < 1
        self.stuck_t = stalled and (self.stuck_t or 0) + dt or 0
        if self.stuck_t > (a.nudge_after or 3) then
            self.nudge_t = (self.nudge_t or 0) + dt
            if self.nudge_t % (a.nudge_period or 4) < (a.nudge_on or 1.5) then
                cmd.rear = math.max(cmd.rear or 0, 1)
                self.nudging = true
            else
                self.nudging = false
            end
        else
            self.nudge_t, self.nudging = 0, false
        end
        -- at (or past) the point, or planned to a standstill: stop
        if (dist < a.face_r and ((v_sp < 0.5 and df <= a.arrive_r + a.stop_margin) or df < 0)) or dist < a.arrive_r then
            fl:setMode("hover")
            self:setPhase("stop")
            self.still = 0
        end
        return cmd
    end

    if self.phase == "turn" then
        fl:setMode("hover")
        -- the heading to face is fixed when the turn starts: close to the
        -- point, a little sideways drift swings the bearing by many degrees
        -- a second and chasing it made the turn hunt back and forth (v2.23:
        -- 46 s to re-aim from 11 m). Rolling against the drift keeps it put.
        if not self.turn_brg then self.turn_brg = brg end
        local terr = U.wrap180(self.turn_brg - s.heading)
        self.herr = terr
        if math.abs(terr) < a.heading_tol and math.abs(s.yaw_rate) < 2 then
            self.turn_brg = nil
            self:setPhase("cruise")
        end
        return { alt = self.goal_alt, heading = self.turn_brg, damp_u = 0, w_sp = 0, tight = true }
    end

    if self.phase == "stop" then
        fl:setMode("hover")
        self.v_sp = 0
        if math.abs(s.u) < 0.3 and math.abs(s.yaw_rate) < 1 then
            self.still = (self.still or 0) + dt
        else
            self.still = 0
        end
        if self.still > 2 or self.pt > 60 then
            if dist > a.retry_r and self.retries < a.retries then
                self.retries = self.retries + 1
                self:setPhase("depart") -- re-aim at the point, creep back
            else
                self:setPhase("align")
            end
        end
        return { alt = self.goal_alt, damp_u = 0, w_sp = 0, tight = true }
    end

    if self.phase == "align" then
        fl:setMode("hover")
        local herr2 = U.wrap180((wp.heading or s.heading) - s.heading)
        self.herr = herr2
        if (math.abs(herr2) < a.heading_tol and math.abs(s.yaw_rate) < 1) or self.pt > 60 then
            fl:beginLanding({ shutdown = a.shutdown_on_land, from_ap = true })
            self:setPhase("land")
        end
        return { alt = self.goal_alt, heading = wp.heading, damp_u = 0, w_sp = 0, tight = true }
    end

    return nil
end

return AP
