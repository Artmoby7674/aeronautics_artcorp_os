#!/usr/bin/env python3
"""Render every v2 UI screen to PNG (real v2 code, simulated flights),
plus the peripheral setup wizard's terminal screens (wizard.lua on a fake
51x19 ship-computer terminal, CC's stock colours).

    python3 tests/render_v2.py [outdir]     # default: hud_shots/v2/

Needs lupa + Pillow. Uses the v2 palette (v2/lib/ui/draw.lua), 3x zoom.
"""
import os
import sys

from lupa import LuaRuntime
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join("hud_shots", "v2")
os.makedirs(OUT, exist_ok=True)
ZOOM = 3

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('package.path = "./?.lua;./tests/v2/?.lua;" .. package.path')
lua.execute('SC = dofile("tests/v2/scene.lua").new()')
pal = lua.eval("SC.D.PALETTE")
PALETTE = [int(pal[i]) for i in range(16)]
# slots 16-31: the tour's dimmed copies of the 16 (draw.lua setDimPalette)
PALETTE += [int(lua.eval("SC.D.dimRGB")(v)) for v in PALETTE]


def snap(name):
    mon = lua.eval("SC.mon")
    W, H, fb = int(mon.W), int(mon.H), mon.fb
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            v = PALETTE[int(fb[y * W + x]) & 31]
            px[x, y] = ((v >> 16) & 255, (v >> 8) & 255, v & 255)
    img = img.resize((W * ZOOM, H * ZOOM), Image.NEAREST)
    path = os.path.join(OUT, name + ".png")
    img.save(path)
    errs = lua.eval("#SC.mon.errors")
    print(path, "" if errs == 0 else f"({errs} draw errors)")


lua.execute("""
function FRAME(world, tab, extra)
    SC.ui:setTab(tab)
    SC.ui:invalidate()
    SC.ui:render(SC.base(world, extra))
end
W_CRUISE = SC.cruise()
W_HOVER = SC.hover()
W_PARK = SC.parked()
""")
lua.execute('SC.ui:render({ power = "off", name = "Atlas", fl = W_PARK.fl, missing = {} })')
snap("00_splash")
lua.execute('SC.ui:render({ power = "booting", boot_frac = 0.55, boot_step = "SPINNING UP", name = "Atlas", fl = W_PARK.fl, missing = {} })')
snap("01_booting")
lua.execute('SC.ui.screen = nil')
lua.execute('FRAME(W_CRUISE, "fly", { msg = "A/P TO NORTHFIELD" })')
snap("02_fly_cruise")
lua.execute('FRAME(W_HOVER, "fly")')
snap("03_fly_hover")
lua.execute('SC.ui.sel = 2 FRAME(W_CRUISE, "nav")')
snap("04_nav")
lua.execute('FRAME(W_CRUISE, "auto")')
snap("05_auto")
lua.execute('FRAME(W_HOVER, "auto", { last_ap = "LAST ROUTE: ARRIVED AT MINE" })')
snap("06_auto_idle")
lua.execute('FRAME(W_CRUISE, "ship")')
snap("07_ship")
lua.execute("""FRAME(W_HOVER, "alert", { alerts_bad = true, alerts = {
    { level = "bad", text = "E-STOP: ALL LIFT CUT", hint = "SPACE RESETS" },
    { level = "warn", text = "LOW LIFT MARGIN", hint = "1.2/15" },
    { level = "info", text = "KEYBOARD COMPUTER OFFLINE", hint = "OPTIONAL" } } })""")
snap("08_alerts")
lua.execute('FRAME(W_HOVER, "alert")')
snap("09_alerts_clear")
lua.execute('FRAME(W_HOVER, "ctrl", { rec = true, rec_t = 125, rec_n = 25 })')
snap("10_ctrl")
lua.execute('FRAME(W_PARK, "fly")')
snap("11_fly_parked")
# the tour, every step, over the engines-off ship
lua.execute('SC.ui.screen = nil SC.ui:setTab("fly") SC.ui:tourStart() TOUR_M = SC.base(W_PARK, { power = "off" })')
n = int(lua.eval("#SC.ui.TOUR or #require('ui').TOUR"))
for i in range(1, n + 1):
    lua.execute("SC.ui:render(TOUR_M)")
    snap(f"{11 + i}_tour_{i:02d}")
    lua.execute("SC.ui:tourNext()")


# the peripheral setup wizard, on the ship computer's terminal
CC_COLOURS = {1: 0xF0F0F0, 2: 0xF2B233, 4: 0xE57FD8, 8: 0x99B2F2, 16: 0xDEDE6C, 32: 0x7FCC19, 64: 0xF2B2CC,
              128: 0x4C4C4C, 256: 0x999999, 512: 0x4C99B2, 1024: 0xB266E5, 2048: 0x3366CC, 4096: 0x7F664C,
              8192: 0x57A64E, 16384: 0xCC4C4C, 32768: 0x111111}
