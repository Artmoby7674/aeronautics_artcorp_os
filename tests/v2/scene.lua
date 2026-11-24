-- Builds realistic UI models from a simulated flight, for the UI test and the
-- screenshot renderer. Returns { ui = UI, mon = monitor, frames = { name -> fn } }.
package.path = "./v2/lib/ui/?.lua;" .. package.path
local World = dofile("tests/v2/world.lua")
local Mon = require("monitor")
package.loaded.draw, package.loaded.ui, package.loaded.font = nil, nil, nil
local D = require("draw")
local UI = require("ui")
local AP = require("ap")

local Scene = {}

function Scene.new()
    local mon = Mon.new()
    D.init(mon, true)
    local ui = UI.new()
    local sc = { mon = mon, ui = ui, D = D }

    local wps = {
        { name = "HOME", x = 10, z = 20, heading = 90 },
        { name = "NORTHFIELD", x = 1200, z = -800, heading = 200 },
        { name = "MINE", x = -455, z = 88, heading = 270 },
        { name = "REACTOR", x = -2150, z = 1644, heading = 255 },
    }

    local function base(w, extra)
        local fl = w.fl
        local m = {
            power = "on", name = "Atlas", fl = fl, s = fl.est.s, wps = wps,
            alerts = {}, kbd = true, loop = { ms = 50.2 }, disk = 612000,
            missing = {}, clutch = true, rec = false, rec_n = 0, rec_t = 0,
        }
        if fl.ap then
            m.ap = fl.ap:status()
            m.ap.x, m.ap.z = fl.ap.wp.x, fl.ap.wp.z
        end
        for k, v in pairs(extra or {}) do m[k] = v end
        return m
    end

    -- a cruising ship mid-trip, banked a little
    function sc.cruise()
        local w = World.new({ sim = { drag = 0.08, rear_dz = 0.4 } })
        w:startAP(wps[2])
        w:run(70)
        return w
    end
    function sc.hover()
        local w = World.new():airborne(132, 40)
        w.sim.vel.x = 2
        w:run(3)
        return w
    end
    function sc.parked()
        return World.new()
    end
    sc.wps = wps
    sc.base = base
    return sc
end

return Scene
