local Hardware = {}
local config = nil
local devices = {}

-- Last value actually sent per relay pin ("relayName:side"). applyOutputs
-- runs at 20 Hz and most channels are steady, so identical writes are
-- skipped — this is the per-tick peripheral (main-thread task) budget of
-- the whole control loop. Invalidated whenever devices are re-wrapped.
local out_cache = {}

function Hardware.invalidateOutputs()
    out_cache = {}
end

function Hardware.init(cfg)
    config = cfg
end

function Hardware.scan()
    local found = {}

    local modem = peripheral.find("modem", function(name, m)
        return not m.isWireless()
    end)
    if modem then
        local names = modem.getNamesRemote()
        for _, name in ipairs(names) do
            local devType = modem.getTypeRemote(name)
            table.insert(found, { name = name, type = devType, via = "wired" })
        end
    end

    local wireless = peripheral.find("modem", function(name, m)
        return m.isWireless()
    end)
    if wireless then
        local types_to_find = { "monitor", "speaker" }
        for _, ptype in ipairs(types_to_find) do
            local dev = peripheral.find(ptype)
            if dev then
                local wname = peripheral.getName(dev)
                if wname then
                    local already = false
                    for _, d in ipairs(found) do
                        if d.name == wname then already = true break end
                    end
                    if not already then
                        table.insert(found, { name = wname, type = ptype, via = "wireless" })
                    end
                end
            end
        end
    end

    if #found == 0 then
        return nil, "No peripherals found (wired or wireless)"
    end
    return found
end

function Hardware.connect()
    local connected = {}
    local missing = {}

    for key, name in pairs(config.peripherals) do
        if name and name ~= "" then
            local wrapped = peripheral.wrap(name)
            if wrapped then
                connected[key] = wrapped
                print("  [OK] " .. key .. " -> " .. name)
            else
                table.insert(missing, key .. " (" .. tostring(name) .. ")")
                print("  [FAIL] " .. key .. " -> " .. tostring(name))
            end
        end
    end

    devices = connected
    out_cache = {} -- re-wrapped peripherals may have missed state changes
    return connected, missing
end

function Hardware.getDevice(key)
    return devices[key]
end

function Hardware.hasFeature(name)
    if not config or not config.features then return true end
    local v = config.features[name]
    if v == nil then return true end
    return not not v
end

local function engineCfg()
    return config and config.engine or nil
end

function Hardware.setEngineStarter(active)
    local e = engineCfg()
    if not e or not Hardware.hasFeature("engine_auto_start") then return false end
    local relay = devices[e.relay_key or "engine_relay"]
    if not relay then return false end
    local value = active and (e.active or 15) or (e.inactive or 0)
    return pcall(function()
        relay.setAnalogOutput(e.start_side or "left", value)
    end)
end

function Hardware.setClutch(engaged)
    local e = engineCfg()
    if not e or not Hardware.hasFeature("clutch") then return false end
    local relay = devices[e.relay_key or "engine_relay"]
    if not relay then return false end
    local value = engaged and (e.active or 15) or (e.inactive or 0)
    return pcall(function()
        relay.setAnalogOutput(e.clutch_side or "right", value)
    end)
end

function Hardware.engineOutputsOff()
    Hardware.setEngineStarter(false)
    Hardware.setClutch(false)
end

function Hardware.readInputs()
    local keys = {}
    for relayKey, sides in pairs(config.input_map or {}) do
        local relay = devices[relayKey]
        if relay then
            for key, side in pairs(sides) do
                -- pcall(fn, arg) instead of a per-channel closure: this runs
                -- every 20 Hz tick and allocates nothing per call
                local success, val = pcall(relay.getAnalogInput, side)
                keys[key] = success and val or 0
            end
        end
    end
    return keys
end

function Hardware.isKeyPressed(key)
    local keys = Hardware.readInputs()
    return (keys[key] or 0) > 0
end

function Hardware.getProximity()
    local prox = config.proximity
    if not prox then return 0 end
    local relay = devices[prox.input_key]
    if not relay then return 0 end
    local ok, val = pcall(relay.getAnalogInput, prox.side)
    if not ok or type(val) ~= "number" then return 0 end
    return math.max(0, math.min(15, math.floor(val)))
end

function Hardware.setGear(deployed)
    local g = config.gear_output
    if not g then return false end
    local relay = devices[g.relay]
    if not relay then return false end
    local value = deployed and (g.deploy or 15) or (g.retract or 0)
    local cache_key = g.relay .. ":" .. g.side
    if out_cache[cache_key] == value then return true end
    local ok = pcall(relay.setAnalogOutput, g.side, value)
    if ok then out_cache[cache_key] = value end
    return ok
end

