-- mkconfig - ArtCorpOS ship config builder (run on the CC computer)
-- Interactive wizard that writes config/<ship>.lua for a new hull.
-- Wiring (which modem has which relay) is still done by `startup`.

local DEFAULT_LIMITS = {
    max_speed = 80, max_altitude = 320, min_altitude = 0,
    max_tilt = 15, max_climb_rate = 10, max_descent_rate = 5,
    hover_speed = 2, tilt_max = 12, hover_min_speed = 0, hover_max_speed = 15,
    hover_throttle = 6,
    land_descent_rate = 12.0, alt_step = 5,
    cruise_rear = 12, cruise_ramp = 8, cruise_speed_deadband = 1.5,
    landed_creep = 1,
}

local DEFAULT_PID = {
    -- g = 11 m/s² (Create Aeronautics): kp = ωn²·hover/g, kd = 2ζωn·hover/g
    altitude = { kp = 0.35, ki = 0.08, kd = 0.70, integral_limit = 8, output_limit = 7,
        d_on_measurement = true, integral_separation = 2.5 },
    pitch    = { kp = 2.0, ki = 0.0, kd = 1.0, integral_limit = 5, output_limit = 6 },
    roll     = { kp = 2.0, ki = 0.0, kd = 1.0, integral_limit = 5, output_limit = 6 },
    yaw      = { kp = 2.2, ki = 0.0, kd = 1.4, integral_limit = 5, output_limit = 15 },
    speed    = { kp = 0.15, ki = 0.04, kd = 0.0, integral_limit = 40, output_limit = 15 },
}

local function title(s)
    print("")
    print("========================================")
    print("  " .. s)
    print("========================================")
    print("")
end

local function ask(prompt, default)
    if default and default ~= "" then
        write(prompt .. " [" .. default .. "]: ")
    else
        write(prompt .. ": ")
    end
    local line = read()
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return default end
    return line
end

local function askYN(prompt, default)
    local hint = default and "Y/n" or "y/N"
    write(prompt .. " [" .. hint .. "]: ")
    local line = read()
    line = (line or ""):lower()
    if line == "" then return default end
    if line:sub(1, 1) == "y" then return true end
    if line:sub(1, 1) == "n" then return false end
    return default
end

local function askNum(prompt, default)
    local v = ask(prompt, tostring(default))
    local n = tonumber(v)
    if n then return n end
    return default
end

local function sanitizeSlot(raw)
    raw = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
    raw = raw:gsub("[^%w%-_]", "")
    if raw == "" then return nil end
    if #raw > 24 then raw = raw:sub(1, 24) end
    if raw:match("^assignments_") or raw:match("^pid_")
        or raw:match("^wp_") then return nil end
    return raw
end

local function q(s)
    return string.format("%q", tostring(s))
end

local function main()
print("ArtCorpOS config builder")
print("Writes config/<slot>.lua for a new ship.")
print("Afterwards run `startup` to wire peripherals.")

title("1) Identity")
local slot = sanitizeSlot(ask("Config slot name (file name, e.g. myship)", "myship"))
if not slot then
    print("Invalid slot name.")
    return
end
local display = ask("Ship display name", slot)
local version = ask("Config version (bump to force re-wizard)", "1.0")

title("2) Features (what the hull actually has)")
local feats = {
    hud = askYN("Pixel HUD monitor", true),
    gear = askYN("Landing gear", true),
    auto_land = askYN("Auto-landing (L key)", true),
    cruise_mode = askYN("Cruise mode (hover <-> cruise)", true),
    auto_tune = askYN("Altitude PID auto-tune", true),
    engine_auto_start = askYN("Engine auto-start on boot", false),
    clutch = askYN("Clutch (paired with engine relay)", false),
    fuel_level = askYN("Fuel gauge (reserved, leave off)", false),
    rear_reverse = askYN("REAR reverse face (auto-land fore/aft hold)", true),
}

local engine = nil
if feats.engine_auto_start or feats.clutch then
    title("3) Engine relay")
    print("Relay left = start pulse, right = clutch (while OS on).")
    print("Front/back = monitor tab UP/DOWN keys.")
    engine = {
        relay_key = "engine_relay",
        start_side = ask("Start side (left/right/front/back)", "left"),
        clutch_side = ask("Clutch side", "right"),
        start_seconds = askNum("Starter seconds", 3),
        clutch_delay = askNum("Clutch delay after starter (s)", 1),
        boot_seconds = askNum("Boot bar length (s)", 5),
        active = 15,
        inactive = 0,
    }
    if engine.start_side == "front" or engine.start_side == "back"
        or engine.clutch_side == "front" or engine.clutch_side == "back" then
        print("WARNING: front/back is shared with the tab UP/DOWN keys.")
    end
