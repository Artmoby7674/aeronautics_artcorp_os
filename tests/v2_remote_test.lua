-- v2 ArtCorp fleet remote: the protocol module (v2/lib/remote.lua) and the
-- flight-side takeover behaviour (grounded lock, uncancelable summon).
package.path = "./tests/v2/?.lua;./v2/lib/?.lua;" .. package.path
local World = dofile("tests/v2/world.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1 else
        failed = failed + 1
        print("FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end

-- ---------------------------------------------------------------- protocol
do
    -- fake rednet that records what the ship sends back
    local sent = {}
    local saved_rednet, saved_os = rawget(_G, "rednet"), os.getComputerID
    _G.rednet = { send = function(to, m, proto) sent[#sent + 1] = { to = to, m = m, proto = proto } return true end }
    os.getComputerID = function() return 7 end
    package.loaded["remote"] = nil
    local Remote = require("remote")

    local got
    Remote.init({
        snapshot = function() return { name = "ATLAS", slot = "atlas", phase = "flying", locked = false, x = 10, y = 90, z = -5 } end,
        onCommand = function(cmd) got = cmd return "ATLAS" end,
    })

    -- scan -> a "here" reply with the ship's identity
    Remote.onRednet(42, { proto = "artcorp", op = "scan" })
    local reply = sent[1]
    check("scan: replies to the sender", reply and reply.to == 42, reply and reply.to)
    check("scan: reply is 'here' with name + id", reply and reply.m.op == "here" and reply.m.name == "ATLAS" and reply.m.id == 7)
    check("scan: reply carries phase + position", reply and reply.m.phase == "flying" and reply.m.x == 10 and reply.m.z == -5)

    -- a command is passed through and acked
    sent = {}
    Remote.onRednet(42, { proto = "artcorp", op = "cmd", cmd = "summon", x = 100, z = 200 })
    check("cmd: onCommand got it", got and got.cmd == "summon" and got.x == 100 and got.z == 200 and got.by == 42)
    check("cmd: acked ok with the ship name", sent[1] and sent[1].m.op == "ack" and sent[1].m.ok == true and sent[1].m.name == "ATLAS")

    -- a foreign protocol is ignored
    got = nil
    Remote.onRednet(42, { proto = "something", op = "cmd", cmd = "estop" })
    check("ignores other protocols", got == nil)

    _G.rednet, os.getComputerID = saved_rednet, saved_os
end

-- ---------------------------------------------------------------- grounded lock
do
    local w = World.new()
    check("starts parked", w.fl.phase == "parked", w.fl.phase)
    w.fl.lock = { mode = "grounded", reason = "estop" }
    w:tap("SPACE")           -- pilot tries to take off
    w:run(3)
    check("grounded lock: SPACE does not take off", w.fl.phase == "parked", w.fl.phase)
    -- released: now it flies
    w.fl.lock = nil
    w:tap("SPACE")
    w:run(3)
    check("released: take off works again", w.fl.phase == "flying", w.fl.phase)
end

-- ---------------------------------------------------------------- summon
do
    local w = World.new():airborne(120, 0)
    w.fl.ctl.roll_known, w.fl.ctl.pitch_known = 1, 1
    w.fl.calib = nil
    w.fl:remoteSummon(-400, 300) -- come to the CEO
    check("summon: autopilot engaged and locked", w.fl.ap ~= nil and w.fl.ap.locked == true)

    -- the pilot mashes every control; the autopilot must NOT cancel
    local start = w.fl.ap
    for _ = 1, 6 do
        for _, k in ipairs({ "SPACE", "CTRL", "W", "S", "Q", "E" }) do w:tap(k, 0.1) end
    end
    check("summon: pilot cannot cancel it", w.fl.ap == start, tostring(w.fl.ap))

    -- and it actually makes progress toward the CEO
    local d0 = math.sqrt((w:truth().x + 400) ^ 2 + (w:truth().z - 300) ^ 2)
    w:run(60)
    local d1 = math.sqrt((w:truth().x + 400) ^ 2 + (w:truth().z - 300) ^ 2)
    check("summon: flies toward the target", d1 < d0 - 50, string.format("%.0f -> %.0f", d0, d1))
end

-- ---------------------------------------------------------------- estop
do
    local w = World.new():airborne(120, 0)
    w.fl.ap = { update = function() return { alt = 120 } end, cancel = function() end }
    w.fl:setEstop(true)
    check("estop: phase is estop", w.fl.phase == "estop", w.fl.phase)
    check("estop: autopilot dropped", w.fl.ap == nil)
    w:run(2)
    local o = w.sim:readOutputs()
    check("estop: lift props cut", (o.FL or 0) == 0 and (o.FR or 0) == 0, o.FL)
end

print(string.format("v2_remote_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_remote_test FAILED", 0) end
