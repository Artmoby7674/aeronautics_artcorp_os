-- First launch: the computer has no wired ship (no slot in config/, or the
-- chosen slot has no assignments file). Instead of stopping with "no ship
-- config", the cockpit monitor walks the player through it:
--
--   WELCOME   IMPORT FROM DISK (a ship saved with SAVE DISK; restarts on it)
--             or SET UP THIS SHIP
--   WIRING    one role of the template (config/atlas.lua peripherals) at a
--             time: what it does, the matching peripherals actually on the
--             network to tap, TEST to find out which one it is, BACK
--   GUIDE     first-flight cards: water valve, START, TAKE OFF, hover
--             hands-off until calibrated (skippable)
--
-- The new slot (template copy + assignments + v2/data/slot) is written only
-- when the last role is picked, so backing out never leaves half a ship.
-- Ob.run returns "ready" (main carries on with the new config), "reboot"
-- (a disk was loaded) or "stop" (terminate).
local U = require("util")
local Config = require("config")
local D = require("draw")
local UI = require("ui")
local V = require("version")
local ShipDisk = require("shipdisk")

local Ob = {}

local TEMPLATE = "atlas" -- config/atlas.lua: the template the installer ships
Ob.TEMPLATE = TEMPLATE

-- What each role does, in the pilot's words. kind: "output" (TEST flips one
-- of its faces for 2 s), "input" (DETECT watches for a key press),
-- "monitor" (SHOW writes on that monitor).
local ROLES = {
    input_1 = { label = "KEYS W A S D", kind = "input",
        desc = "READS THE TYPEWRITER'S W, A, S AND D KEYS: FORWARD, BACK AND TURNING." },
    input_2 = { label = "KEYS Q E SPACE CTRL", kind = "input",
        desc = "READS THE TYPEWRITER'S Q, E, SPACE AND CTRL KEYS: SIDEWAYS, UP AND DOWN." },
    aux_relay = { label = "AUX RELAY", kind = "output", watch = "THE LANDING GEAR",
        desc = "MOVES THE LANDING GEAR, READS THE GROUND SENSOR AND THE SHIFT KEY." },
    engine_relay = { label = "ENGINE RELAY", kind = "output", watch = "THE CLUTCH",
        desc = "STARTS THE STEAM ENGINE (STARTER) AND COUPLES IT TO THE PROPS (CLUTCH)." },
    output_FL = { label = "FRONT-LEFT PROP", kind = "output", watch = "THE FRONT-LEFT PROP TILT",
        desc = "SETS THE FRONT-LEFT PROPELLER'S SPEED AND TILTS IT." },
    output_FR = { label = "FRONT-RIGHT PROP", kind = "output", watch = "THE FRONT-RIGHT PROP TILT",
        desc = "SETS THE FRONT-RIGHT PROPELLER'S SPEED AND TILTS IT." },
    output_RL = { label = "REAR-LEFT PROP", kind = "output", watch = "THE REAR-LEFT PROP TILT",
        desc = "SETS THE REAR-LEFT PROPELLER'S SPEED AND TILTS IT." },
    output_RR = { label = "REAR-RIGHT PROP", kind = "output", watch = "THE REAR-RIGHT PROP TILT",
        desc = "SETS THE REAR-RIGHT PROPELLER'S SPEED AND TILTS IT." },
    output_REAR = { label = "REAR THRUSTER", kind = "output", watch = "THE REAR THRUSTER'S REVERSE",
        desc = "PUSHES THE SHIP FORWARD OR BACK (CRUISE AND AUTOPILOT), WITH A REVERSE SWITCH." },
    main_monitor = { label = "COCKPIT SCREEN", kind = "monitor", type = "monitor",
        desc = "THE TOUCHSCREEN THE PILOT USES: USUALLY THE ONE YOU ARE TAPPING NOW." },
}
local ORDER = { "input_1", "input_2", "aux_relay", "engine_relay", "output_FL", "output_FR",
    "output_RL", "output_RR", "output_REAR", "main_monitor" }