end

title("4) Computer offset from ship center")
print("Positive X = right, Y = up, Z = forward (blocks).")
local offset = {
    x = askNum("Offset X", 0),
    y = askNum("Offset Y", 6),
    z = askNum("Offset Z", 0),
}

title("5) Device names (targets for the startup wiring wizard)")
print("Use the network device name you will give each relay/monitor.")
local per = {
    input_1        = ask("Input relay 1 (WASD)", "relay_1"),
    input_2        = ask("Input relay 2 (Q/E/Space/Ctrl)", "relay_2"),
    aux_relay      = ask("Aux relay (shift/gear/prox)", "relay_aux"),
    engine_relay   = engine and ask("Engine relay", "relay_eng") or nil,
    output_FL      = ask("Prop FL relay", "relay_3"),
    output_FR      = ask("Prop FR relay", "relay_4"),
    output_RL      = ask("Prop RL relay", "relay_5"),
    output_RR      = ask("Prop RR relay", "relay_6"),
    output_REAR    = ask("Rear thruster relay", "relay_7"),
    main_monitor   = ask("HUD monitor", "main_monitor"),
    printer        = ask("Network printer name (blank = auto-find)", ""),
}
if not per.engine_relay then per.engine_relay = nil end
if per.printer == "" then per.printer = nil end

