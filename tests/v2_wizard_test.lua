-- The peripheral setup wizard (v2/lib/wizard.lua), ported from the original
-- OS: a fake computer whose modems were all disconnected, a player plugging
-- the devices in one at a time (attach events), and the assignments file it
-- writes, loaded back through Config.load.
package.path = "./v2/lib/?.lua;./tests/v2/?.lua;" .. package.path
for _, m in ipairs({ "wizard", "config", "util", "version" }) do package.loaded[m] = nil end

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1 else
        failed = failed + 1
        print("FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end

-- ---------------------------------------------------------------- fakes
local saved = { fs = rawget(_G, "fs"), peripheral = rawget(_G, "peripheral"), term = rawget(_G, "term"),
    loadfile = loadfile, dofile = dofile, textutils = rawget(_G, "textutils"), keys = rawget(_G, "keys"),
    colors = rawget(_G, "colors"), startTimer = os.startTimer, cancelTimer = os.cancelTimer,
    pullEventRaw = os.pullEventRaw, shell = rawget(_G, "shell") }

local function readReal(p) local f = io.open(p, "r") local d = f:read("a") f:close() return d end
local files = {}
local function reset()
    files = {
        ["config/atlas.lua"] = readReal("config/atlas.lua"),
        ["v2/tune.lua"] = readReal("v2/tune.lua"),
    }
end
reset()
_G.fs = {
    exists = function(p) if files[p] then return true end
        for k in pairs(files) do if k:sub(1, #p + 1) == p .. "/" then return true end end
        return false end,
    isDir = function(p) for k in pairs(files) do if k:sub(1, #p + 1) == p .. "/" then return true end end return false end,
    makeDir = function() end,
    list = function(d)
        local out = {}
        for p in pairs(files) do
            local rest = p:match("^" .. d:gsub("%p", "%%%0") .. "/([^/]+)$")
            if rest then out[#out + 1] = rest end
        end
        return out
    end,
    delete = function(p) files[p] = nil end,
    move = function(a, b) files[b] = files[a] files[a] = nil end,
    getSize = function(p) return #(files[p] or "") end,
    open = function(p, mode)
        if mode == "r" then
            if not files[p] then return nil end
            local d = files[p]
            return { readAll = function() return d end, close = function() end }
        end
        if files.readonly then return nil end
        local buf = { mode == "a" and files[p] or nil }
        return { write = function(s) buf[#buf + 1] = s end, writeLine = function(s) buf[#buf + 1] = s .. "\n" end,
            close = function() files[p] = table.concat(buf) end }
    end,
}
_G.loadfile = function(path, mode, env)
    local d = files[path]
    if not d then return nil, "no file " .. path end
    return load(d, "@" .. path, "t", env or _G)
end
_G.dofile = function(path)
    local fn = _G.loadfile(path)
    if not fn then return saved.dofile(path) end
    return fn()
end
_G.textutils = { serialize = function() return "{}" end, formatTime = function(t) return tostring(t) end }
_G.colors = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32, pink = 64, gray = 128,
    lightGray = 256, cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768 }
_G.keys = { s = 31, enter = 28, getName = function(c) return ({ [31] = "s", [28] = "enter" })[c] end }

-- the network: name -> type
local net = {}
_G.peripheral = {
    getNames = function()
        local out = {}
        for n in pairs(net) do out[#out + 1] = n end
        return out
    end,
    getType = function(n) return net[n] end,
    wrap = function(n) return net[n] and {} or nil end,
}

-- events: a script of functions run in order; each returns an event
local script, timers, tid = {}, {}, 0
os.startTimer = function(s) tid = tid + 1 timers[#timers + 1] = { id = tid, s = s } return tid end
os.cancelTimer = function() end
os.pullEventRaw = function()
    local fn = table.remove(script, 1)
    if not fn then return "terminate" end -- ran out: the test is wrong, don't hang
    return table.unpack(fn())
end
local function plug(name, ty) return function() net[name] = ty return { "peripheral", name } end end
local function key(k) return function() return { "key", k } end end
local function hintTimer() return function() return { "timer", timers[#timers].id } end end

local TermF = require("term")
local Wiz = require("wizard")
local Config = require("config")

-- ---------------------------------------------------------------- order and checks
local ship = Config.readShip("atlas")
local steps = Wiz.steps(ship)
local order = {}
for _, st in ipairs(steps) do order[#order + 1] = st.key end
check("steps: the original order", table.concat(order, " ") ==
    "input_1 input_2 aux_relay engine_relay output_FL output_FR output_RL output_RR output_REAR main_monitor",
    table.concat(order, " "))
check("steps: the original descriptions", steps[4].desc == "Engine relay: LEFT=start, RIGHT=clutch; front/back=tab up/down"
    and steps[10].desc == "HUD display monitor")
local extra = Wiz.steps({ peripherals = { input_1 = "a", main_monitor = "m" }, optional_peripherals = { "speaker", "input_1" } })
check("steps: optional ones the config lists come last, once", #extra == 3 and extra[3].key == "speaker" and extra[3].optional)

local function needed() return Wiz.needed("v2") end
local need, why = needed()
check("needed: no assignments file", need and why == "no peripheral assignments yet", why)
files["config/assignments_atlas.lua"] = "return { config_version = \"1.1\", input_1 = \"x\" }"
need, why = needed()
check("needed: another config version", need and why:find("config v1.1 -> v1.2", 1, true) ~= nil, why)
local partial = { "return { config_version = \"1.2\"," }
for _, k in ipairs(order) do if k ~= "engine_relay" then partial[#partial + 1] = string.format("[%q] = \"r_%s\",", k, k) end end
files["config/assignments_atlas.lua"] = table.concat(partial) .. "}"
need, why = needed()
check("needed: a role missing", need and why:find("missing engine_relay", 1, true) ~= nil, why)
files["config/assignments_atlas.lua"] = "return {"
check("needed: an unreadable file", (needed()))
files["config/assignments_atlas.lua"] = nil

-- ---------------------------------------------------------------- a full run
-- Still on the network after "disconnect all": the computer's own modem
-- (back) and a disk drive. On the way the player re-clicks the drive, puts
-- a new modem on the computer, waits long enough for the hint, plugs in a
-- disk drive for the engine relay (wrong type: taken, flagged), connects two
-- props at once, and finally a printer.
local T = TermF.new()
_G.term = T.api
net = { back = "modem", drive_0 = "drive" }
local WORLD = {
    input_1 = "redstone_relay_3", input_2 = "redstone_relay_4", aux_relay = "redstone_relay_9",
    engine_relay = "drive_1", output_FL = "redstone_relay_10", output_FR = "redstone_relay_11",
    output_RL = "redstone_relay_12", output_RR = "redstone_relay_13", output_REAR = "redstone_relay_14",
    main_monitor = "monitor_2",
}
local shots = {}
local function step(fn) script[#script + 1] = fn end
step(function() shots.intro = T.text() return { "key", 28 } end)
step(function() shots.first = T.text() return { "peripheral", "drive_0" } end) -- re-clicked: was already there
step(function() shots.ignored = T.text() net.left = "modem" return { "peripheral", "left" } end) -- a modem on the computer
step(function() shots.modem = T.text() return hintTimer()() end)
step(function() shots.hint = T.text() return { "char", "x" } end)
step(plug(WORLD.input_1, "redstone_relay"))
step(plug(WORLD.input_2, "redstone_relay"))
step(function() net[WORLD.input_1] = nil return { "peripheral_detach", WORLD.input_1 } end)
step(function() net[WORLD.input_1] = "redstone_relay" return { "peripheral", WORLD.input_1 } end) -- re-clicked: ignored
step(plug(WORLD.aux_relay, "redstone_relay"))
step(plug(WORLD.engine_relay, "drive"))
step(function() -- two props at once: the event's one first, the other next step
    net[WORLD.output_FR] = "redstone_relay"
    net[WORLD.output_FL] = "redstone_relay"
    return { "peripheral", WORLD.output_FL }
end)
step(plug(WORLD.output_RL, "redstone_relay"))
step(plug(WORLD.output_RR, "redstone_relay"))
step(plug(WORLD.output_REAR, "redstone_relay"))
step(function() shots.monitor = T.text() net[WORLD.main_monitor] = "monitor" return { "peripheral", WORLD.main_monitor } end)
step(function() shots.printer = T.text() net.printer_0 = "printer" return { "peripheral", "printer_0" } end)
step(function() shots.done = T.text() return { "timer", timers[#timers].id } end)

local r = Wiz.run("v2", { why = "no peripheral assignments yet" })
check("run: ready", r == "ready", r)
check("run: every scripted event used", #script == 0, #script)
check("intro: disconnect all modems first", shots.intro and shots.intro:find("Disconnect ALL modems from the computer first", 1, true) ~= nil, shots.intro)
check("intro: any key", shots.intro and shots.intro:find("When all modems are removed, press any key.", 1, true) ~= nil)
check("intro: says why", shots.intro and shots.intro:find("no peripheral assignments yet", 1, true) ~= nil)
check("intro: names the ship", shots.intro and shots.intro:find("Ship: Atlas", 1, true) ~= nil)
check("step 1: asks for the WASD relay", shots.first and shots.first:find("[1/10] Connect: Typewriter relay for WASD keys", 1, true) ~= nil, shots.first)
check("step 1: plug in, right-click", shots.first and shots.first:find("Plug in this device's modem, then right-click it.", 1, true) ~= nil)
check("step 1: the drive left on is counted and ignored", shots.first and shots.first:find("1 already on (ignored)", 1, true) ~= nil, shots.first)
check("step 1: the role list shows what comes", shots.first and shots.first:find("main_monitor", 1, true) ~= nil
    and shots.first:find("> input_1", 1, true) ~= nil)
check("re-clicked old device: ignored, said so", shots.ignored and shots.ignored:find("drive_0 was already there: ignored", 1, true) ~= nil, shots.ignored)
check("hint after a while", shots.hint and shots.hint:find("No new device yet", 1, true) ~= nil, shots.hint)
check("modem on the computer: ignored, said so", shots.modem and shots.modem:find("left is a modem on the computer: ignored", 1, true) ~= nil, shots.modem)
check("step 10: the monitor", shots.monitor and shots.monitor:find("[10/10] Connect: HUD display monitor", 1, true) ~= nil, shots.monitor)
check("wrong type: flagged on screen", shots.monitor and shots.monitor:find("drive_1  (drive?)", 1, true) ~= nil, shots.monitor)
check("printer step: offered", shots.printer and shots.printer:find("Network printer (flight reports)", 1, true) ~= nil
    and shots.printer:find("Press S to skip", 1, true) ~= nil, shots.printer)
check("done: file named", shots.done and shots.done:find("config/assignments_atlas.lua", 1, true) ~= nil, shots.done)
check("done: OS starts next", shots.done and shots.done:find("Starting the flight OS", 1, true) ~= nil)
check("screen: nothing past the right edge", T.overflow == nil, T.overflow)
check("screen: nothing below the bottom", (function()
    for _, s in ipairs(T.seen) do local n = select(2, s:gsub("\n", "")) if n + 1 > T.H then return false end end
    return true
end)())

local src = files["config/assignments_atlas.lua"] or ""
check("file: written", src ~= "")
check("file: config_version first, original layout", src:match("^return {\n  config_version = \"1.2\",\n") ~= nil, src)
check("file: one line per role", src:find("  [\"input_1\"] = \"redstone_relay_3\",\n", 1, true) ~= nil, src)
check("file: printer pinned like v1", src:find("[\"printer\"] = \"printer_0\"", 1, true) ~= nil)
check("file: the old drive and modems not assigned", not src:find("drive_0", 1, true) and not src:find("\"left\"", 1, true)
    and not src:find("\"back\"", 1, true))
local cfg, err = Config.load("v2")
check("Config.load: loads", cfg ~= nil, err)
if cfg then
    local p = cfg.ship.peripherals
    local bad = {}
    for k, v in pairs(WORLD) do if p[k] ~= v then bad[#bad + 1] = k .. "=" .. tostring(p[k]) end end
    check("Config.load: every role on its world name (two at once in order, wrong type kept)", #bad == 0, table.concat(bad, " "))
    check("Config.load: printer not a must-have peripheral", p.printer == nil)
end
check("compatible after the run", not (needed()))

-- ---------------------------------------------------------------- skip the printer, stop
reset()
net = { back = "modem" }
T = TermF.new()
_G.term = T.api
script = { key(28) }
for i, k in ipairs(order) do script[#script + 1] = plug("dev_" .. i, k == "main_monitor" and "monitor" or "redstone_relay") end
script[#script + 1] = function() return { "peripheral", "drive_5" } end -- not a printer, not on the net: nothing
script[#script + 1] = key(31) -- S
script[#script + 1] = key(28) -- any key: start now
r = Wiz.run("v2", {})
check("skip printer: ready", r == "ready" and #script == 0, tostring(r) .. " " .. #script)
src = files["config/assignments_atlas.lua"] or ""
check("skip printer: no printer line", src ~= "" and not src:find("printer", 1, true), src)
check("skip printer: compatible", not (needed()))

reset()
T = TermF.new()
_G.term = T.api
net = {}
script = { key(28), plug("dev_1", "redstone_relay"), function() return { "terminate" } end }
r = Wiz.run("v2", {})
check("Ctrl+T: stops, nothing written", r == "stop" and files["config/assignments_atlas.lua"] == nil, r)
script = { function() return { "terminate" } end }
check("Ctrl+T on the first screen: stops", Wiz.run("v2", {}) == "stop")

-- a printer already on the network is pinned without asking
reset()
net = { printer_7 = "printer" }
script = { key(28) }
for i in ipairs(order) do script[#script + 1] = plug("dev_" .. i, "redstone_relay") end
script[#script + 1] = key(28)
r = Wiz.run("v2", {})
check("printer already there: pinned, not asked", r == "ready" and #script == 0
    and (files["config/assignments_atlas.lua"] or ""):find("printer_7", 1, true) ~= nil)

-- ---------------------------------------------------------------- re-run by hand
-- v2/wizard (shell program): asks again even though the file is fine, then
-- starts the OS through /startup
local ran
_G.shell = { run = function(p) ran = p return true end }
net = { back = "modem" }
script = { key(28) }
for i in ipairs(order) do script[#script + 1] = plug("again_" .. i, "redstone_relay") end
script[#script + 1] = key(31)
script[#script + 1] = key(28)
local path = package.path
dofile("v2/wizard.lua")
package.path = path
check("v2/wizard: asked again and rewrote the file", (files["config/assignments_atlas.lua"] or ""):find("again_1", 1, true) ~= nil)
check("v2/wizard: then starts the OS", ran == "/startup", ran)

-- ---------------------------------------------------------------- restore
_G.fs, _G.peripheral, _G.term, _G.textutils = saved.fs, saved.peripheral, saved.term, saved.textutils
_G.loadfile, _G.dofile, _G.keys, _G.colors, _G.shell = saved.loadfile, saved.dofile, saved.keys, saved.colors, saved.shell
os.startTimer, os.cancelTimer, os.pullEventRaw = saved.startTimer, saved.cancelTimer, saved.pullEventRaw
for _, m in ipairs({ "wizard", "config", "util", "version", "term" }) do package.loaded[m] = nil end
print(string.format("v2_wizard_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_wizard_test FAILED", 0) end