local GUIDE = {
    { title = "WATER VALVE", text = "BEFORE EVERY START, OPEN THE STEAM ENGINE'S WATER INPUT VALVE BY HAND. "
        .. "THE OS CAN'T DO THIS FOR YOU: WITHOUT WATER THE ENGINE GIVES NO POWER." },
    { title = "START ENGINES", text = "TAP START ENGINES ON THE START SCREEN (OR PRESS SPACE ON THE "
        .. "TYPEWRITER). THE STARTER RUNS, THEN THE CLUTCH COUPLES THE PROPS." },
    { title = "TAKE OFF", text = "ON THE CTRL TAB TAP TAKE OFF (OR PRESS SPACE). THE SHIP CLIMBS A FEW "
        .. "BLOCKS AND HOLDS ITS HEIGHT." },
    { title = "HOVER HANDS-OFF", text = "LET GO OF EVERY KEY AND JUST HOVER. THE SHIP LEARNS ITS TRIMS: "
        .. "WAIT UNTIL SHIP > CALIBRATION SAYS DONE (FROZEN). THEN SHE'S YOURS." },
}
Ob.GUIDE = GUIDE

local ROWS = 6 -- candidate rows on screen (UI:obRole)

-- Does this computer need the first-launch setup?
function Ob.needed(root)
    local slot = Config.pickSlot(root)
    if not slot then return true end
    return not fs.exists("config/assignments_" .. slot .. ".lua")
end

local function isType(name, want)
    if peripheral.hasType then
        local ok, yes = pcall(peripheral.hasType, name, want)
        if ok and yes then return true end
    end
    local t = peripheral.getType(name)
    if t == want then return true end
    -- relays from other mods / versions still say "relay" in their type
    return want == "redstone_relay" and type(t) == "string" and t:find("relay") ~= nil
end