title("6) Output map (relay face per action)")
print("Default matches ArtCorpOS docs:")
print("  props: front/back = tilt, left/right = slow-down (inverted)")
print("  rear:  front = fw, back = bw")
local use_default_map = askYN("Use default output face map", true)
local output_map
if use_default_map then
    output_map = {
        FL   = { relay = per.output_FL, tilt_fwd = "front", tilt_bwd = "back", speed = "left" },
        FR   = { relay = per.output_FR, tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        RL   = { relay = per.output_RL, tilt_fwd = "front", tilt_bwd = "back", speed = "left" },
        RR   = { relay = per.output_RR, tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        REAR = { relay = per.output_REAR, fw = "front", bw = "back", rev = "top" },
    }
else
    local function prop(relay, speed_side)
        return {
            relay = relay,
            tilt_fwd = ask("  " .. relay .. " tilt-fwd side", "front"),
            tilt_bwd = ask("  " .. relay .. " tilt-bwd side", "back"),
            speed = ask("  " .. relay .. " slow-down side", speed_side),
        }
    end
    output_map = {
        FL   = prop(per.output_FL, "left"),
        FR   = prop(per.output_FR, "right"),
        RL   = prop(per.output_RL, "left"),
        RR   = prop(per.output_RR, "right"),
        REAR = {
            relay = per.output_REAR,
            fw = ask("  REAR fw side", "front"),
            bw = ask("  REAR bw side", "back"),
            rev = ask("  REAR reverse side", "top"),
        },
    }
end

title("7) Limits")
local limits = {}
for _, k in ipairs({
    "max_speed", "max_altitude", "tilt_max", "hover_throttle",
    "alt_step", "cruise_rear", "cruise_ramp",
    "landed_creep", "land_descent_rate",
}) do
    limits[k] = askNum("  " .. k, DEFAULT_LIMITS[k])
end
for k, v in pairs(DEFAULT_LIMITS) do
    if limits[k] == nil then limits[k] = v end
end

title("Write config")
local path = "config/" .. slot .. ".lua"
if fs.exists(path) then
    if not askYN("WARNING: " .. path .. " exists. Overwrite", false) then
        print("Aborted.")
        return
    end
end

local lines = {}
local function w(s) table.insert(lines, s) end

w("return {")
w("    name = " .. q(display) .. ",")
w("    version = " .. q(version) .. ",")
w("")
w("    computer_offset = { x = " .. offset.x .. ", y = " .. offset.y .. ", z = " .. offset.z .. " },")
w("")
w("    features = {")
    for _, k in ipairs({ "hud", "gear", "auto_land", "cruise_mode", "auto_tune",
        "engine_auto_start", "clutch", "fuel_level", "rear_reverse" }) do
        w("        " .. k .. " = " .. tostring(feats[k]) .. ",")
    end
w("    },")

if engine then
    w("")
    w("    engine = {")
    w("        relay_key = " .. q(engine.relay_key) .. ",")
    w("        start_side = " .. q(engine.start_side) .. ",")
    w("        clutch_side = " .. q(engine.clutch_side) .. ",")
    w("        start_seconds = " .. engine.start_seconds .. ",")
    w("        clutch_delay = " .. engine.clutch_delay .. ",")
    w("        boot_seconds = " .. engine.boot_seconds .. ",")
    w("        active = 15,")
    w("        inactive = 0,")
    w("    },")
end

w("")
w("    peripherals = {")
    for _, k in ipairs({ "input_1", "input_2", "aux_relay", "engine_relay",
        "output_FL", "output_FR", "output_RL", "output_RR", "output_REAR",
        "main_monitor", "printer" }) do
        if per[k] then
            w("        " .. k .. " = " .. q(per[k]) .. ",")
        end
    end
w("    },")
w("")
w("    input_map = {")
w("        input_1 = { W = \"front\", S = \"back\", A = \"left\", D = \"right\" },")
w("        input_2 = { Q = \"left\", E = \"right\", SPACE = \"front\", CTRL = \"back\" },")
w("        aux_relay = { SHIFT = \"left\", PROX = \"back\" },")
if engine then
    w("        engine_relay = { UP = \"front\", DOWN = \"back\" },")
end
w("    },")
w("")
w("    gear_output = { relay = \"aux_relay\", side = \"front\", deploy = 15, retract = 0 },")
w("    proximity = { input_key = \"aux_relay\", side = \"back\", landed_threshold = 15,")
w("        gear_deploy_threshold = 1, max_blocks = 15, gear_settle_ticks = 20 },")
w("")
w("    output_map = {")
    for _, k in ipairs({ "FL", "FR", "RL", "RR", "REAR" }) do
        local m = output_map[k]
        if k == "REAR" then
            w(string.format("        REAR = { relay = %q, fw = %q, bw = %q },",
                m.relay, m.fw, m.bw))
        else
            w(string.format("        %s   = { relay = %q, tilt_fwd = %q, tilt_bwd = %q, speed = %q },",
                k, m.relay, m.tilt_fwd, m.tilt_bwd, m.speed))
        end
    end
w("    },")
w("")
w("    propellers = {")
w("        FL = { x = -3, y = 0, z = 3 },")
w("        FR = { x = 3,  y = 0, z = 3 },")
w("        RL = { x = -3, y = 0, z = -3 },")
w("        RR = { x = 3,  y = 0, z = -3 },")
w("    },")
w("")
w("    limits = {")
    local keys = {}
    for k in pairs(limits) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        w("        " .. k .. " = " .. tostring(limits[k]) .. ",")
    end
w("    },")
w("")
w("    pid = {")
    for _, k in ipairs({ "altitude", "pitch", "roll", "yaw", "speed" }) do
        local p = DEFAULT_PID[k]
        local extra = ""
        if p.d_on_measurement then
            extra = extra .. ", d_on_measurement = true"
        end
        if p.integral_separation then
            extra = extra .. ", integral_separation = " .. tostring(p.integral_separation)
        end
        w(string.format("        %-8s = { kp = %s, ki = %s, kd = %s, integral_limit = %s, output_limit = %s%s },",
            k, p.kp, p.ki, p.kd, p.integral_limit, p.output_limit, extra))
    end
w("    },")
w("")
w("    signal = { max = 15, min = 0 },")
    -- engine_relay is only optional when the ship actually uses it;
    -- listing it unconditionally made startup block on a missing peripheral
    local optional = { "aux_relay" }
    if engine then table.insert(optional, "engine_relay") end
    if per.printer then table.insert(optional, "printer") end
    local quoted = {}
    for _, name in ipairs(optional) do table.insert(quoted, "\"" .. name .. "\"") end
    w("    optional_peripherals = { " .. table.concat(quoted, ", ") .. " },")
w("}")

if not fs.exists("config") then
    fs.makeDir("config")
end
local h = fs.open(path, "w")
if not h then
    print("ERROR: cannot write " .. path)
    return
end
h.write(table.concat(lines, "\n") .. "\n")
h.close()

print("")
print("Wrote " .. path)
print("")
print("Next steps:")
print("  1. Edit ship.lua  -> profile = \"" .. slot .. "\"")
print("  2. Run `startup`  -> wire relays for this ship")
print("")
end

main()
