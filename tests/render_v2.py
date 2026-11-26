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
lua.execute("""SC.ui.slot_sel = 2
FRAME(W_PARK, "slots", { slot = "atlas", msg = "NEW SLOT SHIP2: COPY OF ATLAS", slots = {
    { id = "atlas", wired = true }, { id = "ship2", wired = true }, { id = "cargo", wired = false } } })""")
snap("12_slots")

# first-launch setup screens (onboard.lua state, drawn by UI:onboard)
lua.execute("""
OB = require("onboard")
function OBF(ob) SC.ui.screen = nil SC.ui:render({ ob = ob }) end
RELAYS = { { name = "relay_1", used = true, tag = "USED: KEYS W A S D", tag_color = SC.D.C.dim },
    { name = "relay_2", used = true, tag = "USED: KEYS Q E SPACE CTRL", tag_color = SC.D.C.dim },
    { name = "relay_3" }, { name = "relay_4" }, { name = "relay_5" }, { name = "relay_6" },
    { name = "relay_7" }, { name = "relay_aux" }, { name = "relay_eng" } }
""")
lua.execute('OBF({ screen = "welcome", rev = 1 })')
snap("13_setup_welcome")
lua.execute("""OBF({ screen = "role", rev = 1, idx = 3, total = 10, scroll = 3, sel = 8,
    msg = "TESTING RELAY_AUX: WATCH THE LANDING GEAR", msg_color = SC.D.C.accent, cands = RELAYS,
    role = { key = "aux_relay", label = "AUX RELAY", type = "redstone_relay", optional = true, test_label = "TEST",
        desc = "MOVES THE LANDING GEAR, READS THE GROUND SENSOR AND THE SHIFT KEY." } })""")
snap("14_setup_role")
lua.execute("""OBF({ screen = "role", rev = 1, idx = 1, total = 10, scroll = 0, sel = 1,
    msg = "FOUND IT: RELAY_1", msg_color = SC.D.C.good,
    cands = { { name = "relay_1", tag = "SIGNAL", tag_color = SC.D.C.good }, { name = "relay_2" }, { name = "relay_3" } },
    role = { key = "input_1", label = "KEYS W A S D", type = "redstone_relay", test_label = "DETECT", test_any = true,
        desc = "READS THE TYPEWRITER'S W, A, S AND D KEYS: FORWARD, BACK AND TURNING." } })""")
snap("15_setup_role_detect")
lua.execute("""OBF({ screen = "role", rev = 1, idx = 10, total = 10, scroll = 0, cands = {},
    role = { key = "main_monitor", label = "COCKPIT SCREEN", type = "monitor", test_label = "SHOW",
        desc = "THE TOUCHSCREEN THE PILOT USES: USUALLY THE ONE YOU ARE TAPPING NOW." } })""")
snap("16_setup_role_none")
lua.execute('OBF({ screen = "guide", rev = 1, gi = 1, gn = #OB.GUIDE, card = OB.GUIDE[1] })')
snap("17_setup_guide_1")
lua.execute('OBF({ screen = "guide", rev = 1, gi = 4, gn = #OB.GUIDE, card = OB.GUIDE[4] })')
snap("18_setup_guide_4")
lua.execute('OBF({ screen = "busy", rev = 1, title = "SHIP LOADED", msg = "RESTARTING ON CARGO...", msg_color = SC.D.C.good })')
snap("19_setup_import")

# the tour, every step, over the engines-off ship
lua.execute('SC.ui.screen = nil SC.ui:setTab("fly") SC.ui:tourStart() TOUR_M = SC.base(W_PARK, { power = "off" })')
n = int(lua.eval("#SC.ui.TOUR or #require('ui').TOUR"))
for i in range(1, n + 1):
    lua.execute("SC.ui:render(TOUR_M)")
    snap(f"{19 + i}_tour_{i:02d}")
    lua.execute("SC.ui:tourNext()")