function Hardware.setPropellerOutput(prop, side, value)
    local mapping = (config.output_map or {})[prop]
    if not mapping then return false end

    local relay = devices[mapping.relay]
    if not relay then return false end

    local relaySide = mapping[side]
    if not relaySide then return false end

    value = math.max(0, math.min(15, math.floor(value + 0.5)))

    -- Slow-downer: engine is always ~256 RPM; higher redstone = more braking.
    -- Flight layer uses thrust 0..15 (0 = stopped). Invert at the wire.
    if side == "speed" then
        value = 15 - value
    end

    -- Steady-state skip: only touch the peripheral when the pin actually
    -- changes (failures are never cached, so they retry next tick)
    local cache_key = mapping.relay .. ":" .. relaySide
    if out_cache[cache_key] == value then return true end
    local success = pcall(relay.setAnalogOutput, relaySide, value)
    if success then out_cache[cache_key] = value end

    return success
end

function Hardware.setRearOutput(direction, value)
    local mapping = (config.output_map or {}).REAR
    if not mapping then return false end

    local relay = devices[mapping.relay]
    if not relay then return false end

    local relaySide = mapping[direction]
    if not relaySide then return false end

    value = math.max(0, math.min(15, math.floor(value + 0.5)))

    -- Same slow-down wiring as main prop "speed": higher redstone = more
    -- braking (15 = stopped). Flight layer uses thrust 0..15 (0 = stopped).
    -- Invert at the wire: more speed = less redstone signal.
    value = 15 - value

    local cache_key = mapping.relay .. ":" .. relaySide
    if out_cache[cache_key] == value then return true end
    local success = pcall(relay.setAnalogOutput, relaySide, value)
    if success then out_cache[cache_key] = value end

    return success
end

-- REAR relay reverse face (mapping.rev, e.g. top): reverses the rear unit's
-- thrust direction for the auto-land fore/aft hold.
function Hardware.setRearReverse(on)
    local mapping = (config.output_map or {}).REAR
    if not mapping or not mapping.rev then return false end
    local relay = devices[mapping.relay]
    if not relay then return false end
    local value = on and 15 or 0
    local cache_key = mapping.relay .. ":" .. mapping.rev
    if out_cache[cache_key] == value then return true end
    local ok = pcall(relay.setAnalogOutput, mapping.rev, value)
    if ok then out_cache[cache_key] = value end
    return ok
end

-- Redstone link at the left of the main computer (direct computer redstone,
-- not a relay peripheral): reverses ALL lift propellers for the auto-unflip
-- sequence.
local REVERSE_SIDE = "left"

function Hardware.setLiftReverse(on)
    pcall(function()
        redstone.setOutput(REVERSE_SIDE, on == true)
    end)
end

function Hardware.cutAllOutputs()
    -- Route through the cached setters (same wire values: thrust 0 -> signal
    -- 15) so the every-tick power-off/estop hammer becomes a steady-state
    -- no-op once the pins are at their cut values.
    for prop, mapping in pairs(config.output_map or {}) do
        if prop == "REAR" then
            if mapping.fw then Hardware.setRearOutput("fw", 0) end
            if mapping.bw then Hardware.setRearOutput("bw", 0) end
        else
            if mapping.tilt_fwd then Hardware.setPropellerOutput(prop, "tilt_fwd", 0) end
            if mapping.tilt_bwd then Hardware.setPropellerOutput(prop, "tilt_bwd", 0) end
            -- Speed is inverted slow-down: thrust 0 -> device signal 15
            if mapping.speed then Hardware.setPropellerOutput(prop, "speed", 0) end
        end
    end
    -- Propulsion safety: never leave starter high from a cut
    Hardware.setEngineStarter(false)
    -- Reverse links must never survive a safety cut either
    Hardware.setLiftReverse(false)
    Hardware.setRearReverse(false)
end

function Hardware.setAllSpeed(value)
    for _, prop in ipairs({"FL", "FR", "RL", "RR"}) do
        Hardware.setPropellerOutput(prop, "speed", value)
    end
end

function Hardware.setAllTilt(value)
    for _, prop in ipairs({"FL", "FR", "RL", "RR"}) do
        if value >= 0 then
            Hardware.setPropellerOutput(prop, "tilt_fwd", value)
            Hardware.setPropellerOutput(prop, "tilt_bwd", 0)
        else
            Hardware.setPropellerOutput(prop, "tilt_fwd", 0)
            Hardware.setPropellerOutput(prop, "tilt_bwd", math.abs(value))
        end
    end
end

