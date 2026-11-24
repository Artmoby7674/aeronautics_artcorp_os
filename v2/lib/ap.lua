-- v2 waypoint autopilot. The ship can only push itself forward and back
-- (rear thruster) and turn (tilt); it cannot strafe. So the whole trip is
-- built from straight lines and turns made while stopped:
--
--   depart  turn toward the waypoint at the current (low) altitude, then
--           climb to the travel altitude; the rear thruster keeps it still
--   cruise  rear thruster on a speed profile that plans its own stop (rear
--           reverse brakes); heading held toward the waypoint while far out,
--           then left alone for the last `face_r` metres (no sideways fixes)
--   turn    drifted > turn_limit off course: stop, turn in place, resume
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

-- Highest altitude where hover still leaves lift_margin units free.
function AP:ceiling(fl)
    local ph, a = self.t.physics, self.t.autopilot
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
    if self.pt > a.phase_timeout then
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
        fl:setMode("hover")
        local cmd = { heading = brg, damp_u = 0 }
        -- turn first, low; climb once roughly on the bearing
        if math.abs(herr) > 30 then
            if not self.turn_alt then self.turn_alt = s.alt end
            cmd.alt = self.turn_alt
        else
            cmd.alt = self.goal_alt
        end
        if math.abs(herr) < a.heading_tol and math.abs(s.alt - self.goal_alt) < 4
            and math.abs(s.vs) < 1.2 and math.abs(s.yaw_rate) < 2 then
            self:setPhase("cruise")
        end
        return cmd
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
        if math.abs(herr) > 15 and dist > a.face_r then v_sp = math.min(v_sp, 10) end
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
        -- at (or past) the point, or planned to a standstill: stop
        if (dist < a.face_r and (v_sp < 0.5 or df < 0)) or dist < a.arrive_r then
            fl:setMode("hover")
            self:setPhase("stop")
            self.still = 0
        end
        return cmd
    end

    if self.phase == "turn" then
        fl:setMode("hover")
        if math.abs(herr) < a.heading_tol and math.abs(s.yaw_rate) < 2 then
            self:setPhase("cruise")
        end
        return { alt = self.goal_alt, heading = brg, damp_u = 0 }
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
                self.turn_alt = nil
                self:setPhase("depart") -- re-aim at the point, creep back
            else
                self:setPhase("align")
            end
        end
        return { alt = self.goal_alt, damp_u = 0, tight = true }
    end

    if self.phase == "align" then
        fl:setMode("hover")
        local herr2 = U.wrap180((wp.heading or s.heading) - s.heading)
        self.herr = herr2
        if (math.abs(herr2) < a.heading_tol and math.abs(s.yaw_rate) < 1) or self.pt > 60 then
            fl:beginLanding({ shutdown = a.shutdown_on_land, from_ap = true })
            self:setPhase("land")
        end
        return { alt = self.goal_alt, heading = wp.heading, damp_u = 0, tight = true }
    end

    return nil
end

return AP
