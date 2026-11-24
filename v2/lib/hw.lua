-- v2 hardware layer: relays, sensors, and the CC:Sable ship state.
--
-- Wire conventions (same physical ship as the original OS):
--   * prop speed + rear level: inverted slow-down links, signal = 15 - thrust
--   * prop tilt: one face per direction; ANY signal = the full 25 deg tilt,
--     so v2 treats tilt as on/off and writes 15 or 0
--   * rear reverse, gear, starter, clutch: plain on/off
--   * lift reverse: the computer's own left face (auto-unflip)
-- Every write is cached per pin and skipped when unchanged.
local U = require("util")

local HW = {}

local cfg, dev, cache = nil, {}, {}
local PROPS = { "FL", "FR", "RL", "RR" }
HW.PROPS = PROPS

function HW.init(ship)
    cfg = ship
end

function HW.connect()
    dev, cache = {}, {}
    local missing = {}
    for key, name in pairs(cfg.peripherals or {}) do
        -- kbd_computer is a computer ID, not a peripheral name
        if type(name) == "string" and name ~= "" and key ~= "kbd_computer" and not name:match("^%d+$") then
            local p = peripheral.wrap(name)
            if p then dev[key] = p else missing[#missing + 1] = key end
        end
    end
    table.sort(missing)
    return missing
end

function HW.device(key) return dev[key] end

function HW.feature(name)
    local f = cfg.features or {}
    if f[name] == nil then return true end
    return not not f[name]
end

-- Call timing (debug): how long each kind of peripheral call keeps the
-- control loop waiting. Real milliseconds (os.epoch "utc"); main.lua reads
-- and resets HW.stats every tick. A call that waits for the game's main
-- thread costs a whole game tick (50 ms) of loop time.
local function now_ms()
    if os.epoch then return os.epoch("utc") end
    return os.clock() * 1000
end
HW.now_ms = now_ms
HW.stats = {}
function HW.resetStats()
    HW.stats = { pose_ms = 0, vel_ms = 0, mass_ms = 0, in_ms = 0, in_n = 0, out_ms = 0, out_n = 0 }
end
HW.resetStats()
local function stat(k, ms, nk)
    local st = HW.stats
    st[k] = (st[k] or 0) + ms
    if nk then st[nk] = (st[nk] or 0) + 1 end
end

local function write(relayKey, side, value)
    local r = dev[relayKey]
    if not r or not side then return false end
    local ck = relayKey .. ":" .. side
    if cache[ck] == value then return true end
    local t0 = now_ms()
    local ok = pcall(r.setAnalogOutput, side, value)
    stat("out_ms", now_ms() - t0, "out_n")
    if ok then cache[ck] = value end
    return ok
end

local function level(v)
    return U.clamp(math.floor((v or 0) + 0.5), 0, 15)
end

-- thrust 0..15 for a lift prop
function HW.setProp(prop, thrust)
    local m = (cfg.output_map or {})[prop]
    if not m then return end
    write(m.relay, m.speed, 15 - level(thrust))
end

-- tilt -1 (back) / 0 / +1 (forward)
function HW.setTilt(prop, t)
    local m = (cfg.output_map or {})[prop]
    if not m then return end
    write(m.relay, m.tilt_fwd, t > 0 and 15 or 0)
    write(m.relay, m.tilt_bwd, t < 0 and 15 or 0)
end

function HW.setRear(lvl, reverse)
    local m = (cfg.output_map or {}).REAR
    if not m then return end
    local s = 15 - level(lvl)
    write(m.relay, m.fw, s)
    write(m.relay, m.bw, s)
    if m.rev and HW.feature("rear_reverse") then
        write(m.relay, m.rev, reverse and 15 or 0)
    end
end

function HW.setGear(down)
    local g = cfg.gear_output
    if not g then return end
    write(g.relay, g.side, down and (g.deploy or 15) or (g.retract or 0))
end

local function engine() return cfg.engine or {} end

function HW.setStarter(on)
    if not HW.feature("engine_auto_start") then return end
    local e = engine()
    write(e.relay_key or "engine_relay", e.start_side or "left",
        on and (e.active or 15) or (e.inactive or 0))
end

function HW.setClutch(on)
    if not HW.feature("clutch") then return end
    local e = engine()
    write(e.relay_key or "engine_relay", e.clutch_side or "right",
        on and (e.active or 15) or (e.inactive or 0))
end

function HW.setLiftReverse(on)
    local v = on == true
    if cache["computer:left"] == v then return end
    if pcall(redstone.setOutput, "left", v) then cache["computer:left"] = v end
end

-- Every prop stopped and untilted, rear off, reverses off. Clutch untouched.
function HW.cutAll()
    for _, p in ipairs(PROPS) do
        HW.setProp(p, 0)
        HW.setTilt(p, 0)
    end
    HW.setRear(0, false)
    HW.setLiftReverse(false)
    HW.setStarter(false)
end

-- Pilot inputs: { W=0..15, S=..., SPACE=..., ... } from the input relays.
function HW.inputs()
    local keys = {}
    for relayKey, sides in pairs(cfg.input_map or {}) do
        local r = dev[relayKey]
        for key, side in pairs(sides) do
            local v = 0
            if r then
                local t0 = now_ms()
                local ok, val = pcall(r.getAnalogInput, side)
                stat("in_ms", now_ms() - t0, "in_n")
                if ok and type(val) == "number" then v = val end
            end
            keys[key] = v
        end
    end
    return keys
end

function HW.proximity()
    local p = cfg.proximity
    if not p then return 0 end
    local r = dev[p.input_key]
    if not r then return 0 end
    local t0 = now_ms()
    local ok, v = pcall(r.getAnalogInput, p.side)
    stat("in_ms", now_ms() - t0, "in_n")
    if not ok or type(v) ~= "number" then return 0 end
    return U.clamp(math.floor(v), 0, 15)
end

-- ---------------------------------------------------------------- Sable

local function quatParts(q)
    if type(q) ~= "table" then return nil end
    if type(q.v) == "table" and q.a ~= nil then
        return q.v.x, q.v.y, q.v.z, q.a
    end
    return q.x, q.y, q.z, q.w
end

-- Rotate vector v by unit quaternion (x,y,z,w): v' = q v q*
local function rotate(x, y, z, w, vx, vy, vz)
    local tx = 2 * (y * vz - z * vy)
    local ty = 2 * (z * vx - x * vz)
    local tz = 2 * (x * vy - y * vx)
    return vx + w * tx + (y * tz - z * ty),
        vy + w * ty + (z * tx - x * tz),
        vz + w * tz + (x * ty - y * tx)
end
HW._rotate = rotate

-- Raw ship state. The ship's local axes (as built): +X nose, +Y up, +Z right.
-- Returned as world-space unit vectors so nothing downstream depends on any
-- Euler convention.
local mass, mass_n = 0, 0
function HW.ship()
    local s = { ok = false }
    local ok, err = pcall(function()
        local t0 = now_ms()
        local pose = sublevel.getLogicalPose()
        stat("pose_ms", now_ms() - t0)
        local p = pose.position
        s.x, s.y, s.z = p.x, p.y, p.z
        local qx, qy, qz, qw = quatParts(pose.orientation)
        if not qw then error("no orientation") end
        local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
        if n < 1e-9 then error("bad orientation") end
        qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
        s.fx, s.fy, s.fz = rotate(qx, qy, qz, qw, 1, 0, 0)
        s.ux, s.uy, s.uz = rotate(qx, qy, qz, qw, 0, 1, 0)
        s.rx, s.ry, s.rz = rotate(qx, qy, qz, qw, 0, 0, 1)
        t0 = now_ms()
        local v = sublevel.getLinearVelocity()
        stat("vel_ms", now_ms() - t0)
        s.vx, s.vy, s.vz = v.x or 0, v.y or 0, v.z or 0
        -- mass is not used for control: read it once in a while only (each
        -- Sable call can cost the loop a game tick)
        mass_n = mass_n - 1
        if mass_n <= 0 then
            mass_n = 200
            t0 = now_ms()
            local okm, m = pcall(sublevel.getMass)
            stat("mass_ms", now_ms() - t0)
            if okm then mass = m end
        end
        s.mass = mass
        s.ok = true
    end)
    if not ok then s.err = tostring(err) end
    return s
end

return HW
