-- v2 waypoint autopilot.
--
--   depart    turn toward the waypoint at the CURRENT altitude first (plenty
--             of spare lift low down), then climb to the travel altitude
--   cruise    rear thruster on a speed profile that plans its own slow-down,
--             heading held by tilt + bank (+ the learned yaw trim)
--   turn      cruise drifted > turn_limit off course: stop the rear, turn in
--             hover, resume
--   approach  hover travel onto the point (also the whole leg for short hops)
--   land      flight.lua's landing sequence, on the waypoint's heading
--
-- The travel altitude is chosen so the props keep `lift_margin` units spare:
-- turning and stabilising up there never runs out of lift.
local U = require("util")

local AP = {}
AP.__index = AP

AP.PHASES = { "depart", "cruise", "approach", "land" }

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

    if self.phase == "depart" then
        fl:setMode("hover")
        local cmd = { heading = brg, u_sp = 0, w_sp = 0 }
        -- turn first, low; climb once roughly on the bearing
        if math.abs(herr) > 30 then
            if not self.turn_alt then self.turn_alt = s.alt end
            cmd.alt = self.turn_alt
        else
            cmd.alt = self.goal_alt
        end
        if math.abs(herr) < a.heading_tol and math.abs(s.alt - self.goal_alt) < 4
            and math.abs(s.vs) < 1.2 then
            self:setPhase((self.hop or dist < a.approach_r) and "approach" or "cruise")
        end
        return cmd
    end

    if self.phase == "cruise" then
        if dist < a.approach_r then
            fl:setMode("hover")
            self:setPhase("approach")
            return { alt = self.goal_alt, heading = brg, u_sp = 0 }
        end
        if math.abs(herr) > a.turn_limit then
            fl:setMode("hover")
            self:setPhase("turn")
            return { alt = self.goal_alt, heading = brg, u_sp = 0 }
        end
        fl:setMode("cruise")
        local room = dist - a.approach_r * 0.6
        local v_sp = math.min(a.cruise_speed, U.brakeSpeed(room, a.cruise_brake))
        -- slow down while badly off course so the turn is tighter
        if math.abs(herr) > 15 then v_sp = math.min(v_sp, 10) end
        self.v_sp = v_sp
        local e = v_sp - s.u
        local cmd = { alt = self.goal_alt, heading = brg, bank = true }
        if e < -3 and fl:feature("rear_reverse") then
            cmd.rear_rev = true
            cmd.rear = U.clamp((-e) * 1.5, 1, 10)
            self.level_i = 0
        else
            self.level_i = U.clamp(self.level_i + a.speed_int * e * dt, 0, 15)
            cmd.rear = U.clamp(self.level_i + a.speed_gain * e, 0, 15)
        end
        return cmd
    end

    if self.phase == "turn" then
        fl:setMode("hover")
        if math.abs(herr) < a.heading_tol and math.abs(s.yaw_rate) < 3 then
            self:setPhase("cruise")
        end
        return { alt = self.goal_alt, heading = brg, u_sp = 0, w_sp = 0 }
    end

    if self.phase == "approach" then
        fl:setMode("hover")
        local df = dx * s.fwd_x + dz * s.fwd_z
        local dl = dx * -s.fwd_z + dz * s.fwd_x
        local near = dist < 15
        local heading = near and wp.heading or brg
        local u_mag = math.min(a.hover_speed, U.brakeSpeed(math.abs(df), a.hover_brake),
            0.5 * math.abs(df))
        if not near and math.abs(herr) > 25 then u_mag = math.min(u_mag, 1) end
        self.v_sp = u_mag
        local cmd = {
            alt = self.goal_alt, heading = heading,
            u_sp = U.sign(df) * u_mag,
            w_sp = U.clamp(0.4 * dl, -3, 3),
        }
        if dist < a.arrive_r and s.hspeed < a.arrive_speed then
            fl:beginLanding({ x = wp.x, z = wp.z, heading = wp.heading,
                shutdown = a.shutdown_on_land, from_ap = true })
            self:setPhase("land")
        end
        return cmd
    end

    return nil
end

return AP
