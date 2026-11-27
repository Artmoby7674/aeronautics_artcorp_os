-- First launch: the computer has no wired ship (no slot in config/, or the
-- chosen slot has no assignments file). Instead of stopping with "no ship
-- config", the cockpit monitor walks the player through it:
--
--   WELCOME   IMPORT FROM DISK (a ship saved with SAVE DISK; restarts on it)
--             or SET UP THIS SHIP
--   ENGINES   start the steam engine by hand, tap ENGINES RUNNING
--   KEYS      the typewriter's input relays (input_1, input_2): pick from the
--             network list, DETECT finds the one that sees a key press
--   FIRE      every other relay face, one at a time in random order: the
--             computer flips it and the player taps what moved (which prop,
--             tilt / speed, rear thruster, gear, props spinning, nothing).
--             That names each relay AND each face, so a ship wired unlike
--             the template still flies. See "safety" below.
--   FOUND     what was learned; FIRE MISSING looks again
--   BUTTONS   inputs on the relays just found (engine OFF button, which also
--             drives the starter; screen UP / DOWN; ground sensor; SHIFT):
--             press it, the face that lights up is the one
--   GUIDE     first-flight cards: water valve, START, TAKE OFF, hover
--             hands-off until calibrated (skippable)
--
-- The cockpit monitor is the screen the setup runs on. The new slot (the
-- template copy with the observed faces + assignments + v2/data/slot) is
-- written only at the end, so backing out never leaves half a ship.
--
-- Safety while firing (slow-down links: 15 = prop stopped, 0 = full; the
-- props only turn while the clutch is in):
--   round 1  the clutch is not known yet, so any face may be it: pulses are
--            0.5 s, and a relay found by a tilt gets its other faces set to
--            15 (its prop's speed link: stopped) before anything else fires;
--            faces of a relay already started are fired next
--   clutch   once known it is held out, and only put in for a test
--   round 2  speed links (need the clutch): EVERY unknown face of every
--            prop / rear / unknown relay at 15 first, then clutch in and the
--            tested face at 9 (thrust 6 = a quarter of one hover) for 2 s
--   round 3  rear reverse: the rear's speed links at 9, then the face flips
--   always   a rise of more than a block (CC:Sable pose) cuts the test; any
--            tap during a pulse ends it; leaving puts every face back with
--            the clutch out and every known speed link at 15
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

-- Firing (see "safety" above). Tests may change these.
Ob.PULSE_BLIND = 0.5  -- s a face is flipped while the clutch is not known
Ob.PULSE = 1.5        -- s once it is (nothing can spin)
Ob.SPIN = 9           -- slow-down signal of a spin test: thrust 6 on one prop
Ob.SPIN_SECONDS = 2
Ob.REV_SECONDS = 1.5  -- rear reverse test: each half
Ob.LIFT_GUARD = 1.0   -- blocks of rise that stop a test

local FACES = { "top", "bottom", "left", "right", "front", "back" }
Ob.FACES = FACES
local OPPOSITE = { top = "bottom", bottom = "top", left = "right", right = "left", front = "back", back = "front" }

-- The typewriter's input relays: the only roles still picked from a list.
local ROLES = {
    input_1 = { label = "KEYS W A S D",
        desc = "READS THE TYPEWRITER'S W, A, S AND D KEYS: FORWARD, BACK AND TURNING." },
    input_2 = { label = "KEYS Q E SPACE CTRL",
        desc = "READS THE TYPEWRITER'S Q, E, SPACE AND CTRL KEYS: SIDEWAYS, UP AND DOWN." },
}
local KEY_ROLES = { "input_1", "input_2" }

-- The answers on the FIRE screen. kind: what the second choice is.
local PROP_NAME = { FL = "FRONT-LEFT", FR = "FRONT-RIGHT", RL = "REAR-LEFT", RR = "REAR-RIGHT" }
local CHOICES = {
    prop = { { label = "TILTED", sub = "FORWARD", slot = "tilt_fwd" }, { label = "TILTED", sub = "BACK", slot = "tilt_bwd" },
        { label = "CHANGED", sub = "SPEED", slot = "speed" } },
    rear = { { label = "FORWARD", sub = "PUSHED", slot = "fw" }, { label = "BACKWARD", sub = "PUSHED", slot = "bw" },
        { label = "REVERSED", sub = "DIRECTION", slot = "rev" } },
}
local SLOT_SHORT = { tilt_fwd = "F", tilt_bwd = "B", speed = "S", fw = "FW", bw = "BW", rev = "REV", gear = "", clutch = "" }
local SLOT_WORDS = { tilt_fwd = "TILT FORWARD", tilt_bwd = "TILT BACK", speed = "SPEED", fw = "FORWARD",
    bw = "BACKWARD", rev = "REVERSE", gear = "", clutch = "CLUTCH" }

-- Buttons on the relays the firing finds (template input_map keys).
local KEYS = {
    OFF = { label = "ENGINE OFF BUTTON",
        desc = "PRESS THE ENGINE OFF BUTTON. THE STARTER IS WIRED TO THE SAME FACE, SO THIS FINDS IT TOO." },
    UP = { label = "SCREEN UP BUTTON", desc = "PRESS THE BUTTON THAT FLIPS THE SCREEN TO THE PREVIOUS TAB." },
    DOWN = { label = "SCREEN DOWN BUTTON", desc = "PRESS THE BUTTON THAT FLIPS THE SCREEN TO THE NEXT TAB." },
    PROX = { label = "GROUND SENSOR", auto = true,
        desc = "NOTHING TO PRESS: WHILE THE SHIP IS LANDED THE SENSOR SENDS A STRONG SIGNAL BY ITSELF." },
    SHIFT = { label = "SHIFT KEY", desc = "PRESS SHIFT ON THE TYPEWRITER (LANDING GEAR / LAND)." },
}
local KEY_ORDER = { OFF = 1, UP = 2, DOWN = 3, PROX = 4, SHIFT = 5 }

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

-- The keyboard roles the template has, with the keys DETECT listens for.
local function buildRoles(tpl)
    local out = {}
    for _, k in ipairs(KEY_ROLES) do
        local name = (tpl.peripherals or {})[k]
        if type(name) == "string" and name ~= "" then
            local info = ROLES[k]
            local r = { key = k, label = info.label, desc = info.desc, kind = "input", type = "redstone_relay",
                faces = {}, test_label = "DETECT", test_any = true }
            local ks = {}
            for key, side in pairs((tpl.input_map or {})[k] or {}) do
                r.faces[#r.faces + 1] = side
                ks[#ks + 1] = key
            end
            table.sort(r.faces)
            table.sort(ks)
            r.keys = table.concat(ks, ", ")
            out[#out + 1] = r
        end
    end
    return out
end

-- The parts the FIRE screen asks about, from the template. Each slot is a
-- face to learn: where it goes in the config and the template's guess.
local function buildParts(tpl)
    local parts, om = {}, tpl.output_map or {}
    for _, p in ipairs({ "FL", "FR", "RL", "RR" }) do
        local m = om[p]
        if m then
            parts[#parts + 1] = { id = p, kind = "prop", role = m.relay or ("output_" .. p), label = PROP_NAME[p],
                sub = "PROP", name = PROP_NAME[p] .. " PROP", short = PROP_NAME[p], slots = {
                    { id = "tilt_fwd", path = { "output_map", p }, key = "tilt_fwd", tpl = m.tilt_fwd },
                    { id = "tilt_bwd", path = { "output_map", p }, key = "tilt_bwd", tpl = m.tilt_bwd },
                    { id = "speed", path = { "output_map", p }, key = "speed", tpl = m.speed, safety = true } } }
        end
    end
    if om.REAR then
        local m = om.REAR
        parts[#parts + 1] = { id = "REAR", kind = "rear", role = m.relay or "output_REAR", label = "REAR",
            sub = "THRUSTER", name = "REAR THRUSTER", short = "REAR THRUST", slots = {
                { id = "fw", path = { "output_map", "REAR" }, key = "fw", tpl = m.fw },
                { id = "bw", path = { "output_map", "REAR" }, key = "bw", tpl = m.bw },
                { id = "rev", path = { "output_map", "REAR" }, key = "rev", tpl = m.rev } } }
    end
    if tpl.gear_output then
        parts[#parts + 1] = { id = "GEAR", kind = "gear", role = tpl.gear_output.relay or "aux_relay", label = "LANDING",
            sub = "GEAR", name = "LANDING GEAR", short = "GEAR", slots = {
                { id = "gear", path = { "gear_output" }, key = "side", tpl = tpl.gear_output.side } } }
    end
    if tpl.engine then
        parts[#parts + 1] = { id = "ENGINE", kind = "clutch", role = tpl.engine.relay_key or "engine_relay",
            label = "ENGINE /", sub = "PROPS SPIN", name = "ENGINE CLUTCH", short = "CLUTCH", slots = {
                { id = "clutch", path = { "engine" }, key = "clutch_side", tpl = tpl.engine.clutch_side } } }
    end
    local byId, byRole = {}, {}
    for _, p in ipairs(parts) do
        byId[p.id], byRole[p.role] = p, p
        p.slot = {}
        for _, s in ipairs(p.slots) do p.slot[s.id] = s end
    end
    return parts, byId, byRole
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

-- Height of the ship (CC:Sable), or nil off a ship.
local function shipY()
    local sl = rawget(_G, "sublevel")
    if not (sl and sl.getLogicalPose) then return nil end
    local ok, p = pcall(sl.getLogicalPose)
    if ok and type(p) == "table" and type(p.position) == "table" then return tonumber(p.position.y) end
end

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

function Ob.run(root, opts)
    opts = opts or {}
    local st = { screen = "welcome", rev = 1, fire_id = 0, fires = {} }
    local ui = UI.new()
    local mon, mon_name = findMonitor()
    local roles, tpl, assign = nil, nil, {}
    local parts, PART, ROLEPART = {}, {}, {}
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

    -- ------------------------------------------------ KEYS (pick + DETECT)
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
        st.detect, st.signal, st.msg = nil, nil, nil
        st.screen, st.idx, st.total, st.scroll = "role", i, #roles, 0
        st.head, st.next_label = "SHIP SETUP: KEYS", "NEXT >"
        st.role = roles[i]
        st.cands = candidates()
        st.sel = nil
        for k, c in ipairs(st.cands) do if c.name == assign[st.role.key] then st.sel = k end end
        if st.sel and st.sel > ROWS then st.scroll = st.sel - ROWS end
        changed()
    end

    local function showEngines()
        st.screen, st.msg = "engines", nil
        changed()
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
                    local key = c.name .. ":" .. face
                    if not (ok and (tonumber(v) or 0) > 0) then d.base[key] = nil
                    elseif not d.base[key] then
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

    -- ------------------------------------------------ FIRE: what we know
    -- Everything learned is derived from the answer list, so BACK (undo)
    -- is just dropping the last answer.
    local know

    local function derive()
        local k = { role = {}, of = {}, face = {}, owner = {}, nothing = {} }
        for _, a in ipairs(st.answers or {}) do
            local fk = a.relay .. ":" .. a.face
            if a.part == "NOTHING" then
                k.nothing[a.stage .. ":" .. fk] = true
            else
                local part = PART[a.part]
                k.role[part.role], k.of[a.relay] = a.relay, part.role
                k.face[part.id] = k.face[part.id] or {}
                k.face[part.id][a.slot] = a.face
                k.owner[fk] = { part = part.id, slot = a.slot }
            end
        end
        -- the first prop relay with both tilts known (see desired)
        st.show_relay = nil
        for _, p in ipairs(parts) do
            local f = k.face[p.id]
            if p.kind == "prop" and not st.show_relay and f and f.tilt_fwd and f.tilt_bwd then st.show_relay = k.role[p.role] end
        end
        know = k
        return k
    end

    local function known(pid, slot) return know.face[pid] and know.face[pid][slot] end
    local function partOf(relay)
        local r = know.of[relay]
        return r and ROLEPART[r]
    end
    local function engineRelay() return PART.ENGINE and know.role[PART.ENGINE.role] end
    local function clutchFace() return known("ENGINE", "clutch") end
    -- the clutch is known, or there is none to find (props always coupled)
    local function clutchReady() return not PART.ENGINE or clutchFace() ~= nil end
    local function rearRelay() return PART.REAR and know.role[PART.REAR.role] end

    local function counts()
        local n, total = 0, 0
        for _, p in ipairs(parts) do
            for _, s in ipairs(p.slots) do
                total = total + 1
                if known(p.id, s.id) then n = n + 1 end
            end
        end
        return n, total
    end

    -- A relay whose remaining faces can't show anything more this round.
    local function relayDone(stage, relay)
        local part = partOf(relay)
        if not part then return false end
        if part.kind == "gear" or part.kind == "clutch" then return true end
        if stage == 1 then
            if part.kind == "prop" then return known(part.id, "tilt_fwd") and known(part.id, "tilt_bwd") end
            return part.kind == "rear" -- its faces only show while it spins
        elseif stage == 2 then
            if part.kind == "prop" then return known(part.id, "speed") end
            if part.kind == "rear" then return known(part.id, "fw") and known(part.id, "bw") end
        end
        return true
    end

    local function stageDone(stage)
        for _, p in ipairs(parts) do
            if stage == 1 then
                if p.kind == "prop" and not (known(p.id, "tilt_fwd") and known(p.id, "tilt_bwd")) then return false end
                if (p.kind == "gear" or p.kind == "clutch") and not known(p.id, p.slots[1].id) then return false end
            elseif stage == 2 then
                if p.kind == "prop" and not known(p.id, "speed") then return false end
                if p.kind == "rear" and not (known(p.id, "fw") and known(p.id, "bw")) then return false end
            elseif p.kind == "rear" then
                return known(p.id, "rev") ~= nil
            end
        end
        return true
    end

    local function eligible(stage, it)
        local fk = it.relay .. ":" .. it.face
        if know.owner[fk] or know.nothing[stage .. ":" .. fk] then return false end
        if stage == 3 then
            return it.relay == rearRelay() and (known("REAR", "fw") or known("REAR", "bw")) ~= nil
        end
        return not relayDone(stage, it.relay)
    end

    -- The next face to fire: round 1 (look), 2 (spin), 3 (rear reverse).
    -- Within a round, faces of a relay already identified go first.
    local function nextItem()
        for stage = 1, 3 do
            if stage == 2 and not clutchReady() then
                -- round 1 is over and no face started the props: with every
                -- speed link already at 15 (the OS parks them) a clutch pulse
                -- shows nothing. Now that a prop idles at a crawl during
                -- pulses (show_relay), fire the unknown relays' quiet faces
                -- once more ("round 0": the clutch hunt).
                if not st.show_relay then return nil end
                for _, it in ipairs(st.order) do
                    local fk = it.relay .. ":" .. it.face
                    if not partOf(it.relay) and not know.owner[fk] and know.nothing["1:" .. fk]
                        and not know.nothing["0:" .. fk] then
                        return it, 0
                    end
                end
                return nil
            end
            if not stageDone(stage) then
                local first
                for _, it in ipairs(st.order) do
                    if eligible(stage, it) then
                        if partOf(it.relay) then return it, stage end
                        first = first or it
                    end
                end
                if first then return first, stage end
            end
        end
    end

    -- ------------------------------------------------ FIRE: the relays
    local function put(relay, face, v)
        local key = relay .. ":" .. face
        if st.out[key] == v then return end
        local p = peripheral.wrap(relay)
        if p and p.setAnalogOutput then pcall(p.setAnalogOutput, face, v) end
        st.out[key] = v
    end

    local function active() return (tpl.engine and tpl.engine.active) or 15 end
    local function inactive() return (tpl.engine and tpl.engine.inactive) or 0 end

    -- What a face should sit at between tests ("test") or when leaving
    -- the firing ("rest"); see "safety" at the top.
    local function desired(relay, face, mode)
        local o = know.owner[relay .. ":" .. face]
        local orig = st.orig[relay .. ":" .. face] or 0
        if o and o.slot == "clutch" then return inactive() end
        local part = partOf(relay)
        if part and part.kind == "clutch" then return orig end -- the engine relay: starter etc. untouched
        if o and (o.slot == "speed" or o.slot == "fw" or o.slot == "bw") then return 15 end
        if mode == "rest" then return orig end
        if o then return orig end
        if part and part.kind == "prop" and known(part.id, "tilt_fwd") and known(part.id, "tilt_bwd") then
            -- its speed link is one of these: stopped. While the clutch is
            -- still unknown one such prop idles at a crawl instead, so a
            -- clutch pulse still shows when every prop is parked.
            if not clutchReady() and relay == st.show_relay then return Ob.SPIN end
            return 15
        end
        if (st.phase or 1) >= 2 and not (part and part.kind == "gear") then return 15 end
        return orig
    end

    local function apply(mode)
        for _, r in ipairs(st.relays or {}) do
            for _, f in ipairs(FACES) do put(r, f, desired(r, f, mode)) end
        end
    end

    local function clutch(on)
        local r, f = engineRelay(), clutchFace()
        if r and f then put(r, f, on and active() or inactive()) end
    end

    local function rearSpin(on)
        local r = rearRelay()
        for _, s in ipairs({ "fw", "bw" }) do
            local f = known("REAR", s)
            if r and f then put(r, f, on and Ob.SPIN or 15) end
        end
    end

    -- a running test: steps at times after its start, each on its own timer
    local function stopTest()
        if st.tl then
            st.tl = nil
            st.firing = false
            apply("test")
            changed()
        end
    end

    local function runTest(steps)
        local t0 = os.clock()
        st.tl = { t0 = t0, steps = steps, i = 1, timers = {} }
        local last = steps[#steps].at
        for _, s in ipairs(steps) do st.tl.timers[os.startTimer(s.at)] = true end
        for t = 0.1, last, 0.1 do st.tl.timers[os.startTimer(t)] = true end -- lift guard
        st.firing = true
    end

    local function testTick()
        local tl = st.tl
        if not tl then return end
        if st.y0 then
            local y = shipY()
            if y and y - st.y0 > Ob.LIFT_GUARD then
                stopTest()
                U.log("setup: ship rose %.1f blocks during a test: stopped", y - st.y0)
                return say("THE SHIP LIFTED: TEST STOPPED. ANSWER, OR FIRE AGAIN", D.C.bad)
            end
            if y and y < st.y0 then st.y0 = y end
        end
        while tl.steps[tl.i] and os.clock() >= tl.t0 + tl.steps[tl.i].at - 1e-6 do
            tl.steps[tl.i].fn()
            tl.i = tl.i + 1
        end
        if not tl.steps[tl.i] then
            st.tl, st.firing = nil, false
            changed()
        end
    end

    local function viewParts()
        local pv = {}
        for _, p in ipairs(parts) do
            local n = 0
            for _, s in ipairs(p.slots) do if known(p.id, s.id) then n = n + 1 end end
            local v = { id = p.id, label = p.label, sub = p.sub, done = n == #p.slots }
            if #p.slots > 1 then v.sub = v.done and "DONE" or (p.sub .. " " .. n .. "/" .. #p.slots)
            elseif v.done then v.sub = #p.sub <= 7 and (p.sub .. " DONE") or "DONE" end
            pv[#pv + 1] = v
        end
        pv[#pv + 1] = { id = "NOTHING", label = "NOTHING", sub = "NO CHANGE" }
        st.pv = pv
        st.known_n, st.known_total = counts()
    end

    local function fire(it, stage)
        stopTest()
        st.screen, st.cur, st.phase, st.part = "fire", it, stage, nil
        apply("test")
        st.fire_id = st.fire_id + 1
        local key = it.relay .. ":" .. it.face
        st.fires[key] = (st.fires[key] or 0) + 1
        local r, f = it.relay, it.face
        local v0 = desired(r, f, "test")
        local steps
        if stage <= 1 then
            local dur = clutchReady() and Ob.PULSE or Ob.PULSE_BLIND
            st.hint = clutchReady() and string.format("WATCH THE SHIP: THIS FACE FLIPS FOR %.1f S.", dur)
                or string.format("WATCH THE SHIP: A %.1f S FLIP. PROPS TURNING = ENGINE.", dur)
            steps = { { at = 0, fn = function() put(r, f, v0 > 0 and 0 or 15) end },
                { at = dur, fn = function() put(r, f, v0) end } }
        elseif stage == 2 then
            st.hint = "SPIN TEST: CLUTCH IN, THIS FACE AT LOW SPEED FOR 2 S."
            steps = { { at = 0, fn = function() put(r, f, Ob.SPIN) clutch(true) end },
                { at = Ob.SPIN_SECONDS, fn = function() clutch(false) put(r, f, v0) end } }
        else
            st.hint = "THE REAR THRUSTER TURNS SLOWLY, THEN THIS FACE FLIPS."
            steps = { { at = 0, fn = function() rearSpin(true) clutch(true) end },
                { at = Ob.REV_SECONDS, fn = function() put(r, f, v0 > 0 and 0 or 15) end },
                { at = 2 * Ob.REV_SECONDS, fn = function() clutch(false) rearSpin(false) put(r, f, v0) end } }
        end
        U.log("setup: fire %s %s (round %d)", r, f, stage)
        runTest(steps)
        testTick()
        viewParts()
        changed()
    end

    -- ------------------------------------------------ FOUND (review)
    local function missing()
        local out = {}
        for _, p in ipairs(parts) do
            if (p.kind == "prop" or p.kind == "rear") and not know.role[p.role] then out[#out + 1] = p.short
            elseif p.kind == "prop" and not known(p.id, "speed") then out[#out + 1] = p.short .. " SPEED"
            elseif p.kind == "rear" and not (known(p.id, "fw") or known(p.id, "bw")) then out[#out + 1] = "REAR SPEED" end
        end
        return out
    end

    -- The face a slot gets: seen, else the template's unless that face of
    -- the relay already does something else.
    local function finalFace(p, s)
        local f = known(p.id, s.id)
        if f then return f, true end
        local relay = know.role[p.role]
        if relay and s.tpl and know.owner[relay .. ":" .. s.tpl] then return nil, false end
        return s.tpl, false
    end

    local function showReview()
        stopTest()
        if st.relays then apply("rest") end
        st.screen, st.part = "review", nil
        local rows = {}
        for _, p in ipairs(parts) do
            local row = { label = p.short, relay = know.role[p.role], faces = {} }
            for _, s in ipairs(p.slots) do
                local f, seen = finalFace(p, s)
                row.faces[#row.faces + 1] = { lbl = SLOT_SHORT[s.id], face = f, seen = seen }
            end
            rows[#rows + 1] = row
        end
        st.rows = rows
        st.missing = missing()
        st.can_next = #st.missing == 0
        st.known_n, st.known_total = counts()
        if PART.ENGINE and not clutchFace() then
            say("NO FACE STARTED THE PROPS: IS THE ENGINE RUNNING?", D.C.warn)
        elseif not st.can_next then
            say("MISSING: " .. table.concat(st.missing, ", "), D.C.warn)
        else
            st.msg = nil
        end
        changed()
    end

    local function nextFire()
        local it, stage = nextItem()
        if it then return fire(it, stage) end
        return showReview()
    end

    local function startFire()
        local skip = {}
        for _, r in ipairs(roles) do if assign[r.key] then skip[assign[r.key]] = true end end
        local relays = {}
        for _, n in ipairs(peripheral.getNames()) do
            if not skip[n] and isType(n, "redstone_relay") then relays[#relays + 1] = n end
        end
        table.sort(relays)
        if #relays == 0 then return say("NO OTHER RELAYS ON THE NETWORK", D.C.bad) end
        st.relays, st.orig, st.out, st.answers, st.order = relays, {}, {}, {}, {}
        for _, n in ipairs(relays) do
            local p = peripheral.wrap(n)
            for _, f in ipairs(FACES) do
                local ok, v = pcall(p.getAnalogOutput, f)
                v = ok and tonumber(v) or 0
                st.orig[n .. ":" .. f], st.out[n .. ":" .. f] = v, v
                st.order[#st.order + 1] = { relay = n, face = f }
            end
        end
        shuffle(st.order)
        st.y0 = shipY()
        derive()
        U.log("setup: firing %d faces on %d relays", #st.order, #relays)
        st.msg = nil
        return nextFire()
    end

    -- leaving the firing for good (BACK to the keys, terminate)
    local function leaveFire()
        stopTest()
        if st.relays then apply("rest") end
    end

    local function answer(pid, slot)
        local it = st.cur
        local fk = it.relay .. ":" .. it.face
        local rec = { relay = it.relay, face = it.face, stage = st.phase }
        if pid == "NOTHING" then
            rec.part = "NOTHING"
        else
            local p = PART[pid]
            slot = slot or p.slots[1].id
            local has = know.role[p.role]
            if has and has ~= it.relay then
                return say("THE " .. p.name .. " IS ON " .. has:upper() .. " ALREADY", D.C.warn)
            end
            local other = partOf(it.relay)
            if other and other ~= p then
                return say(it.relay:upper() .. " IS THE " .. other.name .. " ALREADY", D.C.warn)
            end
            if p.kind == "rear" and (slot == "fw" or slot == "bw") and known(p.id, slot) then
                slot = slot == "fw" and "bw" or "fw" -- both are speed links: the other one
            end
            if known(p.id, slot) then
                return say(p.name .. " " .. SLOT_WORDS[slot] .. " IS " .. known(p.id, slot):upper() .. " ALREADY", D.C.warn)
            end
            rec.part, rec.slot = pid, slot
        end
        stopTest()
        st.answers[#st.answers + 1] = rec
        derive()
        if rec.part == "NOTHING" then
            st.msg = nil
        else
            local p = PART[rec.part]
            local w = SLOT_WORDS[rec.slot]
            say(it.relay:upper() .. " " .. it.face:upper() .. " = " .. p.name .. (w ~= "" and (" " .. w) or ""), D.C.good)
        end
        U.log("setup: %s -> %s %s", fk, rec.part, tostring(rec.slot))
        return nextFire()
    end

    local function undo()
        stopTest()
        local a = table.remove(st.answers)
        if not a then
            leaveFire()
            if #roles > 0 then return showRole(#roles) end
            return showEngines()
        end
        derive()
        say("UNDONE: FIRING " .. a.relay:upper() .. " " .. a.face:upper() .. " AGAIN")
        return fire({ relay = a.relay, face = a.face }, a.stage)
    end

    -- ------------------------------------------------ BUTTONS (press / read)
    local function pressItems()
        local items = {}
        for role, keys in pairs(tpl.input_map or {}) do
            local p = ROLEPART[role]
            local relay = p and know.role[role]
            if relay then
                for key, face in pairs(keys) do
                    local info = KEYS[key] or { label = key .. " INPUT", desc = "PRESS WHATEVER SENDS " .. key .. "." }
                    items[#items + 1] = { id = role .. ":" .. key, role = role, key = key, relay = relay, tpl = face,
                        label = info.label, desc = info.desc, auto = info.auto }
                end
            end
        end
        table.sort(items, function(a, b)
            local ra, rb = KEY_ORDER[a.key] or 99, KEY_ORDER[b.key] or 99
            if ra ~= rb then return ra < rb end
            return a.id < b.id
        end)
        return items
    end

    local function readInputs(relay)
        local p = peripheral.wrap(relay)
        local lv = {}
        for _, f in ipairs(FACES) do
            local ok, v = pcall(p and p.getAnalogInput, f)
            lv[f] = ok and tonumber(v) or 0
        end
        return lv
    end

    -- faces of this relay other buttons already took
    local function claimed(item)
        local c = {}
        for _, o in ipairs(st.pitems) do
            if o ~= item and o.relay == item.relay and st.pressed[o.id] then c[st.pressed[o.id]] = true end
        end
        return c
    end

    local function pressView()
        local it = st.pitems[st.pi]
        local pr = st.press
        pr.found = st.pressed[it.id]
        local faces = {}
        for _, f in ipairs(FACES) do faces[#faces + 1] = { face = f, level = pr.levels[f] or 0 } end
        pr.faces = faces
    end

    local function pressTick()
        local pr = st.press
        local it = st.pitems[st.pi]
        local lv = readInputs(it.relay)
        local moved = false
        for _, f in ipairs(FACES) do if lv[f] ~= pr.levels[f] then moved = true end end
        pr.levels = lv
        local was = st.pressed[it.id]
        local taken = claimed(it)
        if it.auto then
            local best, bv = nil, 0
            for _, f in ipairs(FACES) do
                if not taken[f] and lv[f] > bv then best, bv = f, lv[f] end
            end
            if best and st.pressed[it.id] ~= best then
                st.pressed[it.id] = best
                say(it.label .. ": " .. best:upper() .. " FACE READS " .. bv, D.C.good)
            end
        else
            for _, f in ipairs(FACES) do
                if lv[f] <= 0 then pr.hold[f] = nil
                elseif not pr.hold[f] and not taken[f] then
                    pr.hold[f] = true
                    if st.pressed[it.id] ~= f then
                        st.pressed[it.id] = f
                        say("FOUND IT: THE " .. f:upper() .. " FACE", D.C.good)
                    end
                end
            end
        end
        if moved or st.pressed[it.id] ~= was then pressView() changed() end
    end

    local function showPress(i)
        st.screen, st.pi, st.pn, st.msg = "press", i, #st.pitems, nil
        local it = st.pitems[i]
        st.press = { item = it, levels = readInputs(it.relay), hold = {} }
        -- a key already held (or a sensor that is always on) is not a press
        for _, f in ipairs(FACES) do if st.press.levels[f] > 0 then st.press.hold[f] = true end end
        pressView()
        if it.auto then pressTick() end
        changed()
    end

    -- ------------------------------------------------ finish / import
    local function finish()
        local edits, errs = {}, {}
        for _, p in ipairs(parts) do
            for _, s in ipairs(p.slots) do
                local f = finalFace(p, s)
                edits[#edits + 1] = { s.path, s.key, f }
            end
        end
        -- inputs on the found relays
        local pressed = st.pressed or {}
        for _, it in ipairs(st.pitems or {}) do
            local f = pressed[it.id]
            if f then edits[#edits + 1] = { { "input_map", it.role }, it.key, f } end
        end
        -- the starter shares the OFF button's face (template convention);
        -- without a press it keeps its place opposite the clutch
        local e = tpl.engine
        if e and e.start_side then
            local er = e.relay_key or "engine_relay"
            local offTpl = ((tpl.input_map or {})[er] or {}).OFF
            local start = e.start_side
            local clutchNow = clutchFace()
            if offTpl == e.start_side and pressed[er .. ":OFF"] then
                start = pressed[er .. ":OFF"]
            elseif clutchNow and OPPOSITE[e.clutch_side] == e.start_side then
                start = OPPOSITE[clutchNow]
            end
            edits[#edits + 1] = { { "engine" }, "start_side", start }
        end
        -- the ground sensor read on the PROX face
        local px = tpl.proximity
        if px and px.input_key then
            local f = pressed[px.input_key .. ":PROX"]
            if f and ((tpl.input_map or {})[px.input_key] or {}).PROX == px.side then
                edits[#edits + 1] = { { "proximity" }, "side", f }
            end
        end
        -- assignments: role -> peripheral
        local a = {}
        for k, v in pairs(assign) do a[k] = v end
        for role, relay in pairs(know.role) do a[role] = relay end
        if (tpl.peripherals or {}).main_monitor and mon_name then a.main_monitor = mon_name end

        local name = Config.firstSlotName()
        local id, why = Config.copySlot(TEMPLATE, name, true)
        if not id then return say("CAN'T MAKE THE SLOT: " .. tostring(why), D.C.bad) end
        local okp, perr = Config.patchSlot(id, edits)
        if not okp then
            Config.deleteSlot(id)
            U.log("setup: patch failed: %s", tostring(perr))
            return say("CAN'T WRITE THE FACES: " .. tostring(perr):upper():sub(1, 34), D.C.bad)
        end
        if not Config.writeAssignments(id, a, tpl.version) then
            Config.deleteSlot(id)
            return say("CAN'T WRITE THE WIRING: DISK FULL?", D.C.bad)
        end
        Config.useSlot(root, id)
        local cfg, err = Config.load(root)
        if not cfg then
            Config.deleteSlot(id)
            return say("SETUP FAILED: " .. tostring(err):upper():sub(1, 40), D.C.bad)
        end
        U.log("setup: new slot %s wired by firing (%d faces seen) from template %s", id, (counts()), TEMPLATE)
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
                parts, PART, ROLEPART = buildParts(tpl)
                if #parts == 0 then return say("THE TEMPLATE LISTS NO OUTPUTS", D.C.bad) end
                assign, st.pressed, st.answers = {}, {}, {}
                derive()
                return showEngines()
            end
        elseif st.screen == "engines" then
            if a == "ob:back" then st.screen, st.msg = "welcome", nil return changed() end
            if a == "ob:engines" then
                U.log("setup: engines running")
                if #roles > 0 then return showRole(1) end
                return startFire()
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
                -- a press is a rise: faces already on (a ground sensor on
                -- another relay, a held key) are ignored until they drop
                st.detect = { stop = os.clock() + 10, base = {} }
                st.signal = {}
                for _, c in ipairs(st.cands) do
                    local p = peripheral.wrap(c.name)
                    for _, face in ipairs(st.role.faces) do
                        local ok, v = pcall(p and p.getAnalogInput, face)
                        if ok and (tonumber(v) or 0) > 0 then st.detect.base[c.name .. ":" .. face] = true end
                    end
                end
                return say("PRESS " .. st.role.keys .. " ON THE TYPEWRITER NOW (10 S)", D.C.accent)
            end
            if a == "ob:back" then
                if st.idx > 1 then return showRole(st.idx - 1) end
                return showEngines()
            end
            if a == "ob:next" then
                local c = st.sel and st.cands[st.sel]
                if not c then return say("TAP ONE IN THE LIST FIRST", D.C.warn) end
                assign[st.role.key] = c.name
                if st.idx < #roles then return showRole(st.idx + 1) end
                st.detect = nil
                return startFire()
            end
        elseif st.screen == "fire" then
            local pid = a:match("^ob:part:(.+)$")
            if pid then
                local p = PART[pid]
                if p and CHOICES[p.kind] then
                    st.part, st.choices = pid, CHOICES[p.kind]
                    return changed()
                end
                return answer(pid)
            end
            local slot = a:match("^ob:what:(.+)$")
            if slot and st.part then return answer(st.part, slot) end
            if a == "ob:parts" then st.part = nil return changed() end
            if a == "ob:again" then
                st.fires.again = (st.fires.again or 0) + 1
                return fire(st.cur, st.phase)
            end
            if a == "ob:back" then return undo() end
            if a == "ob:review" then return showReview() end
        elseif st.screen == "review" then
            if a == "ob:back" then return undo() end
            if a == "ob:more" then
                local keep = {}
                for _, r in ipairs(st.answers) do if r.part ~= "NOTHING" then keep[#keep + 1] = r end end
                st.answers = keep
                derive()
                local it, stage = nextItem()
                if not it then return say("NOTHING LEFT TO FIRE", D.C.warn) end
                st.msg = nil
                return fire(it, stage)
            end
            if a == "ob:next" then
                if not st.can_next then return say("MISSING: " .. table.concat(st.missing, ", "), D.C.warn) end
                st.pitems = pressItems()
                if #st.pitems == 0 then return finish() end
                return showPress(1)
            end
        elseif st.screen == "press" then
            local it = st.pitems[st.pi]
            if a == "ob:back" then
                if st.pi > 1 then return showPress(st.pi - 1) end
                return showReview()
            end
            if a == "ob:skip" or a == "ob:next" then
                if a == "ob:skip" then st.pressed[it.id] = nil
                elseif not st.pressed[it.id] then return say("NOTHING SEEN YET: PRESS IT, OR SKIP", D.C.warn) end
                if st.pi < #st.pitems then return showPress(st.pi + 1) end
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
    Ob._know = function() return know end

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
            elseif e == "timer" and st.tl and st.tl.timers[ev[2]] then
                st.tl.timers[ev[2]] = nil
                testTick()
            elseif e == "timer" and ev[2] == tick then
                if st.detect then detectTick() end
                if st.screen == "press" then pressTick() end
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
                result = "stop"
                return
            end
        end
    end
    parallel.waitForAny(loop)
    leaveFire()
    return result
end

return Ob
