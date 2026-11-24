-- v2 state estimator: turns the raw Sable pose into the flight quantities the
-- controllers use. Conventions (all v2 code):
--   heading  compass degrees, 0 = north (-Z), 90 = east (+X), increases turning right
--   pitch    degrees, + = nose UP
--   roll     degrees, + = right side DOWN (-180..180, |roll| > 90 = inverted)
--   rates    deg/s, from differencing the angles: frame-independent, so it
--            does not matter whether Sable reports angular velocity in world
--            or body axes (the original OS had to assume one).
--   u / w    speed along the nose / to the right, horizontal plane, m/s
local U = require("util")

local Est = {}
Est.__index = Est

function Est.new(tune)
    return setmetatable({ t = tune, s = { valid = false }, prev = nil }, Est)
end

function Est:pressure(h)
    if self.atmos then return self.atmos:press(h) end -- learned (atmos.lua)
    local p = self.t.physics
    return math.exp(-p.press_k * (h - p.press_ref))
end

function Est:update(raw, dt)
    local s = self.s
    if not raw.ok then
        s.valid = false
        s.err = raw.err
        return s
    end
    s.valid, s.err = true, nil
    -- debug: the game's physics sometimes stalls (pose and velocity exactly
    -- unchanged for many ticks) and then lets go (v2.20 log: frozen 22 s,
    -- then 140 m/s). Flag both so the log shows them.
    local pv = self.prev
    if pv and pv.x then
        local same = raw.x == pv.x and raw.y == pv.y and raw.z == pv.z and raw.uy == pv.uy
        self.frozen = same and (self.frozen or 0) + dt or 0
        if self.frozen >= 2 and not self.frozen_told then
            self.frozen_told = true
            U.log("telemetry: ship pose has not changed for 2 s (physics stalled?) at %.1f,%.1f,%.1f",
                raw.x, raw.y, raw.z)
        elseif self.frozen == 0 and self.frozen_told then
            self.frozen_told = false
            U.log("telemetry: ship moving again")
        end
        local jump = U.hypot(raw.x - pv.x, raw.z - pv.z, raw.y - pv.y)
        local expect = (U.hypot(raw.vx, raw.vz, raw.vy) + 5) * math.max(dt, 0.05) * 3 + 2
        if jump > expect and jump > 5 then
            U.log("telemetry: ship jumped %.1f m in one tick (%.2f s; speed says %.1f m)", jump, dt, expect)
        end
    end
    s.frozen = self.frozen or 0
    s.x, s.y, s.z = raw.x, raw.y, raw.z
    s.alt = raw.y
    s.vx, s.vy, s.vz = raw.vx, raw.vy, raw.vz
    s.vs = raw.vy
    s.hspeed = U.hypot(raw.vx, raw.vz)
    s.mass = raw.mass

    local fh = U.hypot(raw.fx, raw.fz)
    local hfx, hfz = 0, -1
    if fh > 1e-6 then hfx, hfz = raw.fx / fh, raw.fz / fh end
    -- horizontal right vector = forward rotated 90 deg clockwise from above
    local hrx, hrz = -hfz, hfx
    s.fwd_x, s.fwd_z = hfx, hfz

    local heading = U.bearing(hfx, hfz)
    local pitch = math.deg(U.atan2(raw.fy, fh))
    local roll = math.deg(U.atan2(-raw.ry, raw.uy))
    s.up_y = raw.uy
    s.inverted = raw.uy < 0

    s.u = raw.vx * hfx + raw.vz * hfz
    s.w = raw.vx * hrx + raw.vz * hrz

    local tau = self.t.attitude.rate_tau
    if self.prev and dt > 0 then
        local pr = (pitch - self.prev.pitch) / dt
        local rr = U.wrap180(roll - self.prev.roll) / dt
        local yr = U.wrap180(heading - self.prev.heading) / dt
        s.pitch_rate = U.lowpass(s.pitch_rate, pr, dt, tau)
        s.roll_rate = U.lowpass(s.roll_rate, rr, dt, tau)
        s.yaw_rate = U.lowpass(s.yaw_rate, yr, dt, tau)
        s.accel = U.lowpass(s.accel, (s.vs - self.prev.vs) / dt, dt, 0.25)
    else
        s.pitch_rate, s.roll_rate, s.yaw_rate, s.accel = 0, 0, 0, 0
    end
    self.prev = { pitch = pitch, roll = roll, heading = heading, vs = s.vs,
        x = raw.x, y = raw.y, z = raw.z, uy = raw.uy }
    s.heading, s.pitch, s.roll = heading, pitch, roll

    s.press = self:pressure(s.alt)
    local ph = self.t.physics
    s.den = U.clamp(1 - s.vs / ph.airflow, 0.3, 3)
    return s
end

return Est
