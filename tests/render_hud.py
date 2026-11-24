#!/usr/bin/env python3
"""Render every HUD screen to PNG so layout changes can be eyeballed
without launching Minecraft.

    python3 tests/render_hud.py [outdir]     # default: hud_shots/

Needs lupa + Pillow. Paints the REAL lib/hud.lua into a 348x216 indexed
framebuffer (mocked CC:Graphics monitor) using the stock CC palette, then
writes one PNG per screen, scaled 3x.
"""
import os
import sys

from lupa import LuaRuntime
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
OUT = sys.argv[1] if len(sys.argv) > 1 else "hud_shots"
os.makedirs(OUT, exist_ok=True)

W, H, ZOOM = 348, 216, 3

# CC:Tweaked default palette, index = log2(colors.X)
PALETTE = [
    0xF0F0F0, 0xF2B233, 0xE57FD8, 0x99B2F2, 0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x4C4C4C,
    0x999999, 0x4C99B2, 0xB266E5, 0x3366CC, 0x7F664C, 0x57A64E, 0xCC4C4C, 0x111111,
]

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('package.path = "./?.lua;" .. package.path')
lua.execute(f"""
W, H = {W}, {H}
FB = {{}}
for i = 0, W * H - 1 do FB[i] = 15 end
local function put(x, y, c)
    if c and c >= 0 and x >= 0 and y >= 0 and x < W and y < H then
        FB[y * W + x] = c
    end
end
mon = {{}}
function mon.setTextScale() end
function mon.setGraphicsMode() return true end
function mon.setFrozen() end
function mon.setPaletteColor() end
function mon.getSize(m)
    if m then return W, H end
    return math.floor(W / 6), math.floor(H / 9)
end
function mon.drawPixels(px, py, a, b, c)
    if b == nil then
        for r, row in ipairs(a) do
            for col = 1, #row do put(px + col - 1, py + r - 1, row[col]) end
        end
    else
        for y = py, py + c - 1 do
            for x = px, px + b - 1 do put(x, y, a) end
        end
    end
end
term = {{}}
os.clock = os.clock or function() return 0 end
HUD = dofile("lib/hud.lua")
HUD.init(mon)
HUD.setShipLabel("Atlas")
""")


def snap(name):
    fb = lua.globals().FB
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            v = PALETTE[int(fb[y * W + x]) & 15]
            px[x, y] = ((v >> 16) & 255, (v >> 8) & 255, v & 255)
    img = img.resize((W * ZOOM, H * ZOOM), Image.NEAREST)
    path = os.path.join(OUT, name + ".png")
    img.save(path)
    print(path)


lua.execute("""
AP = { name = "NORTHFIELD", phase = "cruise", step = "turn", dist = 1247.3,
    progress = 0.42, eta = 204, speed = 6.1, paused = false,
    err = -4.1, heading = 95, alt = 280, goal_alt = 250, ceil = 450 }
function ST(o)
    o = o or {}
    local s = {
        mode = "CRUISE", altitude = 270, target_altitude = 280,
        pitch = 1.2, roll = -6.4, yaw = 92.3, speed = 6.1, target_speed = 8,
        climb_rate = 0.8, landed = false, gear_down = false, auto_land = false,
        proximity = 0, estop = false, unflip = false,
        position = { x = 120.5, y = 270, z = -43.2 },
        outputs = { speed = 11.2, FL_speed = 11.7, FR_speed = 10.9,
                    RL_speed = 11.4, RR_speed = 0.4 },
        pid_gains = {
            altitude = { kp = 0.35, ki = 0.08, kd = 0.7 },
            pitch = { kp = 2, ki = 0, kd = 1 },
            roll = { kp = 2, ki = 0, kd = 1 },
            yaw = { kp = 2.2, ki = 0, kd = 1.4 },
        },
        loop = { ema = 0.051, late_streak = 0 },
        kbd_last = "KBD #10 OK",
    }
    for k, v in pairs(o) do s[k] = v end
    return s
end
CFG = { features = { auto_land = true, gear = true } }
function FRAME(tab, o, msg)
    HUD.setTab(tab)
    HUD.markChromeDirty()
    HUD.render(mon, ST(o), CFG, msg or "")
end
""")

lua.execute('HUD.renderPower("off", 0, "")')
snap("00_splash")
lua.execute('HUD.renderPower("booting", 0.6, "")')
snap("01_booting")
lua.execute('HUD.render(mon, ST({ap = nil}), CFG, "")')  # leave splash
for i, tab in enumerate(["flight", "engines", "systems", "nav", "alarms", "actions"]):
    lua.execute(f'FRAME("{tab}", {{}}, "GEAR DOWN")')
    snap(f"{i + 2:02d}_{tab}")
lua.execute('FRAME("alarms", {altitude = 40, climb_rate = -6, estop = true}, "PROX 3 - GEAR DOWN")')
snap("08_alarms_active")
lua.execute('FRAME("ap", {ap = AP}, "")')
snap("09_ap_running")
lua.execute('HUD.render(mon, ST({ap = nil}), CFG, ""); FRAME("ap", {}, "")')
snap("10_ap_idle")
lua.execute("""
HUD.setWaypoints({
    { name = "HOME", x = 10, z = 20, heading = 90 },
    { name = "NORTHFIELD", x = 1200, z = -340, heading = 0 },
    { name = "MINE", x = -455.5, z = 88, heading = 270 },
})
HUD.wpOpen()
FRAME("actions", {}, "")
""")
snap("11_wp_list")
lua.execute("HUD.wpClose(); FRAME('flight', {unflip = true, landed = true, gear_down = true, proximity = 15}, 'AUTO-LAND ARMED')")
snap("12_flight_unflip_landed")
