-- Rigid-body simulator for the v2 OS: the REAL v2 code (hw.lua included)
-- runs against mocked CC peripherals + a mocked CC:Sable `sublevel` API.
--
-- What it models that the original test plants did not:
--   * full 3-D attitude (quaternion), all three torque axes coupled
--   * prop spin-up lag (first order) and tilt servo travel time
--   * one control tick of telemetry delay (CC reads last tick's pose)
--   * thrust ~ prop speed * air pressure * (1 - axial speed / airflow)
--   * rear thruster with a vertical AND sideways offset from the centre of
--     mass: it pitches the nose and yaws the ship (the "keeps turning right")
--   * ground contact + gear-mounted proximity sensor (whole blocks)
-- What it does NOT know: the real ship's inertia and lag. Those are
-- parameters, and the tests sweep them instead of trusting one value.
local Sim = {}
Sim.__index = Sim

local atan2 = math.atan2 or math.atan

local function qmul(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end

local function rot(q, vx, vy, vz)
    local x, y, z, w = q.x, q.y, q.z, q.w
    local tx = 2 * (y * vz - z * vy)
    local ty = 2 * (z * vx - x * vz)
    local tz = 2 * (x * vy - y * vx)
    return vx + w * tx + (y * tz - z * ty), vy + w * ty + (z * tx - x * tz), vz + w * tz + (x * ty - y * tx)
end
Sim.rot = rot

local function irot(q, vx, vy, vz)
    return rot({ x = -q.x, y = -q.y, z = -q.z, w = q.w }, vx, vy, vz)
end

-- heading: compass degrees the nose points to. Ship is built nose = local +X.
function Sim.quatFromHeading(hdg, pitch, roll)
    -- yaw about world +Y: nose east (+X) at yaw 0; compass = 90 - yaw
    local yaw = math.rad(90 - hdg)
    local q = { w = math.cos(yaw / 2), x = 0, y = math.sin(yaw / 2), z = 0 }
    if roll and roll ~= 0 then
        -- roll + = right down = rotation about body +X by -roll?  body +Z is
        -- right; right going down means rotating about +X by +angle
        -- (y->z->...): +X rotation takes +Y toward +Z, i.e. up leans right,
        -- so the right side goes DOWN. -> positive angle.
        local r = math.rad(roll)
        q = qmul(q, { w = math.cos(r / 2), x = math.sin(r / 2), y = 0, z = 0 })
    end
    if pitch and pitch ~= 0 then
        -- nose up = rotation about body +Z (right axis) taking +X toward +Y
        local p = math.rad(pitch)
        q = qmul(q, { w = math.cos(p / 2), x = 0, y = 0, z = math.sin(p / 2) })
    end
    return q
end

local DEFAULTS = {
    g = 11, hover = 6, airflow = 25, press_k = 0.004, press_ref = 63,
    inertia = { 300, 400, 300 },   -- m^2 about body x(roll) y(yaw) z(pitch)
    ang_damp = 0.15,               -- 1/s
    drag = 0.03,                   -- 1/s linear
    prop_tau = 0.25,               -- s spin-up lag
    tilt_rate = 120,               -- deg/s servo travel
    tilt_deg = 25,
    rear_accel = 0.35,             -- m/s^2 per rear level
    rear_dy = 0,                   -- m: rear thrust line vs the CoM (3 rear
                                   -- thrusters around the centre: ~0)
    rear_dz = 0,                   -- m: sideways offset (+ = right)
    hull_pitch = 0,                -- deg/s^2 constant disturbances
    hull_roll = 0,
    hull_yaw = 0,
    fin = 0.4,                     -- deg/s^2 of turn toward sideways motion per m/s
                                   -- (the arrow-shaped tail fin weathervanes)
    ground = 64,
    delay_ticks = 1,
    arm = 3,
}

function Sim.new(o)
    local self = setmetatable({}, Sim)
    self.p = {}
    for k, v in pairs(DEFAULTS) do self.p[k] = v end
    for k, v in pairs(o or {}) do self.p[k] = v end
    local p = self.p
    self.t = 0
    self.pos = { x = o and o.x or 0, y = (o and o.y) or p.ground, z = o and o.z or 0 }
    self.vel = { x = 0, y = 0, z = 0 }
    self.q = Sim.quatFromHeading(o and o.heading or 0, o and o.pitch, o and o.roll)
    self.w = { x = 0, y = 0, z = 0 } -- body rates rad/s
    self.prop = { FL = 0, FR = 0, RL = 0, RR = 0 }
    self.tilt = { FL = 0, FR = 0, RL = 0, RR = 0 }
    self.relays = {}
    self.history = {}
    self.lift_reverse = false
    self.touch_v = nil
    self:snapshot()
    return self
end

-- --------------------------------------------------------------- CC mocks

function Sim:relay(name)
    if not self.relays[name] then
        local r = { out = {}, inp = {} }
        function r.setAnalogOutput(side, v) r.out[side] = v end
        function r.getAnalogInput(side) return r.inp[side] or 0 end
        function r.getAnalogOutput(side) return r.out[side] or 0 end
        self.relays[name] = r
    end
    return self.relays[name]
end

function Sim:install(cfg)
    local sim = self
    self.cfg = cfg
    _G.peripheral = {
        wrap = function(name) return sim:relay(name) end,
        getNames = function() return {} end,
        getType = function() return nil end,
        call = function() end,
    }
    _G.redstone = { setOutput = function(side, v) if side == "left" then sim.lift_reverse = v end end }
    _G.sublevel = {
        getLogicalPose = function()
            local h = sim.history[1]
            return { position = { x = h.x, y = h.y, z = h.z }, orientation = { x = h.qx, y = h.qy, z = h.qz, w = h.qw } }
        end,
        getLinearVelocity = function()
            local h = sim.history[1]
            return { x = h.vx, y = h.vy, z = h.vz }
        end,
        getAngularVelocity = function() return { x = 0, y = 0, z = 0 } end,
        getMass = function() return 10000 end,
    }
    os.clock = function() return sim.t end
end

function Sim:press(key, on)
    for relayKey, sides in pairs(self.cfg.input_map or {}) do
        if sides[key] then
            local name = self.cfg.peripherals[relayKey]
            self:relay(name).inp[sides[key]] = on and 15 or 0
        end
    end
end

function Sim:setProx(v)
    local p = self.cfg.proximity
    self:relay(self.cfg.peripherals[p.input_key]).inp[p.side] = v
end

-- --------------------------------------------------------------- outputs

function Sim:readOutputs()
    local o, cfg = {}, self.cfg
    for _, prop in ipairs({ "FL", "FR", "RL", "RR" }) do
        local m = cfg.output_map[prop]
        local r = self:relay(cfg.peripherals[m.relay])
        o[prop] = 15 - (r.out[m.speed] or 15)
        local f, b = (r.out[m.tilt_fwd] or 0) > 0, (r.out[m.tilt_bwd] or 0) > 0
        o[prop .. "_tilt"] = (f and 1 or 0) - (b and 1 or 0)
    end
    local m = cfg.output_map.REAR
    local r = self:relay(cfg.peripherals[m.relay])
    o.rear = 15 - (r.out[m.fw] or 15)
    o.rear_rev = (r.out[m.rev] or 0) > 0
    return o
end

-- --------------------------------------------------------------- physics

local POS = { FL = { 1, -1 }, FR = { 1, 1 }, RL = { -1, -1 }, RR = { -1, 1 } } -- fwd, right

function Sim:snapshot()
    local s = { x = self.pos.x, y = self.pos.y, z = self.pos.z,
        vx = self.vel.x, vy = self.vel.y, vz = self.vel.z,
        qx = self.q.x, qy = self.q.y, qz = self.q.z, qw = self.q.w }
    table.insert(self.history, s)
    while #self.history > self.p.delay_ticks + 1 do table.remove(self.history, 1) end
end

function Sim:height()
    return self.pos.y - self.p.ground
end

function Sim:step(dt)
    local p = self.p
    local o = self:readOutputs()
    local sub = 5
    local h = dt / sub
    for _ = 1, sub do
        local press = math.exp(-p.press_k * (self.pos.y - p.press_ref))
        local ux, uy, uz = rot(self.q, 0, 1, 0)
        local fx, fy, fz = rot(self.q, 1, 0, 0)
        local sign = self.lift_reverse and -1 or 1
        -- airflow term along the THRUST direction (reversed props push the
        -- other way, so falling helps them instead of starving them)
        local v_axial = sign * (self.vel.x * ux + self.vel.y * uy + self.vel.z * uz)
        local den = math.max(0.25, math.min(3, 1 - v_axial / p.airflow))
        local unit = p.g / (4 * p.hover) * press * den -- accel per prop unit

        local F = { 0, 0, 0 }      -- body frame (x fwd, y up, z right)
        local Tq = { 0, 0, 0 }     -- body torque per mass
        for prop, pos in pairs(POS) do
            self.prop[prop] = self.prop[prop] + (o[prop] - self.prop[prop]) * (h / (p.prop_tau + h))
            local target = o[prop .. "_tilt"] * p.tilt_deg
            local d = target - self.tilt[prop]
            local mv = p.tilt_rate * h
            self.tilt[prop] = self.tilt[prop] + math.max(-mv, math.min(mv, d))
            local th = math.rad(self.tilt[prop])
            local T = sign * self.prop[prop] * unit
            local f = { T * math.sin(th), T * math.cos(th), 0 }
            local r = { pos[1] * p.arm, 0, pos[2] * p.arm }
            F[1], F[2] = F[1] + f[1], F[2] + f[2]
            -- r x f
            Tq[1] = Tq[1] + (r[2] * f[3] - r[3] * f[2])
            Tq[2] = Tq[2] + (r[3] * f[1] - r[1] * f[3])
            Tq[3] = Tq[3] + (r[1] * f[2] - r[2] * f[1])
        end
        -- rear thruster at (-arm, rear_dy, rear_dz), force along +x
        local rear = o.rear * p.rear_accel * (o.rear_rev and -1 or 1)
        F[1] = F[1] + rear
        local rr = { -p.arm, p.rear_dy, p.rear_dz }
        Tq[2] = Tq[2] + (rr[3] * rear)
        Tq[3] = Tq[3] + (-rr[2] * rear)

        -- angular: body rates (x = roll axis, y = yaw axis, z = pitch axis)
        local w = self.w
        local I = p.inertia
        local dist = { math.rad(p.hull_roll), math.rad(-p.hull_yaw), math.rad(p.hull_pitch) }
        -- tail fin: sideways speed (body +z = right) turns the nose toward the
        -- motion; moving right turns right = negative body-y rotation
        local _, _, vz_body = irot(self.q, self.vel.x, self.vel.y, self.vel.z)
        dist[2] = dist[2] - math.rad(p.fin) * vz_body
        w.x = w.x + (Tq[1] / I[1] + dist[1] - p.ang_damp * w.x) * h
        w.y = w.y + (Tq[2] / I[2] + dist[2] - p.ang_damp * w.y) * h
        w.z = w.z + (Tq[3] / I[3] + dist[3] - p.ang_damp * w.z) * h

        -- linear
        local wx, wy, wz = rot(self.q, F[1], F[2], F[3])
        local ax = wx - p.drag * self.vel.x
        local ay = wy - p.g - p.drag * self.vel.y
        local az = wz - p.drag * self.vel.z
        self.vel.x = self.vel.x + ax * h
        self.vel.y = self.vel.y + ay * h
        self.vel.z = self.vel.z + az * h
        self.pos.x = self.pos.x + self.vel.x * h
        self.pos.y = self.pos.y + self.vel.y * h
        self.pos.z = self.pos.z + self.vel.z * h

        -- ground: rests on its gear, levels out, friction
        if self.pos.y <= p.ground then
            if self.vel.y < -0.05 then self.touch_v = -self.vel.y end
            self.pos.y = p.ground
            if self.vel.y < 0 then self.vel.y = 0 end
            self.vel.x, self.vel.z = self.vel.x * 0.8, self.vel.z * 0.8
            local _, ry = rot(self.q, 0, 0, 1)
            local _, fy2 = rot(self.q, 1, 0, 0)
            w.x = w.x * 0.7 + ry * 2
            w.z = w.z * 0.7 - fy2 * 2
            w.y = w.y * 0.8
            self.grounded = true
        else
            self.grounded = false
        end

        -- integrate orientation: q' = q * (0, w) / 2
        local dq = qmul(self.q, { w = 0, x = w.x, y = w.y, z = w.z })
        local q = self.q
        q.w, q.x, q.y, q.z = q.w + 0.5 * dq.w * h, q.x + 0.5 * dq.x * h, q.y + 0.5 * dq.y * h, q.z + 0.5 * dq.z * h
        local n = math.sqrt(q.w ^ 2 + q.x ^ 2 + q.y ^ 2 + q.z ^ 2)
        q.w, q.x, q.y, q.z = q.w / n, q.x / n, q.y / n, q.z / n
    end
    self.t = self.t + dt
    -- gear sensor: whole blocks above ground, high = close
    local hb = self:height()
    self:setProx(hb >= 15 and 0 or math.max(0, math.min(15, math.floor(15 - hb))))
    self:snapshot()
end

-- truth readouts (independent of the code under test)
function Sim:attitude()
    local fx, fy, fz = rot(self.q, 1, 0, 0)
    local ux, uy, uz = rot(self.q, 0, 1, 0)
    local rx, ry, rz = rot(self.q, 0, 0, 1)
    local hdg = math.deg(atan2(fx, -fz)) % 360
    local pitch = math.deg(atan2(fy, math.sqrt(fx * fx + fz * fz)))
    local roll = math.deg(atan2(-ry, uy))
    return hdg, pitch, roll, uy
end

return Sim
