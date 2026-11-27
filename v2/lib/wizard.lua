-- Peripheral setup wizard: which network name each relay and the cockpit
-- monitor got on THIS computer (redstone_relay_8, monitor_3, ...: the names
-- depend on the order things were connected in each world). Ported from the
-- original OS (v1 `startup`, "Step 3: Setup wizard") and run the same way,
-- on the ship computer's own terminal (the monitor isn't known until it is
-- plugged in):
--
--   1. disconnect ALL modems from the computer, press any key
--   2. the devices still on the network are noted and ignored
--   3. one role at a time, in a fixed order (input_1, input_2, aux_relay,
--      engine_relay, output_FL/FR/RL/RR, output_REAR, main_monitor, then the
--      optional ones the config lists): "plug in this device's modem, then
--      right-click it"; the first NEW peripheral that attaches is that role
--   4. a printer for flight reports (S skips: printing finds one by itself)
--   5. config/assignments_<slot>.lua is written in the original format and
--      the flight OS starts on it
--
-- Like v1 it takes whatever new device appears: one that was already there
-- (or was assigned a step ago and is re-clicked) is ignored, a modem on the
-- computer itself is ignored, and a device of an unexpected type is taken
-- but flagged on screen. Detection waits on CC's "peripheral" attach events
-- (no polling).
--
-- It runs when the assignments file is missing, made for another config
-- version, or lacks a role the config wants (main.lua, Wiz.needed). To run
-- it again by hand: hold Ctrl+T on the ship computer to stop the OS, then
-- type  v2/wizard  (or delete config/assignments_<slot>.lua and reboot).
local Config = require("config")
local U = require("util")
local V = require("version")

local Wiz = {}

-- The original wizard's descriptions and order.
local DESC = {
    input_1 = "Typewriter relay for WASD keys",
    input_2 = "Typewriter relay for Q/E/Space/Ctrl",
    aux_relay = "Aux relay: shift / gear / proximity",
    engine_relay = "Engine relay: LEFT=start, RIGHT=clutch; front/back=tab up/down",
    output_FL = "Front-left propeller relay",
    output_FR = "Front-right propeller relay",
    output_RL = "Rear-left propeller relay",
    output_RR = "Rear-right propeller relay",
    output_REAR = "Rear thruster relay",
    main_monitor = "HUD display monitor",
    printer = "Network printer (flight reports)",
    speaker = "Audio speaker",
}
Wiz.DESC = DESC

local ORDER = {
    input_1 = 1, input_2 = 2,
    aux_relay = 3,
    engine_relay = 4,
    output_FL = 5, output_FR = 6, output_RL = 7, output_RR = 8,
    output_REAR = 9,
    main_monitor = 10, speaker = 11, printer = 12,
}

-- Seconds without a new device before the "is it connected?" hint.
Wiz.HINT_AFTER = 15
-- Seconds the "saved" screen stays before the OS starts (any key skips).
Wiz.DONE_WAIT = 3

