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
""")
lua.execute('OBF({ screen = "welcome", rev = 1 })')
snap("13_setup_welcome")
lua.execute('OBF({ screen = "engines", rev = 1 })')
snap("14_setup_engines")
lua.execute("""OBF({ screen = "role", rev = 1, idx = 1, total = 2, scroll = 0, sel = 1, head = "SHIP SETUP: KEYS",
    next_label = "NEXT >", msg = "FOUND IT: RELAY_1", msg_color = SC.D.C.good,
    cands = { { name = "relay_1", tag = "SIGNAL", tag_color = SC.D.C.good }, { name = "relay_2" }, { name = "relay_3" } },
    role = { key = "input_1", label = "KEYS W A S D", type = "redstone_relay", test_label = "DETECT", test_any = true,
        desc = "READS THE TYPEWRITER'S W, A, S AND D KEYS: FORWARD, BACK AND TURNING." } })""")
snap("15_setup_keys_detect")
lua.execute("""PV = {
    { id = "FL", label = "FRONT-LEFT", sub = "PROP 2/3" }, { id = "FR", label = "FRONT-RIGHT", sub = "PROP 0/3" },
    { id = "RL", label = "REAR-LEFT", sub = "DONE", done = true }, { id = "RR", label = "REAR-RIGHT", sub = "PROP 1/3" },
    { id = "REAR", label = "REAR", sub = "THRUSTER 0/3" }, { id = "GEAR", label = "LANDING", sub = "DONE", done = true },
    { id = "ENGINE", label = "ENGINE /", sub = "PROPS SPIN" }, { id = "NOTHING", label = "NOTHING", sub = "NO CHANGE" } }
OBF({ screen = "fire", rev = 1, phase = 1, firing = false, known_n = 6, known_total = 17, pv = PV,
    cur = { relay = "relay_5", face = "left" }, hint = "WATCH THE SHIP: A 0.5 S FLIP. PROPS TURNING = ENGINE.",
    msg = "RELAY_3 FRONT = FRONT-LEFT PROP TILT FORWARD", msg_color = SC.D.C.good })""")
snap("16_setup_fire")
lua.execute("""OBF({ screen = "fire", rev = 1, phase = 2, firing = true, known_n = 11, known_total = 17, pv = PV, part = "FL",
    cur = { relay = "relay_3", face = "left" }, hint = "SPIN TEST: CLUTCH IN, THIS FACE AT LOW SPEED FOR 2 S.",
    choices = { { label = "TILTED", sub = "FORWARD", slot = "tilt_fwd" }, { label = "TILTED", sub = "BACK", slot = "tilt_bwd" },
        { label = "CHANGED", sub = "SPEED", slot = "speed" } } })""")
snap("17_setup_fire_what")
lua.execute("""local function F(a, b, c, s) return { { lbl = "F", face = a, seen = true }, { lbl = "B", face = b, seen = true },
    { lbl = "S", face = c, seen = s ~= false } } end
OBF({ screen = "review", rev = 1, known_n = 16, known_total = 17, can_next = true, rows = {
    { label = "FRONT-LEFT", relay = "relay_3", faces = F("front", "back", "left") },
    { label = "FRONT-RIGHT", relay = "relay_4", faces = F("front", "back", "right") },
    { label = "REAR-LEFT", relay = "relay_5", faces = F("front", "back", "left") },
    { label = "REAR-RIGHT", relay = "relay_6", faces = F("front", "back", "right") },
    { label = "REAR THRUST", relay = "relay_7", faces = { { lbl = "FW", face = "front", seen = true },
        { lbl = "BW", face = "back", seen = true }, { lbl = "REV", face = "top", seen = false } } },
    { label = "GEAR", relay = "relay_aux", faces = { { lbl = "", face = "front", seen = true } } },
    { label = "CLUTCH", relay = "relay_eng", faces = { { lbl = "", face = "right", seen = true } } } } })""")
snap("18_setup_found")
lua.execute("""OBF({ screen = "press", rev = 1, pi = 1, pn = 5, msg = "FOUND IT: THE LEFT FACE", msg_color = SC.D.C.good,
    press = { found = "left", item = { label = "ENGINE OFF BUTTON", relay = "relay_eng", tpl = "left",
        desc = "PRESS THE ENGINE OFF BUTTON. THE STARTER IS WIRED TO THE SAME FACE, SO THIS FINDS IT TOO." },
    faces = { { face = "top", level = 0 }, { face = "bottom", level = 0 }, { face = "left", level = 15 },
        { face = "right", level = 0 }, { face = "front", level = 0 }, { face = "back", level = 0 } } } })""")
snap("19_setup_buttons")
lua.execute('OBF({ screen = "guide", rev = 1, gi = 1, gn = #OB.GUIDE, card = OB.GUIDE[1] })')
snap("20_setup_guide_1")
lua.execute('OBF({ screen = "guide", rev = 1, gi = 4, gn = #OB.GUIDE, card = OB.GUIDE[4] })')
snap("21_setup_guide_4")
lua.execute('OBF({ screen = "busy", rev = 1, title = "SHIP LOADED", msg = "RESTARTING ON CARGO...", msg_color = SC.D.C.good })')
snap("22_setup_import")

# the tour, every step, over the engines-off ship
lua.execute('SC.ui.screen = nil SC.ui:setTab("fly") SC.ui:tourStart() TOUR_M = SC.base(W_PARK, { power = "off" })')
n = int(lua.eval("#SC.ui.TOUR or #require('ui').TOUR"))
for i in range(1, n + 1):
    lua.execute("SC.ui:render(TOUR_M)")
    snap(f"{22 + i}_tour_{i:02d}")
    lua.execute("SC.ui:tourNext()")