-- Body frame (Create/Sable): +X east, +Y up, +Z south.
-- Ship local X = LONGITUDINAL axis (craft built pointing east); local Z = right.
-- toEuler docs say (pitch, yaw, roll), but its YXZ decomposition against this
-- ship's frame yields: slot1 = rotation about local X = the ship's ROLL
-- (right-down positive), slot3 = rotation about local Z = the ship's PITCH
-- (nose-UP positive), slot2 = yaw (turning left positive). Heading-independent.
-- Output convention: pitch + = nose down, roll + = right down (MC-style).
local function quatAttitude(q)
    if type(q) ~= "table" then
        return 0, 0, 0
    end

    if type(q.toEuler) == "function" then
        local ok, p, y, r = pcall(q.toEuler, q)
        if ok and type(p) == "number" and type(y) == "number" and type(r) == "number" then
            local norm = math.sqrt(p * p + y * y + r * r)
            if norm ~= norm or norm == math.huge then
                return 0, 0, 0
            end
            return -math.deg(r), math.deg(p), math.deg(y)
        end
    end

    local x, y, z, w
    if type(q.v) == "table" and q.a ~= nil then
        x, y, z, w = q.v.x, q.v.y, q.v.z, q.a
    else
        x, y, z, w = q.x, q.y, q.z, q.w
    end
    if type(x) ~= "number" or type(y) ~= "number"
        or type(z) ~= "number" or type(w) ~= "number" then
        return 0, 0, 0
    end

    local singularity = 2 * (y * z - x * w)
    local pitch, yaw, roll
    if singularity > 0.9999 then
        pitch = -math.pi / 2
        yaw = math.atan2(-2 * (x * y - z * w), 2 * (w * w + x * x) - 1)
        roll = 0
    elseif singularity < -0.9999 then
        pitch = math.pi / 2
        yaw = -math.atan2(-2 * (x * y - z * w), 2 * (w * w + x * x) - 1)
        roll = 0
    else
        pitch = math.asin(-singularity)
        yaw = math.atan2(2 * (x * z + y * w), 2 * (w * w + z * z) - 1)
        roll = math.atan2(2 * (x * y + z * w), 2 * (w * w + y * y) - 1)
    end
    -- Same mapping as the toEuler path above (local X = longitudinal axis).
    return -math.deg(roll), math.deg(pitch), math.deg(yaw)
end

-- Ship nose direction in world space: local +X rotated by the orientation
-- quaternion (same field shapes as quatAttitude). Used to project world
-- velocity onto the fore/aft axis without yaw-convention guessing.
local function quatForward(q)
    if type(q) ~= "table" then return nil end
    local x, y, z, w
    if type(q.v) == "table" and q.a ~= nil then
        x, y, z, w = q.v.x, q.v.y, q.v.z, q.a
    else
        x, y, z, w = q.x, q.y, q.z, q.w
    end
    if type(x) ~= "number" or type(y) ~= "number"
        or type(z) ~= "number" or type(w) ~= "number" then
        return nil
    end
    -- v' = v + 2w(u×v) + 2u×(u×v) with v = (1,0,0), u = (x,y,z)
    return {
        x = 1 - 2 * (y * y + z * z),
        y = 2 * (w * z + x * y),
        z = 2 * (x * z - w * y),
    }
end

function Hardware.getShipState()
    local state = {
        position = { x = 0, y = 0, z = 0 },
        velocity = { x = 0, y = 0, z = 0 },
        angularVelocity = { x = 0, y = 0, z = 0 },
        forward = { x = 0, y = 0, z = 0 },
        pitch = 0,
        roll = 0,
        yaw = 0,
        mass = 0,
        altitude = 0,
        speed = 0,
        climb_rate = 0,
    }

    local ok, err = pcall(function()
        local pose = sublevel.getLogicalPose()
        if pose and pose.position then
            state.position = { x = pose.position.x, y = pose.position.y, z = pose.position.z }
            state.altitude = pose.position.y
        end

        if pose and pose.orientation then
            local pitch, roll, yaw = quatAttitude(pose.orientation)
            state.pitch = pitch
            state.roll = roll
            state.yaw = yaw
            local fwd = quatForward(pose.orientation)
            if fwd then state.forward = fwd end
        end

        local vel = sublevel.getLinearVelocity()
        if vel then
            state.velocity = { x = vel.x, y = vel.y, z = vel.z }
            state.speed = math.sqrt(vel.x * vel.x + vel.z * vel.z)
            state.climb_rate = vel.y
        end

        local angVel = sublevel.getAngularVelocity()
        if angVel then
            state.angularVelocity = { x = angVel.x or 0, y = angVel.y or 0, z = angVel.z or 0 }
        end

        state.mass = sublevel.getMass() or 0
    end)

    if not ok then
        state.sable_error = err
    end

    return state
end

function Hardware.hasSable()
    return type(sublevel) == "table" and type(sublevel.getLogicalPose) == "function"
end

function Hardware.playNote(instrument, volume, pitch)
    local spk = devices.speaker
    if spk then
        pcall(function()
            spk.playNote(instrument, volume or 1, pitch or 1)
        end)
    end
end

return Hardware