-- The roles the template needs, in wiring order, with what TEST does.
local function buildRoles(tpl)
    local keys = {}
    for k, v in pairs(tpl.peripherals or {}) do
        if type(v) == "string" and v ~= "" then keys[#keys + 1] = k end
    end
    local rank = {}
    for i, k in ipairs(ORDER) do rank[k] = i end
    table.sort(keys, function(a, b)
        local ra, rb = rank[a] or 99, rank[b] or 99
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    local optional = {}
    for _, k in ipairs(tpl.optional_peripherals or {}) do optional[k] = true end
    local out = {}
    for _, k in ipairs(keys) do
        local info = ROLES[k] or { label = k:upper():gsub("_", " "), kind = "output",
            desc = "A DEVICE THE SHIP CONFIG CALLS " .. k:upper() .. "." }
        local r = { key = k, label = info.label, desc = info.desc, kind = info.kind,
            type = info.type or "redstone_relay", optional = optional[k], watch = info.watch }
        if r.kind == "output" then
            -- the face TEST flips: one whose effect the player can see
            local prop = k:match("^output_(.+)$")
            local om = prop and tpl.output_map and tpl.output_map[prop]
            if om then r.face = om.tilt_fwd or om.rev or om.fw
            elseif tpl.gear_output and tpl.gear_output.relay == k then r.face = tpl.gear_output.side
            elseif tpl.engine and (tpl.engine.relay_key or "engine_relay") == k then r.face = tpl.engine.clutch_side end
            if r.face then r.test_label = "TEST" end
        elseif r.kind == "input" then
            r.faces = {}
            for _, side in pairs((tpl.input_map or {})[k] or {}) do r.faces[#r.faces + 1] = side end
            table.sort(r.faces)
            if #r.faces > 0 then r.test_label, r.test_any = "DETECT", true end
            local ks = {}
            for key in pairs((tpl.input_map or {})[k] or {}) do ks[#ks + 1] = key end
            table.sort(ks)
            r.keys = table.concat(ks, ", ")
        elseif r.kind == "monitor" then
            r.test_label = "SHOW"
        end
        out[#out + 1] = r
    end
    return out
end

-- The biggest monitor on the network (the same rule as main's findMonitor).
local function findMonitor()
    local best, best_name, best_area = nil, nil, -1
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local m = peripheral.wrap(name)
            local ok, w, h = pcall(m.getSize)
            local area = ok and (w * h) or 0
            if area > best_area then best, best_name, best_area = m, name, area end
        end
    end
    return best, best_name
end

function Ob.run(root, opts)
    opts = opts or {}
    local st = { screen = "welcome", rev = 1 }
    local ui = UI.new()
    local mon, mon_name = findMonitor()
    local roles, tpl, assign = nil, nil, {}
    local result

    local function changed() st.rev = st.rev + 1 end
    local function say(text, color)
        st.msg, st.msg_color, st.msg_t = text, color, os.clock()
        print("[setup] " .. tostring(text))
        changed()
    end

    local function initScreen()
        mon, mon_name = findMonitor()
        if not mon then return false end
        local okt, tune = pcall(dofile, root .. "/tune.lua")
        local pal = not (okt and type(tune) == "table" and tune.ui and tune.ui.palette == false)
        local ok = D.init(mon, pal)
        ui:invalidate()
        ui.screen = nil
        U.log("setup screen %s: %s", tostring(mon_name), ok and (D.W .. "x" .. D.H .. " px") or "no graphics")
        return ok
    end

    -- ------------------------------------------------ TEST / DETECT / SHOW
    local function restore()
        local r = st.restore
        if r then
            st.restore = nil
            pcall(r.p.setAnalogOutput, r.face, r.v)
        end
    end

    local function candidates()
        local role = roles[st.idx]
        local used = {}
        for _, r in ipairs(roles) do
            if r.key ~= role.key and assign[r.key] then used[assign[r.key]] = r.label end
        end
        local names = {}
        for _, n in ipairs(peripheral.getNames()) do
            if isType(n, role.type) then names[#names + 1] = n end
        end
        table.sort(names)
        local out = {}
        for _, n in ipairs(names) do
            local c = { name = n }
            if used[n] then c.used, c.tag, c.tag_color = true, "USED: " .. used[n], D.C.dim
            elseif n == mon_name and role.kind == "monitor" then c.tag, c.tag_color = "THIS SCREEN", D.C.good
            elseif st.signal and st.signal[n] then c.tag, c.tag_color = "SIGNAL", D.C.good end
            out[#out + 1] = c
        end
        return out
    end

    local function refresh()
        if st.screen ~= "role" then return end
        local keep = st.sel and st.cands and st.cands[st.sel] and st.cands[st.sel].name
        st.cands = candidates()
        st.sel = nil
        for i, c in ipairs(st.cands) do if c.name == keep then st.sel = i end end
        st.scroll = U.clamp(st.scroll or 0, 0, math.max(#st.cands - ROWS, 0))
        changed()
    end

    local function showRole(i)
        restore()
        st.detect, st.signal, st.msg = nil, nil, nil
        st.screen, st.idx, st.total, st.scroll = "role", i, #roles, 0
        st.role = roles[i]
        st.cands = candidates()
        st.sel = nil
        local want = assign[st.role.key] or (st.role.kind == "monitor" and mon_name) or nil
        for k, c in ipairs(st.cands) do if c.name == want then st.sel = k end end
        if st.sel and st.sel > ROWS then st.scroll = st.sel - ROWS end
        changed()
    end

    local function test()
        local role = st.role
        local c = st.sel and st.cands[st.sel]
        if role.kind == "output" then
            if not c then return say("TAP ONE IN THE LIST FIRST", D.C.warn) end
            restore()
            local p = peripheral.wrap(c.name)
            if not (p and p.setAnalogOutput) then return say("CAN'T DRIVE " .. c.name:upper(), D.C.bad) end
            local okg, was = pcall(p.getAnalogOutput, role.face)
            was = okg and tonumber(was) or 0
            -- flip the face (on if off, off if on) and put it back after 2 s
            pcall(p.setAnalogOutput, role.face, was > 0 and 0 or 15)
            st.restore = { p = p, face = role.face, v = was, at = os.clock() + 2 }
            U.log("setup: TEST %s on %s face %s", role.key, c.name, role.face)
            return say("TESTING " .. c.name:upper() .. ": WATCH " .. (role.watch or role.face:upper()), D.C.accent)
        elseif role.kind == "input" then
            st.detect = { stop = os.clock() + 10 }
            st.signal = {}
            return say("PRESS " .. role.keys .. " ON THE TYPEWRITER NOW (10 S)", D.C.accent)
        elseif role.kind == "monitor" then
            if not c then return say("TAP ONE IN THE LIST FIRST", D.C.warn) end
            if c.name == mon_name then return say("THAT IS THIS SCREEN", D.C.good) end
            local p = peripheral.wrap(c.name)
            pcall(function()
                p.setTextScale(1)
                p.setBackgroundColor(colors.black)
                p.clear()
                p.setCursorPos(2, 2)
                p.write("THIS ONE? (" .. c.name .. ")")
            end)
            return say("LOOK FOR \"THIS ONE?\" ON " .. c.name:upper(), D.C.accent)
        end
    end

    -- DETECT: the first relay that sees one of the role's keys gets picked
    local function detectTick()
        local d = st.detect
        if not d then return end
        local role = st.role
        for i, c in ipairs(st.cands) do
            if not c.used and not st.signal[c.name] then
                local p = peripheral.wrap(c.name)
                for _, face in ipairs(role.faces) do
                    local ok, v = pcall(p and p.getAnalogInput, face)
                    if ok and (tonumber(v) or 0) > 0 then
                        st.signal[c.name] = true
                        st.detect = nil
                        st.cands = candidates()
                        st.sel = i
                        if i > (st.scroll or 0) + ROWS or i <= (st.scroll or 0) then st.scroll = math.max(0, i - ROWS) end
                        return say("FOUND IT: " .. c.name:upper(), D.C.good)
                    end
                end
            end
        end
        if os.clock() >= d.stop then
            st.detect = nil
            say("NO KEY SEEN: CHECK THE TYPEWRITER'S LINK", D.C.warn)
        end
    end

    -- ------------------------------------------------ finish / import
    local function finish()
        local name = Config.firstSlotName()
        local id, why = Config.copySlot(TEMPLATE, name, true)
        if not id then return say("CAN'T MAKE THE SLOT: " .. tostring(why), D.C.bad) end
        if not Config.writeAssignments(id, assign, tpl.version) then
            Config.deleteSlot(id)
            return say("CAN'T WRITE THE WIRING: DISK FULL?", D.C.bad)
        end
        Config.useSlot(root, id)
        local cfg, err = Config.load(root)
        if not cfg then
            Config.deleteSlot(id)
            return say("SETUP FAILED: " .. tostring(err):upper():sub(1, 40), D.C.bad)
        end
        U.log("setup: new slot %s wired from template %s", id, TEMPLATE)
        st.screen, st.gi, st.gn, st.msg = "guide", 1, #GUIDE, nil
        st.card = GUIDE[1]
        changed()
    end

    local function import()
        local m, why = ShipDisk.peek()
        if not m then return say(why, D.C.bad) end
        local label = tostring(m.ship or m.slot):upper()
        if not (st.confirm == "import" and os.clock() - st.confirm_t < 4) then
            st.confirm, st.confirm_t = "import", os.clock()
            return say("TAP IMPORT AGAIN TO LOAD " .. label, D.C.warn)
        end
        st.confirm = nil
        local ok, why2 = ShipDisk.load()
        if not ok then return say(why2, D.C.bad) end
        U.log("setup: ship %s imported from disk: restarting", label)
        st.screen, st.title, st.msg, st.msg_color = "busy", "SHIP LOADED", "RESTARTING ON " .. label .. "...", D.C.good
        st.reboot_at = os.clock() + 1.5 -- let the screen show it first
        changed()
    end

    -- ------------------------------------------------ taps
    local function act(a)
        if st.screen == "welcome" then
            if a == "ob:import" then return import() end
            if a == "ob:setup" then
                if not fs.exists("config/" .. TEMPLATE .. ".lua") then
                    return say("NO TEMPLATE CONFIG/" .. TEMPLATE:upper() .. ".LUA: REINSTALL", D.C.bad)
                end
                tpl = U.loadTable("config/" .. TEMPLATE .. ".lua")
                if not tpl then return say("TEMPLATE CONFIG/" .. TEMPLATE:upper() .. ".LUA IS BROKEN", D.C.bad) end
                roles = buildRoles(tpl)
                if #roles == 0 then return say("THE TEMPLATE LISTS NO PERIPHERALS", D.C.bad) end
                assign = {}
                return showRole(1)
            end
        elseif st.screen == "role" then
            local row = a:match("^ob:row:(%d+)")
            if row then
                local i = (st.scroll or 0) + tonumber(row) + 1
                local c = st.cands[i]
                if not c then return end
                if c.used then return say(c.name:upper() .. " IS ALREADY " .. c.tag:sub(7), D.C.warn) end
                st.sel = i
                return changed()
            end
            if a == "ob:up" then st.scroll = math.max(0, (st.scroll or 0) - 1) return changed() end
            if a == "ob:down" then
                st.scroll = math.min(math.max(#st.cands - ROWS, 0), (st.scroll or 0) + 1)
                return changed()
            end
            if a == "ob:test" then
                if #st.cands == 0 then refresh() return say("LOOKED AGAIN: " .. #st.cands .. " FOUND") end
                if st.role.test_label then return test() end
                return
            end
            if a == "ob:back" then
                restore()
                if st.idx > 1 then return showRole(st.idx - 1) end
                st.screen, st.msg = "welcome", nil
                return changed()
            end
            if a == "ob:skip" and st.role.optional then
                assign[st.role.key] = nil
                if st.idx < #roles then return showRole(st.idx + 1) end
                restore()
                return finish()
            end
            if a == "ob:next" then
                local c = st.sel and st.cands[st.sel]
                if not c then return say("TAP ONE IN THE LIST FIRST", D.C.warn) end
                assign[st.role.key] = c.name
                if st.idx < #roles then return showRole(st.idx + 1) end
                restore()
                return finish()
            end
        elseif st.screen == "guide" then
            if a == "ob:gskip" then result = "ready" return end
            if a == "ob:gback" and st.gi > 1 then st.gi = st.gi - 1
            elseif a == "ob:gnext" then
                if st.gi >= #GUIDE then result = "ready" return end
                st.gi = st.gi + 1
            else return end
            st.card = GUIDE[st.gi]
            return changed()
        end
    end
    Ob._st = st -- (tests)

    -- ------------------------------------------------ loop
    print("No wired ship on this computer: setup on the monitor.")
    U.log("---- setup (no wired ship config) %s", V.label)
    if mon then initScreen() else print("no monitor found: attach the cockpit monitor") end

    local function loop()
        local tick = os.startTimer(0.25)
        while true do
            if D.ok then
                local ok, err = pcall(ui.render, ui, { ob = st })
                if not ok then print("[UI] " .. tostring(err)) U.log("setup screen error: %s", tostring(err)) end
            end
            if result then return end
            local ev = { os.pullEventRaw() }
            local e = ev[1]
            if e == "monitor_touch" then
                if ev[2] == mon_name and D.ok then
                    local a = ui:touch(ev[3] - 1, ev[4] - 1)
                    U.log("setup touch %d,%d -> %s", ev[3], ev[4], tostring(a))
                    if a then
                        local ok, err = pcall(act, a)
                        if not ok then say("ERROR: " .. tostring(err):upper():sub(1, 40), D.C.bad) U.log("setup error: %s", tostring(err)) end
                    end
                end
            elseif e == "timer" and ev[2] == tick then
                if st.restore and os.clock() >= st.restore.at then restore() end
                if st.detect then detectTick() end
                if st.msg and st.msg_t and os.clock() - st.msg_t > 8 and st.screen ~= "busy" then
                    st.msg = nil
                    changed()
                end
                if st.reboot_at and os.clock() >= st.reboot_at then
                    result = "reboot"
                    os.reboot()
                    return
                end
                tick = os.startTimer(0.25)
            elseif e == "peripheral" or e == "peripheral_detach" then
                if not D.ok or (e == "peripheral" and peripheral.getType(ev[2]) == "monitor") then initScreen() end
                refresh()
            elseif e == "monitor_resize" then
                initScreen()
            elseif e == "terminate" then
                restore()
                result = "stop"
                return
            end
        end
    end
    parallel.waitForAny(loop)
    restore()
    return result
end

return Ob