-- The roles to ask for, in order: every named peripheral of the config,
-- then the optional ones it lists that are not among them. The printer is
-- its own step at the end (wizard v1 [3c]).
function Wiz.steps(ship)
    local steps, seen = {}, {}
    for key, name in pairs(ship.peripherals or {}) do
        if type(name) == "string" and name ~= "" and key ~= "printer" and key ~= "kbd_computer" then
            steps[#steps + 1] = { key = key, target = name, desc = DESC[key] or key }
            seen[key] = true
        end
    end
    table.sort(steps, function(a, b)
        local oa, ob = ORDER[a.key] or 99, ORDER[b.key] or 99
        if oa ~= ob then return oa < ob end
        return a.key < b.key
    end)
    for _, key in ipairs(ship.optional_peripherals or {}) do
        if not seen[key] and key ~= "printer" then
            seen[key] = true
            steps[#steps + 1] = { key = key, target = key, desc = DESC[key] or key, optional = true }
        end
    end
    return steps
end

-- v1 assignmentsCompatible: the same config version, and every role the
-- config wants (optional ones too: v2 never stops at boot to ask for one).
function Wiz.compatible(ship, saved)
    if type(saved) ~= "table" then return false, "not a table" end
    if tostring(saved.config_version) ~= tostring(ship.version) then
        return false, "config v" .. tostring(saved.config_version) .. " -> v" .. tostring(ship.version)
    end
    for _, st in ipairs(Wiz.steps(ship)) do
        if type(saved[st.key]) ~= "string" or saved[st.key] == "" then return false, "missing " .. st.key end
    end
    return true, "ok"
end

-- Does this computer need the wizard? -> need, why, slot
function Wiz.needed(root)
    local slot = Config.pickSlot(root)
    if not slot then return false end -- Config.load says what is wrong
    local ship = Config.readShip(slot)
    if not ship then return false end
    if not fs.exists(Config.assignmentsPath(slot)) then return true, "no peripheral assignments yet", slot end
    local ok, why = Wiz.compatible(ship, Config.readAssignments(slot))
    if not ok then return true, "saved assignments outdated (" .. why .. ")", slot end
    return false, nil, slot
end

-- ------------------------------------------------------------ terminal

local col = {}
local function setupColors()
    local c = rawget(_G, "colors") or rawget(_G, "colours") or {}
    local okc, color = pcall(function() return term.isColor and term.isColor() end)
    color = okc and color
    local function pick(name, mono) return (color and c[name]) or c[mono] or c.white end
    col = {
        bg = c.black, text = c.white or 1,
        head_bg = pick("blue", "white"), head = pick("white", "black"),
        dim = pick("lightGray", "white"), accent = pick("cyan", "white"),
        good = pick("lime", "white"), warn = pick("yellow", "white"), bad = pick("red", "white"),
        name = pick("lightBlue", "white"),
    }
end

local function setFg(c) if c and term.setTextColor then pcall(term.setTextColor, c) end end
local function setBg(c) if c and term.setBackgroundColor then pcall(term.setBackgroundColor, c) end end

local function size()
    local ok, w, h = pcall(term.getSize)
    if ok and w then return w, h end
    return 51, 19
end

local function wrap(text, width)
    local out, cur = {}, ""
    for w in tostring(text):gmatch("%S+") do
        local word = w
        while #word > width do
            if cur ~= "" then out[#out + 1] = cur cur = "" end
            out[#out + 1] = word:sub(1, width)
            word = word:sub(width + 1)
        end
        if cur == "" then cur = word
        elseif #cur + 1 + #word <= width then cur = cur .. " " .. word
        else out[#out + 1] = cur cur = word end
    end
    if cur ~= "" or #out == 0 then out[#out + 1] = cur end
    return out
end

local function fit(s, n)
    s = tostring(s)
    if #s > n then return s:sub(1, math.max(n - 2, 0)) .. ".." end
    return s .. string.rep(" ", n - #s)
end

-- A screen is a list of lines; a line is a list of { text, color } runs.
-- The header bar is line 1 and drawn on its own background.
local function draw(lines, header_right)
    local W, H = size()
    setBg(col.bg)
    term.clear()
    term.setCursorPos(1, 1)
    setBg(col.head_bg)
    setFg(col.head)
    local left = " PERIPHERAL SETUP"
    local right = (header_right or V.label) .. " "
    term.write(fit(left, W - #right) .. right)
    setBg(col.bg)
    for i, line in ipairs(lines) do
        if i + 1 > H then break end
        term.setCursorPos(1, i + 1)
        local x = 0
        for _, run in ipairs(line) do
            local t = tostring(run[1])
            if x + #t > W then t = t:sub(1, W - x) end
            setFg(run[2] or col.text)
            term.write(t)
            x = x + #t
            if x >= W then break end
        end
    end
    setFg(col.text)
    term.setCursorPos(1, math.min(#lines + 2, H))
end

local function para(lines, text, color, indent)
    local W = size()
    indent = indent or 1
    for _, l in ipairs(wrap(text, W - indent - 1)) do
        lines[#lines + 1] = { { string.rep(" ", indent) .. l, color } }
    end
end

-- ------------------------------------------------------------ the network

local function typeOf(name)
    local ok, t = pcall(peripheral.getType, name)
    return ok and t or nil
end

local function hasType(name, want)
    if peripheral.hasType then
        local ok, yes = pcall(peripheral.hasType, name, want)
        if ok and yes then return true end
    end
    local t = typeOf(name)
    return t == want or (want == "redstone_relay" and type(t) == "string" and t:find("relay") ~= nil)
end

-- What a role should be, for the "unexpected type" flag.
local function expected(key)
    if key == "main_monitor" or key:match("monitor") then return "monitor" end
    if key == "printer" or key == "speaker" then return key end
    if key:match("^input_") or key:match("^output_") or key:match("relay") then return "redstone_relay" end
end

-- The computer's own modems are the way in, never a device (v1 listed only
-- what the wired modem saw on the network).
local function isModem(name) return hasType(name, "modem") end

local function names()
    local ok, list = pcall(peripheral.getNames)
    return ok and list or {}
end

-- The first peripheral on the network that is not known yet (the event's
-- own name first), or nil.
local function newDevice(known, hint)
    if hint and not known[hint] and not isModem(hint) then
        for _, n in ipairs(names()) do if n == hint then return n end end
    end
    local list = names()
    table.sort(list)
    for _, n in ipairs(list) do
        if not known[n] and not isModem(n) then return n end
    end
end

-- ------------------------------------------------------------ run

local function pull()
    return os.pullEventRaw()
end

-- Waits for any key; false on terminate.
local function anyKey()
    while true do
        local e = pull()
        if e == "key" then return true end
        if e == "terminate" then return false end
    end
end

-- opts.why: why it runs (shown on the first screen). Returns "ready" once
-- the assignments are written, "stop" on Ctrl+T.
function Wiz.run(root, opts)
    opts = opts or {}
    setupColors()
    local slot = Config.pickSlot(root)
    if not slot then error("no ship config in config/ (reinstall: config/atlas.lua is missing)", 0) end
    local ship, err = Config.readShip(slot)
    if not ship then error("config/" .. slot .. ".lua: " .. tostring(err), 0) end
    local file = Config.assignmentsPath(slot)
    local shipline = { { " Ship: ", col.dim }, { tostring(ship.name or slot), col.text },
        { "   config v" .. tostring(ship.version), col.dim } }
    U.log("wizard: started (%s)", tostring(opts.why or "asked for"))

    -- 1. a clean slate
    local lines = { shipline, {} }
    if opts.why then para(lines, "Why: " .. opts.why .. ".", col.warn) lines[#lines + 1] = {} end
    para(lines, "This names every relay and the cockpit monitor as this computer sees them on its network.")
    lines[#lines + 1] = {}
    para(lines, "Disconnect ALL modems from the computer first, so the scan starts clean. You reconnect them one at a time below.", col.accent)
    lines[#lines + 1] = {}
    para(lines, "When all modems are removed, press any key.", col.good)
    lines[#lines + 1] = {}
    para(lines, "(Ctrl+T stops the setup.)", col.dim)
    draw(lines)
    if not anyKey() then return "stop" end

    -- 2. what is still on the network is ignored from now on
    local known, baseline = {}, 0
    for _, n in ipairs(names()) do
        known[n] = true
        if not isModem(n) then baseline = baseline + 1 end
    end
    U.log("wizard: %d device(s) already connected (ignored)", baseline)

    local steps = Wiz.steps(ship)
    local rows = {}
    for _, st in ipairs(steps) do rows[#rows + 1] = st end
    local printer = { key = "printer", desc = DESC.printer, printer = true }
    rows[#rows + 1] = printer
    local assign = { config_version = ship.version, ship_id = ship.id }

    local function screen(cur, prompt)
        local W, H = size()
        local out = { { shipline[1], shipline[2], shipline[3],
            { "   " .. baseline .. " already on (ignored)", col.dim } }, {} }
        -- the role list, scrolled so the current row shows
        local room = math.max(H - 1 - #out - #prompt - 1, 1)
        local top = 1
        if cur and #rows > room then top = math.max(1, math.min(cur - math.floor(room / 2), #rows - room + 1)) end
        for i = top, math.min(#rows, top + room - 1) do
            local r = rows[i]
            local kw = 14
            if r.name then
                local warn = r.odd and ("  (" .. tostring(r.type) .. "?)") or ""
                out[#out + 1] = { { "  " .. fit(r.key, kw), col.good }, { r.name, col.name }, { warn, col.warn } }
            elseif i == cur then
                out[#out + 1] = { { "> " .. fit(r.key, kw), col.warn }, { "connect now", col.warn } }
            elseif r.skipped then
                out[#out + 1] = { { "  " .. fit(r.key, kw), col.dim }, { "skipped", col.dim } }
            else
                out[#out + 1] = { { "  " .. fit(r.key, kw), col.dim }, { fit(r.desc, W - kw - 3), col.dim } }
            end
        end
        out[#out + 1] = {}
        for _, l in ipairs(prompt) do out[#out + 1] = l end
        draw(out)
    end

    local function take(r, name)
        r.name, r.type = name, typeOf(name)
        local want = expected(r.key)
        r.odd = want and not hasType(name, want) or false
        known[name] = true
        assign[r.key] = name
        U.log("wizard: %s = %s (%s)%s", r.key, name, tostring(r.type), r.odd and " UNEXPECTED TYPE" or "")
    end

    -- 3. one device at a time
    for i, st in ipairs(steps) do
        local note
        local hint_timer = os.startTimer(Wiz.HINT_AFTER)
        local function prompt()
            local W = size()
            local p = {}
            local head = "[" .. i .. "/" .. #steps .. "] Connect: "
            local d = wrap(st.desc, W - #head - 1)
            p[#p + 1] = { { " " .. head, col.text }, { d[1], col.accent } }
            for k = 2, #d do p[#p + 1] = { { string.rep(" ", #head + 1) .. d[k], col.accent } } end
            p[#p + 1] = { { "  (", col.dim }, { st.target, col.name }, { " in config/" .. slot .. ".lua)", col.dim } }
            p[#p + 1] = { { " Plug in this device's modem, then right-click it.", col.text } }
            if note then
                for _, l in ipairs(wrap(note[1], W - 2)) do p[#p + 1] = { { " " .. l, note[2] } } end
            end
            return p
        end
        screen(i, prompt())
        local got = newDevice(known) -- one that attached while the screen was drawn
        while not got do
            local e, a = pull()
            if e == "terminate" then return "stop" end
            if e == "peripheral" then
                got = newDevice(known, a)
                if not got then
                    note = { known[a] and (a .. " was already there: ignored")
                        or (a .. " is a modem on the computer: ignored"), col.dim }
                    screen(i, prompt())
                end
            elseif e == "timer" and a == hint_timer then
                note = { "No new device yet - modem must be adjacent to the computer and right-clicked.", col.warn }
                screen(i, prompt())
            end
        end
        if os.cancelTimer then pcall(os.cancelTimer, hint_timer) end
        take(st, got)
    end

    -- 4. printer (flight reports): pinned if one is on the network or
    -- attached now; S skips (printing finds one by type later anyway)
    local function findPrinter()
        local list = names()
        table.sort(list)
        for _, n in ipairs(list) do if hasType(n, "printer") then return n end end
    end
    local pn = findPrinter()
    if not pn then
        local p = {
            { { " Optional: ", col.text }, { DESC.printer, col.accent } },
            { { " Plug in the printer's modem, then right-click it.", col.text } },
            { { " Press S to skip (auto-find works later).", col.dim } },
        }
        screen(#rows, p)
        while not pn do
            local e, a = pull()
            if e == "terminate" then return "stop" end
            if e == "peripheral" then
                pn = findPrinter()
            elseif e == "key" then
                local k = keys and keys.getName and keys.getName(a)
                if k == "s" or (keys and a == keys.s) then break end
            end
        end
    end
    if pn then take(printer, pn) else printer.skipped = true U.log("wizard: printer skipped") end

    -- 5. write it, then the OS
    if not Config.writeAssignments(slot, assign) then
        U.log("wizard: could not write %s", file)
        screen(nil, { { { " Could not write " .. file .. " (disk full?)", col.bad } } })
        -- the OS reads the names from that file: no point starting without it
        error("could not write " .. file .. " (disk full?)", 0)
    end
    U.log("wizard: assignments written to %s", file)
    local done = {
        { { " Assignments saved to ", col.text }, { file, col.good } },
        { { " Starting the flight OS...", col.accent } },
        { { " Wrong device? Hold Ctrl+T, then type v2/wizard", col.dim } },
    }
    for _, r in ipairs(rows) do
        if r.odd then
            done[#done + 1] = { { " (type?) = not the kind of device expected", col.warn } }
            break
        end
    end
    screen(nil, done)
    local t = os.startTimer(Wiz.DONE_WAIT)
    while true do
        local e, a = pull()
        if e == "terminate" then return "stop" end
        if (e == "timer" and a == t) or e == "key" then break end
    end
    setBg(col.bg)
    term.clear()
    term.setCursorPos(1, 1)
    return "ready"
end

return Wiz
