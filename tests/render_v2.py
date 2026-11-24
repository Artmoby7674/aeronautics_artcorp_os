#!/usr/bin/env python3
"""Render every v2 UI screen to PNG (real v2 code, simulated flights).

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


def snap(name):
    mon = lua.eval("SC.mon")
    W, H, fb = int(mon.W), int(mon.H), mon.fb
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            v = PALETTE[int(fb[y * W + x]) & 15]
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
