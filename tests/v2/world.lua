-- Test harness: the real v2 Flight/HW/AP code flying tests/v2/sim.lua.
package.path = "./v2/lib/?.lua;./tests/v2/?.lua;" .. package.path
for _, m in ipairs({ "util", "ctl", "est", "hw", "flight", "ap", "config", "sim" }) do
    package.loaded[m] = nil
end

local Sim = require("sim")
local HW = require("hw")
local Flight = require("flight")
local AP = require("ap")
local Config = require("config")

local World = {}
World.__index = World

local DT = 0.05

function World.new(opts)
    opts = opts or {}
    local self = setmetatable({}, World)
    local ship = dofile("config/atlas.lua")
    local tune = dofile("v2/tune.lua")
    for k, v in pairs(opts.tune or {}) do
        for k2, v2 in pairs(v) do tune[k][k2] = v2 end
    end
    Config.build(ship, tune)
    self.ship, self.tune = ship, tune
    self.sim = Sim.new(opts.sim or {})
    self.sim:install(ship)
    HW.init(ship)
    HW.connect()
    self.sim:step(0) -- publish the starting sensor value
    self.fl = Flight.new(tune, HW, ship)
    self.fl:boot()
    self.t = 0
    self.trace = {}
    return self
end

function World:tick()
    self.fl:update(DT, HW.inputs())
    self.sim:step(DT)
    self.t = self.t + DT
end

-- run for `secs`, calling fn(world) each tick; fn returning true stops early
function World:run(secs, fn)
    local n = math.floor(secs / DT + 0.5)
    for _ = 1, n do
        self:tick()
        if fn and fn(self) then return true end
    end
    return false
end

function World:tap(key, secs)
    self.sim:press(key, true)
    self:run(secs or 0.1)
    self.sim:press(key, false)
end

-- Put the ship in the air at `alt`, level, settled, flying.
function World:airborne(alt, heading)
    local s = self.sim
    s.pos.y = alt
    s.q = require("sim").quatFromHeading(heading or 0)
    s.history = {}
    for _ = 1, 3 do s:snapshot() end
    local hb = s:height()
    s:setProx(hb >= 15 and 0 or math.floor(15 - hb))
    for _, p in ipairs({ "FL", "FR", "RL", "RR" }) do
        s.prop[p] = self.tune.ship.hover_throttle / math.exp(-0.004 * (alt - 63))
    end
    self.fl:boot("air")
    return self
end

function World:startAP(wp)
    self.fl.ap = AP.new(self.fl, wp)
    return self.fl.ap
end

function World:truth()
    local h, p, r, uy = self.sim:attitude()
    return { heading = h, pitch = p, roll = r, up = uy, alt = self.sim.pos.y,
        x = self.sim.pos.x, z = self.sim.pos.z, vy = self.sim.vel.y,
        speed = math.sqrt(self.sim.vel.x ^ 2 + self.sim.vel.z ^ 2) }
end

return World