lua.execute("""
WSHOTS = {}
local T = dofile("tests/v2/term.lua").new()
local saved = { term = rawget(_G, "term"), colors = rawget(_G, "colors"), keys = rawget(_G, "keys"),
    peripheral = rawget(_G, "peripheral"), startTimer = os.startTimer, cancelTimer = os.cancelTimer,
    pullEventRaw = os.pullEventRaw }
_G.term = T.api
_G.colors = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32, pink = 64, gray = 128,
    lightGray = 256, cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768 }
_G.keys = { s = 31, getName = function(c) return c == 31 and "s" or nil end }
local net = { back = "modem", drive_0 = "drive" }
_G.peripheral = { getNames = function() local o = {} for n in pairs(net) do o[#o + 1] = n end return o end,
    getType = function(n) return net[n] end }
local tid = 0
os.startTimer = function() tid = tid + 1 return tid end
os.cancelTimer = function() end
local function shot(name) WSHOTS[#WSHOTS + 1] = { name = name, c = T.cells() } end
local keysOrder = { "input_1", "input_2", "aux_relay", "engine_relay", "output_FL", "output_FR", "output_RL",
    "output_RR", "output_REAR", "main_monitor" }
local script = { function() shot("intro") return { "key", 28 } end }
for i, k in ipairs(keysOrder) do
    script[#script + 1] = function()
        if i == 1 then shot("step_01") end
        if i == 4 then return { "timer", tid } end -- the hint, then the relay
        if i == 10 then shot("step_10_monitor") end
        local n = k == "main_monitor" and "monitor_2" or ("redstone_relay_" .. (i + 2))
        net[n] = k == "main_monitor" and "monitor" or "redstone_relay"
        return { "peripheral", n }
    end
    if i == 4 then
        script[#script + 1] = function()
            shot("step_04_hint")
            net.redstone_relay_6 = "redstone_relay"
            return { "peripheral", "redstone_relay_6" }
        end
    end
end
script[#script + 1] = function() shot("printer") return { "key", 31 } end
script[#script + 1] = function() shot("done") return { "key", 28 } end
os.pullEventRaw = function() local f = table.remove(script, 1) if not f then return "terminate" end return table.unpack(f()) end
package.path = "./v2/lib/?.lua;" .. package.path
local Config = require("config")
Config.pickSlot = function() return "atlas" end
Config.readShip = function() return dofile("config/atlas.lua") end
Config.writeAssignments = function() return true end
WRESULT = require("wizard").run("v2", { why = "no peripheral assignments yet" })
_G.term, _G.colors, _G.keys, _G.peripheral = saved.term, saved.colors, saved.keys, saved.peripheral
os.startTimer, os.cancelTimer, os.pullEventRaw = saved.startTimer, saved.cancelTimer, saved.pullEventRaw
""")
from PIL import ImageDraw, ImageFont
try:
    FONT = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 15)
except OSError:
    FONT = ImageFont.load_default()
CW, CH = 12, 18
shots = lua.eval("WSHOTS")
for k in range(1, int(lua.eval("#WSHOTS")) + 1):
    sh = shots[k]
    c = sh.c
    W, H = int(c.W), int(c.H)
    img = Image.new("RGB", (W * CW + 16, H * CH + 16), (0x11, 0x11, 0x11))
    dr = ImageDraw.Draw(img)
    for pass_ in (0, 1):  # backgrounds first: a glyph's tail (_) may reach into the next row
        for y in range(1, H + 1):
            row = c.rows[y]
            for x in range(1, W + 1):
                key = y * 100 + x
                x0, y0 = 8 + (x - 1) * CW, 8 + (y - 1) * CH
                if pass_ == 0:
                    bg = CC_COLOURS.get(int(c.bg[key] or 32768), 0x111111)
                    dr.rectangle([x0, y0, x0 + CW - 1, y0 + CH - 1], fill=((bg >> 16) & 255, (bg >> 8) & 255, bg & 255))
                elif row[x - 1] != " ":
                    fg = CC_COLOURS.get(int(c.fg[key] or 1), 0xF0F0F0)
                    dr.text((x0 + 1, y0), row[x - 1], font=FONT, fill=((fg >> 16) & 255, (fg >> 8) & 255, fg & 255))
    path = os.path.join(OUT, f"w{k}_wizard_{sh.name}.png")
    img.save(path)
    print(path)
print("wizard:", lua.eval("WRESULT"))
