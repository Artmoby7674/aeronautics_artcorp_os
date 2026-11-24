-- ArtCorpOS HUD - CC:Graphics mode 2 (256 colors)
-- Layout: left content panel, right vertical tab strip.
-- Coordinates are 0-based pixels. Design canvas: 348x216 (58x24 chars @ scale 0.5).

local function loadLib(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    local path = (name:gsub("%.", "/")) .. ".lua"
    local fn = loadfile(path)
    if fn then
        local ok2, res = pcall(fn)
        if ok2 then return res end
        error(res, 0)
    end
    error(mod, 0)
end

local Gfx = loadLib("lib.gfx")
local Font = loadLib("lib.font")

local HUD = {}

local SCALE = 0.5

local C = {
    bg       = 15,
    panel    = 7,
    border   = 9,
    title    = 0,
    dim      = 8,
    text     = 3,
    accent   = 9,
    good     = 13,
    warn     = 4,
    bad      = 14,
    tab_on_bg  = 9,
    tab_on_fg  = 15,
    tab_off_bg = 7,
    tab_off_fg = 8,
    bar_bg   = 7,
    blue     = 11,
    power_off  = 8,  -- gray
    boot_bg    = 9,
    boot_fg    = 15,
}

local TABS = {
    { id = "flight",  label = "FLIGHT" },
    { id = "engines", label = "ENGINES" },
    { id = "systems", label = "SYSTEMS" },
    { id = "nav",     label = "NAV" },
    { id = "alarms",  label = "ALARMS" },
    { id = "actions", label = "ACTIONS" },
    -- Autopilot screen. Present at all times so the strip does not reflow
    -- (and shuffle the tabs out from under a finger) the moment the autopilot
    -- engages; HUD.render() switches to it on its own when that happens.
    { id = "ap",      label = "A/P" },
}

local active_tab = "flight"
local initialized = false
local chrome_dirty = true
local content_dirty = true
local unflip_shown = false -- last seen status.unflip (drives full redraw)
local ap_shown = false     -- last seen status.ap ~= nil (drives green chrome)
local power_dirty = true
local ship_label = "FLIGHT OS"
local render_config = nil -- last config passed to HUD.render (features for ACTIONS)

-- Waypoint window state (full-monitor modal opened from ACTIONS)
local wp_list = {}  -- cached copy of the waypoint list
local wp_view = nil -- nil = closed, "list" | "popup" | "confirm"
local wp_shown = false -- whether the previous frame had the modal open
local wp_sel = nil  -- selected waypoint index (popup/confirm)
local wp_scroll = 0

local L = {}

-- hit rects
local shutdown_rect = nil -- {x,y,w,h,armed}
local boot_rect = nil
local splash_active = false -- boot_rect only hit-tests on splash/boot screens

local function applyLayout()
    local W, H = Gfx.W, Gfx.H
    L.W, L.H = W, H
    L.border = 2
    L.header_h = 20
    L.strip_w = 72
    L.body_y = L.border + L.header_h + 4
    L.body_h = H - L.body_y - L.border - 2
    L.strip_x = W - L.border - L.strip_w
    L.content_x = L.border + 4
    L.content_w = L.strip_x - L.content_x - 4
    L.title_x = L.border + 22                  -- ship name, right of the circle
    L.val_r = L.content_x + L.content_w - 20   -- FLIGHT values end left of the gauge
    L.tab_gap = 5
    L.tab_y0 = L.body_y + 4
    -- Tab height is DERIVED from how many tabs there are, not fixed. The strip
    -- is 186 px tall on the 348x216 design canvas and 6 fixed 24 px tabs were
    -- chosen to fill it; a 7th (the autopilot screen) overflows the bottom of
    -- the monitor at that size. Sizing from the count keeps the full-height
    -- look while there is room and shrinks to fit when there is not, instead of
    -- either clipping the last tab or hardcoding a second geometry.
    local avail = L.body_h - 2 - (L.tab_y0 - L.body_y)
    local n = #TABS
    L.tab_h = math.floor((avail - (n - 1) * L.tab_gap) / n)
    L.tab_h = math.max(14, math.min(24, L.tab_h))

    -- Shutdown circle: top-left of header. d is both the drawn diameter and the
    -- tap rect. Tap targets here are CHARACTER CELLS (6x9 px) which the cell
    -- sampler walks centre-then-corners, so the reachable set is already the
    -- whole cell span overlapping the box -- an earlier HIT_PAD widened the
    -- rect by 3 px and provably added zero reachable cells, so it is gone.
    local d = 15
    shutdown_rect = { x = L.border + 4, y = L.border + 2, w = d, h = d, d = d }
    -- boot button under splash title (leave room for 3x logo + subtitle)
    local bw, bh = 64, 18
    boot_rect = {
        x = math.floor((W - bw) / 2),
        y = math.min(H - 70, math.floor(H * 0.58)),
        w = bw,
        h = bh,
    }
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function fit(str, w)
    return Font.fit(tostring(str or ""), w)
end

-- Text in a fixed slot: the slot is cleared to `bg` first (default: screen
-- background), so a shorter value never leaves stale glyphs behind. Pass the
-- panel colour as bg when the slot sits on a panel (the header).
local function slotText(x, y, w, str, color, align, bg)
    if w < 1 or x >= L.W then return end
    if y < 0 or y + Font.height > L.H then return end
    Gfx.fillRect(x, y, w, Font.height, bg or C.bg)
    str = fit(str, w)
    if str == "" then return end
    local tw = Font.textWidth(str)
    local tx = x
    if align == "right" then
        tx = x + w - tw
    elseif align == "center" then
        tx = x + math.floor((w - tw) / 2)
    end
    Gfx.text(math.max(x, tx), y, str, color or C.text)
end

local function outline(x, y, w, h, color)
    Gfx.fillRect(x, y, w, 1, color)
    Gfx.fillRect(x, y + h - 1, w, 1, color)
    Gfx.fillRect(x, y, 1, h, color)
    Gfx.fillRect(x + w - 1, y, 1, h, color)
end

local function drawBar(x, y, w, h, ratio, fg)
    Gfx.fillRect(x, y, w, h, C.bar_bg)
    local fill = math.floor(w * clamp(ratio or 0, 0, 1) + 0.5)
    if fill > 0 then
        Gfx.fillRect(x, y, fill, h, fg or C.good)
    end
end

-- 15-segment level bar (rear speed level): one cell per possible level,
-- filled cells = current level; level 0 = all empty.
local function drawSegments(x, y, w, h, level, cells)
    cells = cells or 15
    local gap = 1
    local sw = math.floor((w - gap * (cells - 1)) / cells)
    level = math.floor(clamp(level or 0, 0, cells) + 0.5)
    for i = 1, cells do
        local sx = x + (i - 1) * (sw + gap)
        Gfx.fillRect(sx, y, sw, h, i <= level and C.good or C.bar_bg)
    end
end

-- Section heading: dim caption with a thin rule under it.
local function section(x, y, w, str)
    Gfx.text(x, y, fit(str, w), C.dim)
    Gfx.fillRect(x, y + 9, w, 1, C.panel)
end

-- Prop thrust colour: red = stalled, yellow = near the top, green otherwise.
local function thrustColor(t)
    if t < 1 then return C.bad elseif t > 12 then return C.warn end
    return C.good
end

local function label(x, y, str)
    local max_w = L.strip_x - 4 - x
    if max_w < 1 then return end
    Gfx.text(x, y, fit(str, max_w), C.dim)
end

local function tabRect(i)
    local y = L.tab_y0 + (i - 1) * (L.tab_h + L.tab_gap)
    return L.strip_x, y, L.strip_w, L.tab_h
end

local function inRect(rx, ry, rw, rh, x, y)
    return x >= rx and x < rx + rw and y >= ry and y < ry + rh
end

local function drawCircle(cx, cy, r, color)
    for dy = -r, r do
        for dx = -r, r do
            if dx * dx + dy * dy <= r * r then
                Gfx.fillRect(cx + dx, cy + dy, 1, 1, color)
            end
        end
    end
end

local function drawShutdownButton()
    if not shutdown_rect then return end
    local r = shutdown_rect
    local cx = r.x + math.floor(r.w / 2)
    local cy = r.y + math.floor(r.h / 2)
    local rad = math.floor(r.d / 2) - 1
    -- always active: shutdown is allowed landed or airborne
    local col = C.power_off
    -- dark ring
    drawCircle(cx, cy, rad + 1, 15)
    drawCircle(cx, cy, rad, col)
    -- inner highlight (empty center)
    drawCircle(cx, cy, math.max(1, rad - 5), 0)
    drawCircle(cx, cy, math.max(1, rad - 6), col)
end

-- ============================================================
-- Splash / power screens
-- ============================================================

local function drawSplash(progress, booting)
    Gfx.clear(C.bg)
    local W, H = L.W, L.H

    -- thin frame
    Gfx.fillRect(0, 0, W, 2, C.border)
    Gfx.fillRect(0, H - 2, W, 2, C.border)
    Gfx.fillRect(0, 0, 2, H, C.border)
    Gfx.fillRect(W - 2, 0, 2, H, C.border)

    -- *ArtCorp* at 3x scale (bold double-strike)
    local title = "*ArtCorp*"
    local TITLE_SCALE = 3
    local tw = Font.textWidthScaled(title, TITLE_SCALE)
    local th = Font.height * TITLE_SCALE
    if tw > W - 16 then
        TITLE_SCALE = 2
        tw = Font.textWidthScaled(title, TITLE_SCALE)
        th = Font.height * TITLE_SCALE
    end
    local tx = math.floor((W - tw) / 2)
    local ty = math.floor(H * 0.22)
    -- drop shadow, then the title
    Gfx.textScaled(tx + TITLE_SCALE, ty + TITLE_SCALE, title, C.accent, nil, TITLE_SCALE)
    Gfx.textScaled(tx, ty, title, C.title, nil, TITLE_SCALE)

    -- subtitle: ship name when known (below the large title)
    local sub = ship_label or "FLIGHT OS"
    local sw = Font.textWidth(sub)
    Gfx.text(math.floor((W - sw) / 2), ty + th + 8, sub, C.dim)

    if boot_rect then
        local b = boot_rect
        local active = not booting
        Gfx.fillRect(b.x - 2, b.y - 2, b.w + 4, b.h + 4, C.border)
        Gfx.fillRect(b.x, b.y, b.w, b.h, active and C.boot_bg or C.panel)
        local lab = booting and "STARTING" or "BOOT"
        local lw = Font.textWidth(lab)
        local lx = b.x + math.floor((b.w - lw) / 2)
        local ly = b.y + math.floor((b.h - Font.height) / 2)
        Gfx.text(lx, ly, lab, active and C.boot_fg or C.dim)
    end

    -- loading bar: | cubes |
    if booting then
        local segments = 12
        local seg = 7
        local gap = 1
        local bar_w = 2 + segments * (seg + gap) - gap + 2
        local bar_x = math.floor((W - bar_w) / 2)
        local bar_y = (boot_rect and (boot_rect.y + boot_rect.h + 16)) or math.floor(H * 0.7)
        local pipe_h = 14
        local pipe_y = bar_y - math.floor((pipe_h - seg) / 2)

        -- left pipe |
        Gfx.fillRect(bar_x, pipe_y, 2, pipe_h, C.dim)
        local filled = math.floor(clamp(progress or 0, 0, 1) * segments + 0.0001)
        local cx = bar_x + 4
        for i = 1, segments do
            if i <= filled then
                -- full cube (solid block)
                Gfx.fillRect(cx, pipe_y + math.floor((pipe_h - seg) / 2), seg, seg, C.accent)
                Gfx.fillRect(cx + 1, pipe_y + math.floor((pipe_h - seg) / 2) + 1, seg - 2, seg - 2, C.title)
            else
                Gfx.fillRect(cx, pipe_y + math.floor((pipe_h - seg) / 2), seg, seg, C.bar_bg)
            end
            cx = cx + seg + gap
        end
        -- right pipe |
        Gfx.fillRect(cx, pipe_y, 2, pipe_h, C.dim)
    end
end

-- ============================================================
-- Flight chrome + content
-- ============================================================

local function drawChrome()
    -- While the autopilot runs, the chrome outlines switch to light green
    -- (C.good) so the pilot can see at a glance that the ship is flying itself.
    local edge = ap_shown and C.good or C.border
    Gfx.clear(C.bg)
    Gfx.fillRect(0, 0, L.W, L.border, edge)
    Gfx.fillRect(0, L.H - L.border, L.W, L.border, edge)
    Gfx.fillRect(0, 0, L.border, L.H, edge)
    Gfx.fillRect(L.W - L.border, 0, L.border, L.H, edge)

    Gfx.fillRect(L.border, L.border, L.W - 2 * L.border, L.header_h, C.panel)
    Gfx.fillRect(L.border, L.border + L.header_h, L.W - 2 * L.border, 2, edge)

    -- ship name right of the shutdown circle; the live readouts fill the rest
    -- of the header (drawHeader)
    Gfx.text(L.title_x, L.border + 7, ship_label, ap_shown and C.good or C.title)

    Gfx.fillRect(L.strip_x - 3, L.body_y - 2, 3, L.body_h + 4, edge)

    for i, tab in ipairs(TABS) do
        local x, y, w, h = tabRect(i)
        local on = tab.id == active_tab
        Gfx.fillRect(x, y, w, h, on and C.tab_on_bg or C.tab_off_bg)
        if ap_shown then outline(x, y, w, h, C.good) end
        local label_txt = fit(tab.label, w - 4)
        local tw = Font.textWidth(label_txt)
        local tx = x + math.floor((w - tw) / 2)
        local ty = y + math.floor((h - Font.height) / 2)
        Gfx.text(tx, ty, label_txt, on and C.tab_on_fg or C.tab_off_fg)
    end
end

-- FLIGHT tab. One label column on the left, one right-aligned value column
-- ending at L.val_r (left of the altitude gauge), rows on a 16 px pitch.
local FLIGHT_ROWS = { "ALTITUDE", "TARGET ALT", "SPEED", "CLIMB", "MODE", "GEAR" }
local ROW = 16

local function drawFlightStatic()
    local x, y = L.content_x, L.body_y + 4
    for i, name in ipairs(FLIGHT_ROWS) do
        label(x, y + (i - 1) * ROW, name)
    end
    local w = L.val_r - x
    Gfx.fillRect(x, y + 96, w, 1, C.panel)
    label(x, y + 102, "THRUST")
    Gfx.fillRect(x, y + 140, w, 1, C.panel)
    label(x, y + 146, "REAR")
    -- vertical altitude gauge track (right edge of the content area)
    local gx = L.content_x + L.content_w - 12
    Gfx.fillRect(gx, L.body_y + 2, 12, 184, C.bar_bg)
    outline(gx, L.body_y + 2, 12, 184, C.border)
end

-- ENGINES tab: one bar per lift prop, the rear level, and average thrust.
local PROPS = { "FL", "FR", "RL", "RR" }

local function drawEnginesStatic()
    local x, y, w = L.content_x, L.body_y + 4, L.content_w - 4
    section(x, y, w, "LIFT PROPELLERS")
    for i, p in ipairs(PROPS) do
        label(x, y + 16 + (i - 1) * ROW, p)
    end
    section(x, y + 84, w, "REAR THRUSTER")
    label(x, y + 100, "LEVEL")
    label(x, y + 140, "AVG")
    section(x, y + 124, w, "AVERAGE LIFT")
end

local function drawSystemsStatic()
    local x, y, w = L.content_x, L.body_y + 4, L.content_w - 4
    section(x, y, w, "ATTITUDE")
    label(x, y + 16, "PITCH")
    label(x, y + 32, "ROLL")
    label(x, y + 48, "HEADING")
    label(x, y + 64, "CONTROL LOOP") -- 20 Hz tick period
    section(x, y + 88, w, "PID GAINS")
    label(x, y + 104, "ALT")
    label(x, y + 120, "PITCH")
    label(x, y + 136, "ROLL")
    label(x, y + 152, "YAW")
end

local function drawNavStatic()
    local x, y, w = L.content_x, L.body_y + 4, L.content_w - 4
    section(x, y, w, "POSITION")
    -- position block, top-left (buttons occupy the top-right)
    label(x, y + 16, "X")
    label(x, y + 32, "Y")
    label(x, y + 48, "Z")
    Gfx.fillRect(x, y + 94, w, 1, C.panel)
    label(x, y + 102, "HEADING")
    label(x, y + 118, "TARGET ALT")
    label(x, y + 134, "ALT ERROR")
    Gfx.fillRect(x, y + 150, w, 1, C.panel)
    label(x, y + 158, "AUTOPILOT")
end

local ALARM_ROWS = 8

local function drawAlarmsStatic()
    section(L.content_x, L.body_y + 4, L.content_w - 4, "ALARMS")
end

-- ACTIONS tab: touch buttons replacing M/L/G/X/R/T/N keys
-- NOTE: CANCEL A/P used to live here. It moved to the A/P tab, which opens
-- itself when the autopilot engages -- so the control is on the screen that
-- is already showing you the run, instead of a second tab you have to go and
-- find while the ship is flying itself.
local ACTION_BTNS = {
    { id = "land",  label = "AUTO-LAND", feat = "auto_land" },
    { id = "gear",  label = "GEAR",      feat = "gear" },
    { id = "estop", label = "E-STOP" },
    { id = "autopilot", label = "AUTOPILOT" },
}

local function actionBtnRect(i)
    local bw, bh, gap = 124, 30, 8
    local col = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    local x = L.content_x + 4 + col * (bw + gap)
    local y = L.body_y + 16 + row * (bh + gap)
    return x, y, bw, bh
end

-- NAV tab: 4 buttons, top-right of the content area (2x2)
local NAV_BTNS = {
    { id = "rec",     label = "REC" },
    { id = "print",   label = "PRINT" },
    { id = "quickwp", label = "QUICK WP" },
    { id = "newwp",   label = "NEW WP" },
}

local function navBtnRect(i)
    local bw, bh, gap = 64, 18, 4
    local col = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    local x = L.content_x + L.content_w - (2 * bw + gap) + col * (bw + gap)
    local y = L.body_y + 14 + row * (bh + gap)
    return x, y, bw, bh
end

-- ============================================================
-- A/P tab: the autopilot run screen.
-- ============================================================
-- The five numbered boxes are the point of this screen. The sequence is
-- climb -> rotate onto the bearing -> fast travel -> rotate onto the stored
-- heading -> land, and "which of those is it stuck in" is the first question
-- when a run misbehaves, so it is answered with a glanceable number in the
-- top-left rather than a word that has to be read.
--
-- Map is by (phase, step): "aim" covers TWO legs -- the climb always runs
-- first, then the turn -- so phase alone cannot tell them apart.
local AP_PHASES = {
    { n = 1, name = "CLIMB",  long = "CLIMB TO ALT" },
    { n = 2, name = "ROT",    long = "ROTATE" },
    { n = 3, name = "TRAVEL", long = "FAST TRAVEL" },
    { n = 4, name = "ALIGN",  long = "ROTATE" },
    { n = 5, name = "LAND",   long = "LANDING" },
}

local function apPhaseIndex(ph, step)
    if ph == "aim" then
        return (step == "climb") and 1 or 2
    elseif ph == "cruise" or ph == "correct" or ph == "arrive" then
        return 3
    elseif ph == "align" then
        return 4
    elseif ph == "land" then
        return 5
    end
    return nil
end

-- Phase boxes: 5 cells across the top-left, each holding its number.
-- The active one is filled and its number inverted, so the number is readable
-- at a glance and unambiguous even in dim light or on a glare-lit panel.
local AP_CELL_W, AP_CELL_H, AP_CELL_GAP = 20, 22, 4

local function apPhaseRect(i)
    return L.content_x + (i - 1) * (AP_CELL_W + AP_CELL_GAP),
        L.body_y + 14, AP_CELL_W, AP_CELL_H
end

-- CANCEL lives at the bottom of this screen: it is the one thing you want to
-- hit without aiming, and it used to be a half-width button two tabs away.
-- Bottom-anchored to the content area, so it cannot drift off the bottom.
local function apCancelRect()
    local w = math.min(150, L.content_w - 8)
    return L.content_x, L.body_y + L.body_h - 26, w, 22
end

-- Left/right half of the data block; label left, value right-aligned.
local AP_COL_GAP = 16
local function apCol(i) -- 1 = left, 2 = right
    local w = math.floor((L.content_w - 4 - AP_COL_GAP) / 2)
    return L.content_x + (i - 1) * (w + AP_COL_GAP), w
end

local function drawButton(bx, by, bw, bh, txt, bg, fg)
    Gfx.fillRect(bx, by, bw, bh, bg)
    outline(bx, by, bw, bh, C.border)
    local tw = Font.textWidth(txt)
    Gfx.text(bx + math.floor((bw - tw) / 2),
        by + math.floor((bh - Font.height) / 2), txt, fg)
end

-- A/P data rows: label on the left of each column, value right-aligned in
-- the remainder. Values get their OWN slot: slotText clears the slot it is
-- given, and handing it the whole column used to wipe the labels.
local AP_ROWS = { { "MODE", "ALT ERR" }, { "CLIMB", "BEARING ERR" },
                  { "HEADING", "GROUND SPD" }, { "ALT NOW/TGT", "ETA" } }
local AP_LABEL_W = 70

local function apValue(col, row, str, color)
    local cx, cw = apCol(col)
    slotText(cx + AP_LABEL_W - 6, L.body_y + 96 + (row - 1) * 18, cw - AP_LABEL_W + 6,
        str, color, "right")
end

local function drawApStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "AUTOPILOT")
    Gfx.fillRect(x, y + 9, L.content_w, 1, C.panel)

    -- phase boxes: outline + number, drawn once. The active highlight is
    -- dynamic, so it overdraws this and redraws the number with it.
    for i = 1, 5 do
        local bx, by, bw, bh = apPhaseRect(i)
        Gfx.fillRect(bx, by, bw, bh, C.bg)
        outline(bx, by, bw, bh, ap_shown and C.border or C.panel)
        local n = tostring(i)
        Gfx.text(bx + math.floor((bw - Font.textWidth(n)) / 2),
            by + math.floor((bh - Font.height) / 2), n, C.dim)
    end

    if not ap_shown then
        -- idle screen (an AP start/stop forces a full redraw, so this layer
        -- always matches the run state)
        label(x, L.body_y + 46, "NOT RUNNING")
        label(x, L.body_y + 60, "PICK A WAYPOINT: ACTIONS > AUTOPILOT")
        return
    end

    label(x, L.body_y + 42, "TO WAYPOINT")
    label(x, L.body_y + 56, "TRIP DONE")
    for i, names in ipairs(AP_ROWS) do
        for c = 1, 2 do
            label((apCol(c)), L.body_y + 96 + (i - 1) * 18, names[c])
        end
    end
    -- column divider
    local c2 = apCol(2)
    Gfx.fillRect(c2 - math.floor(AP_COL_GAP / 2), L.body_y + 92, 1, 66, C.panel)
end

local function drawApDynamic(s)
    local x, w = L.content_x, L.content_w - 4
    local ap = s.ap
    local bx, by, bw, bh = apCancelRect()

    if not ap then
        drawButton(bx, by, bw, bh, "CANCEL A/P", C.bar_bg, C.dim)
        return
    end

    -- which waypoint: "distance to WP" is only useful next to WHICH waypoint,
    -- and the name is short enough to sit on the title row (right of it).
    local nx = x + Font.textWidth("AUTOPILOT") + 8
    slotText(nx, L.body_y + 2, x + w - nx, tostring(ap.name or ""), C.text, "right")

    -- phase highlight
    local idx = apPhaseIndex(ap.phase, ap.step)
    for i = 1, 5 do
        local px, py, pw, ph = apPhaseRect(i)
        if i == idx then
            Gfx.fillRect(px + 1, py + 1, pw - 2, ph - 2, C.good)
            local n = tostring(i)
            Gfx.text(px + math.floor((pw - Font.textWidth(n)) / 2),
                py + math.floor((ph - Font.height) / 2), n, 0)
        end
    end
    -- spelled out beside the boxes, so a glance gives both the number (for
    -- bug reports) and the meaning (for the person flying). Bounded to the
    -- space left of the tab strip.
    local capx = x + 5 * (AP_CELL_W + AP_CELL_GAP) + 4
    local capw = math.max(0, (x + w) - capx)
    slotText(capx, L.body_y + 18, capw, idx and AP_PHASES[idx].long or "?",
        idx and C.accent or C.dim, "left")
    slotText(capx, L.body_y + 28, capw, ap.paused and "PAUSED" or "", C.warn, "left")

    -- distance + trip percentage: "how far now, and how much is done"
    local vx = x + AP_LABEL_W + 4
    local d = tonumber(ap.dist) or 0
    slotText(vx, L.body_y + 42, x + w - vx, string.format("%.0f M", d), C.accent, "right")
    local pct = (tonumber(ap.progress) or 0) * 100
    slotText(vx, L.body_y + 56, x + w - vx, string.format("%.0f%%", pct), C.accent, "right")
    drawBar(x, L.body_y + 68, w, 6, pct / 100, C.good)

    -- flight state, chosen to match what has actually gone wrong before:
    -- altitude error + climb rate (the climb oscillation), bearing error (the
    -- bank not tracking the bearing), and the mode (cruise quietly turning
    -- into hover, which is a one-glance diagnosis).
    -- Show the PLAN, not the vertical law's command: during the ceiling
    -- discovery climb the law commands the 450 m guard, and reading that back
    -- as "target altitude" alarmed pilots. ap.goal_alt is the intended cruise.
    local tgt_alt = tonumber(ap.goal_alt) or s.target_altitude or 0
    local alt_err = (s.altitude or 0) - tgt_alt
    local berr = tonumber(ap.err) or 0
    local eta = ap.eta
    apValue(1, 1, tostring(s.mode or "-"):upper(), C.text)
    apValue(2, 1, string.format("%+.0f", alt_err), math.abs(alt_err) > 10 and C.bad or C.good)
    apValue(1, 2, string.format("%+.1f M/S", s.climb_rate or 0), C.text)
    apValue(2, 2, string.format("%+.1f", berr),
        math.abs(berr) < 5 and C.good or (math.abs(berr) < 15 and C.warn or C.bad))
    apValue(1, 3, string.format("%.1f", s.yaw or 0), C.text)
    apValue(2, 3, string.format("%.1f M/S", s.speed or 0), C.text)
    apValue(1, 4, string.format("%.0f/%.0f", s.altitude or 0, tgt_alt), C.text)
    apValue(2, 4, (eta and eta >= 0) and string.format("%.0f S", eta) or "--", C.text)

    -- cancel: the one live control during a run, so it stays enabled
    drawButton(bx, by, bw, bh, "CANCEL A/P", C.good, 15)
end

local function drawActionsStatic()
    section(L.content_x, L.body_y + 4, L.content_w - 4, "CONTROLS")
end

local function drawActionsDynamic(s)
    local feats = (render_config and render_config.features) or {}
    for i, btn in ipairs(ACTION_BTNS) do
        local bx, by, bw, bh = actionBtnRect(i)
        local enabled = not (btn.feat and feats[btn.feat] == false)
        local bg = enabled and C.panel or C.bar_bg
        local fg = enabled and C.text or C.dim
        local txt = btn.label
        if not enabled then
            txt = btn.label .. " (N/A)"
        elseif btn.id == "estop" then
            bg, fg = C.bad, 15
            if s.estop then txt = "E-STOP (ON)" end
        elseif btn.id == "land" and s.auto_land then
            bg, fg, txt = C.warn, 15, "AUTO-LAND (ON)"
        elseif btn.id == "gear" then
            txt = s.gear_down and "GEAR (DOWN)" or "GEAR (UP)"
            if s.gear_down then bg, fg = C.good, 15 end
        elseif btn.id == "autopilot" and s.ap then
            bg, fg = C.good, 15
        end
        drawButton(bx, by, bw, bh, txt, bg, fg)
    end
    -- how to get out of an e-stop is not obvious from the button alone
    local hx, hy = L.content_x + 4, L.body_y + 16 + 2 * 38 + 6
    slotText(hx, hy, L.content_w - 8,
        s.estop and "E-STOP ON: SPACE/CTRL OR SHIFT CLEARS IT" or "", C.warn, "left")
end

-- ============================================================
-- Waypoint window: full-monitor modal (list -> popup -> delete confirm)
-- ============================================================
local function wpListRect()
    return 16, 14, L.W - 32, L.H - 28
end

local function wpPopupRect()
    local pw, ph = 210, 118
    return math.floor((L.W - pw) / 2), math.floor((L.H - ph) / 2), pw, ph
end

local function wpConfirmRect()
    local pw, ph = 220, 76
    return math.floor((L.W - pw) / 2), math.floor((L.H - ph) / 2), pw, ph
end

local function wpMaxRows(ph)
    return math.max(1, math.floor((ph - 50) / 16))
end

local function wpBox(x, y, w, h, bg)
    Gfx.fillRect(x, y, w, h, bg)
    outline(x, y, w, h, C.border)
end

local function wpCenter(x, y, w, h, txt, fg)
    local tw = Font.textWidth(txt)
    Gfx.text(x + math.floor((w - tw) / 2),
        y + math.floor((h - Font.height) / 2), txt, fg)
end

-- Bold label: draws the glyph twice, offset 1px, for a heavier stroke.
local function wpCenterBold(x, y, w, h, txt, fg)
    local tw = Font.textWidth(txt)
    local bx = x + math.floor((w - tw) / 2)
    local by = y + math.floor((h - Font.height) / 2)
    Gfx.text(bx, by, txt, fg)
    Gfx.text(bx + 1, by, txt, fg)
end

local function drawWpWindow()
    -- never show popup/confirm with a stale selection (e.g. deleted list)
    if wp_view ~= "list" and (not wp_sel or not wp_list[wp_sel]) then
        wp_view = "list"
        wp_sel = nil
    end
    Gfx.fillRect(0, 0, L.W, L.H, C.bg)

    if wp_view == "list" then
        local px, py, pw, ph = wpListRect()
        wpBox(px, py, pw, ph, C.panel)
        Gfx.text(px + 8, py + 6,
            fit("WAYPOINTS (" .. #wp_list .. ")", pw - 60), C.accent)
        wpBox(px + pw - 20, py + 4, 16, 16, C.bar_bg)
        wpCenter(px + pw - 20, py + 4, 16, 16, "X", C.text)
        if #wp_list == 0 then
            Gfx.text(px + 12, py + 34, fit("No waypoints yet", pw - 24), C.dim)
            Gfx.text(px + 12, py + 50,
                fit("Use QUICK WP / NEW WP on the NAV tab", pw - 24), C.dim)
        else
            local maxrows = wpMaxRows(ph)
            for k = 1, maxrows do
                local i = wp_scroll + k
                local w = wp_list[i]
                if not w then break end
                local ry = py + 26 + (k - 1) * 16
                Gfx.fillRect(px + 4, ry, pw - 8, 14,
                    (k % 2 == 0) and C.bar_bg or C.bg)
                Gfx.text(px + 8, ry + 3, fit(tostring(w.name), 90), C.accent)
                local info = string.format("X%.0f Z%.0f H%.0f",
                    tonumber(w.x) or 0, tonumber(w.z) or 0,
                    tonumber(w.heading) or 0)
                local iw = Font.textWidth(info)
                Gfx.text(px + pw - 12 - iw, ry + 3, info, C.text)
            end
            if #wp_list > maxrows then
                if wp_scroll > 0 then
                    wpBox(px + pw - 46, py + ph - 20, 18, 16, C.bar_bg)
                    wpCenter(px + pw - 46, py + ph - 20, 18, 16, "^", C.text)
                end
                if wp_scroll + maxrows < #wp_list then
                    wpBox(px + pw - 24, py + ph - 20, 18, 16, C.bar_bg)
                    wpCenter(px + pw - 24, py + ph - 20, 18, 16, "v", C.text)
                end
            end
        end

    elseif wp_view == "popup" and wp_sel and wp_list[wp_sel] then
        local w = wp_list[wp_sel]
        local px, py, pw, ph = wpPopupRect()
        wpBox(px, py, pw, ph, C.panel)
        wpBox(px + 4, py + 4, 14, 14, C.bar_bg)
        wpCenter(px + 4, py + 4, 14, 14, "X", C.text)
        Gfx.text(px + 24, py + 6, fit(tostring(w.name), pw - 32), C.accent)
        local rows = {
            { "X", string.format("%.1f", tonumber(w.x) or 0) },
            { "Z", string.format("%.1f", tonumber(w.z) or 0) },
            { "H", string.format("%.0f", tonumber(w.heading) or 0) },
        }
        for i, r in ipairs(rows) do
            local ry = py + 28 + (i - 1) * 18
            Gfx.text(px + 16, ry, r[1], C.dim)
            Gfx.text(px + 40, ry, r[2], C.text)
        end
        -- travel = blue arrow (>>>), delete = red cross - both bold
        wpBox(px + 16, py + ph - 30, 56, 22, C.blue)
        wpCenterBold(px + 16, py + ph - 30, 56, 22, ">>>", 15)
        wpBox(px + pw - 72, py + ph - 30, 56, 22, C.bad)
        wpCenterBold(px + pw - 72, py + ph - 30, 56, 22, "X", 15)

    elseif wp_view == "confirm" and wp_sel and wp_list[wp_sel] then
        local w = wp_list[wp_sel]
        local px, py, pw, ph = wpConfirmRect()
        wpBox(px, py, pw, ph, C.panel)
        Gfx.text(px + 14, py + 12, fit("Delete \"" .. tostring(w.name) .. "\"?", pw - 28), C.text)
        wpBox(px + 16, py + ph - 28, 70, 20, C.bad)
        wpCenter(px + 16, py + ph - 28, 70, 20, "YES", 15)
        wpBox(px + pw - 86, py + ph - 28, 70, 20, C.bar_bg)
        wpCenter(px + pw - 86, py + ph - 28, 70, 20, "NO", C.text)
    end
end

local function drawContentStatic()
    if active_tab == "flight" then
        drawFlightStatic()
    elseif active_tab == "engines" then
        drawEnginesStatic()
    elseif active_tab == "systems" then
        drawSystemsStatic()
    elseif active_tab == "nav" then
        drawNavStatic()
    elseif active_tab == "alarms" then
        drawAlarmsStatic()
    elseif active_tab == "actions" then
        drawActionsStatic()
    elseif active_tab == "ap" then
        drawApStatic()
    end
end

local function drawFlightDynamic(s)
    local x, y = L.content_x, L.body_y + 4
    local o = s.outputs or {}
    local vx = x + 76
    local vw = L.val_r - vx

    local function row(i, str, color)
        slotText(vx, y + (i - 1) * ROW, vw, str, color, "right")
    end
    row(1, string.format("%.1f", s.altitude or 0), C.accent)
    row(2, string.format("%.1f", s.target_altitude or 0), C.warn) -- = gauge marker
    row(3, string.format("%.1f M/S", s.speed or 0), C.accent)
    local clb = s.climb_rate or 0
    local cc = C.good
    if clb < -2 then cc = C.bad elseif clb < 0 then cc = C.warn end
    row(4, string.format("%+.1f M/S", clb), cc)
    local mode = s.mode or "???"
    row(5, mode, mode == "HOVER" and C.good or C.warn)

    local gp = (s.gear_down and "DOWN" or "UP") ..
        string.format("  PROX %d", s.proximity or 0)
    if s.auto_land then gp = "LAND " .. tostring(s.land_state or "") .. "  " .. gp end
    if s.landed then gp = "GROUND  " .. gp end
    row(6, gp, s.landed and C.good or C.text)

    local thrust = (o.speed or 0) / 15
    slotText(vx, y + 102, vw,
        tostring(math.floor(thrust * 100 + 0.5)) .. "%", C.good, "right")
    drawBar(x, y + 112, L.val_r - x, 6, thrust, C.good)

    -- per-prop thrust (0..15): four "FL 11.7" cells across the full row
    local cw = math.floor((L.val_r - x) / 4)
    for i, p in ipairs(PROPS) do
        local t = o[p .. "_speed"] or o.speed or 0
        local cx = x + (i - 1) * cw
        Gfx.text(cx, y + 126, p, C.dim)
        slotText(cx + 16, y + 126, cw - 26, string.format("%.1f", t), thrustColor(t), "right")
    end

    slotText(vx, y + 146, vw, string.format("%d/15", s.target_speed or 0), C.text, "right")
    drawSegments(x, y + 158, L.val_r - x, 8, s.target_speed)

    -- vertical altitude gauge: filled to the current altitude, yellow marker
    -- at the target. Scale is AP_CEIL_HARD (450), not a discovered ceiling.
    local gx = L.content_x + L.content_w - 12
    local gy, gh = L.body_y + 2, 184
    local max_alt = 450
    local function altY(alt)
        local a = clamp(alt or 0, 0, max_alt)
        return gy + gh - 3 - math.floor((a / max_alt) * (gh - 8))
    end
    Gfx.fillRect(gx + 2, gy + 2, 8, gh - 4, C.bar_bg)
    local cy = altY(s.altitude)
    local bottom = gy + gh - 2
    if bottom > cy then
        Gfx.fillRect(gx + 2, cy, 8, bottom - cy, C.accent)
    end
    Gfx.fillRect(gx + 1, altY(s.target_altitude), 10, 2, C.warn)
end

local function drawEnginesDynamic(s)
    local x, y = L.content_x, L.body_y + 4
    local o = s.outputs or {}
    local bx = x + 36
    local vw = 36
    local bw = L.content_w - 4 - (bx - x) - vw - 6
    for i, p in ipairs(PROPS) do
        local t = o[p .. "_speed"] or o.speed or 0
        local ry = y + 16 + (i - 1) * ROW
        drawBar(bx, ry, bw, 7, t / 15, thrustColor(t))
        slotText(bx + bw + 6, ry, vw, string.format("%.1f", t), thrustColor(t), "right")
    end
    drawSegments(bx, y + 100, bw, 7, s.target_speed)
    slotText(bx + bw + 6, y + 100, vw, string.format("%d/15", s.target_speed or 0), C.text, "right")
    local avg = (o.speed or 0) / 15
    drawBar(bx, y + 140, bw, 7, avg, C.good)
    slotText(bx + bw + 6, y + 140, vw, string.format("%d%%", math.floor(avg * 100 + 0.5)),
        C.good, "right")
end

local function drawSystemsDynamic(s)
    local x, y = L.content_x, L.body_y + 4
    local vx = x + 90
    local vw = L.content_w - 4 - 90

    local function attColor(a)
        a = math.abs(a)
        if a > 10 then return C.bad elseif a > 5 then return C.warn end
        return C.good
    end
    local pitch, roll = s.pitch or 0, s.roll or 0
    slotText(vx, y + 16, vw, string.format("%+.1f", pitch), attColor(pitch), "right")
    slotText(vx, y + 32, vw, string.format("%+.1f", roll), attColor(roll), "right")
    slotText(vx, y + 48, vw, string.format("%.1f", s.yaw or 0), C.text, "right")

    -- Control-loop period: green = on the 20 Hz timer, red = starved
    local loop = s.loop
    if loop and (loop.ema or 0) > 0 then
        local lp = loop.ema
        local lc = C.good
        if lp > 0.09 then lc = C.bad elseif lp > 0.06 then lc = C.warn end
        slotText(vx, y + 64, vw, string.format("%.1f MS", lp * 1000), lc, "right")
    else
        slotText(vx, y + 64, vw, "--", C.dim, "right")
    end

    local g = s.pid_gains or {}
    for i, name in ipairs({ "altitude", "pitch", "roll", "yaw" }) do
        local k = g[name] or {}
        slotText(x + 50, y + 88 + i * 16, L.content_w - 54,
            string.format("KP %.2f  KI %.2f  KD %.2f", k.kp or 0, k.ki or 0, k.kd or 0),
            C.text, "right")
    end
end

local function drawNavDynamic(s)
    local x, y = L.content_x, L.body_y + 4
    local w = L.content_w - 4
    local pos = s.position or {}

    -- position, top-left
    slotText(x + 16, y + 16, 80, string.format("%.1f", pos.x or 0), C.text, "right")
    slotText(x + 16, y + 32, 80, string.format("%.1f", pos.y or (s.altitude or 0)), C.text, "right")
    slotText(x + 16, y + 48, 80, string.format("%.1f", pos.z or 0), C.text, "right")

    -- 4 buttons, top-right
    for i, btn in ipairs(NAV_BTNS) do
        local bx, by, bw, bh = navBtnRect(i)
        local bg, fg = C.panel, C.text
        if btn.id == "rec" and s.recording then
            bg, fg = C.bad, 15
        elseif btn.id == "print" then
            if s.printing then
                bg, fg = C.warn, 15
            elseif not s.has_printer then
                fg = C.dim
            end
        end
        drawButton(bx, by, bw, bh, (btn.id == "rec" and s.recording) and "STOP" or btn.label, bg, fg)
    end

    -- status line: keyboard prompt > printing > recent kbd event > recording
    local st = ""
    if s.kbd_prompt then
        st = s.kbd_prompt
    elseif s.printing then
        st = "PRINTING " .. tostring(s.printing)
    elseif s.kbd_last then
        st = s.kbd_last
    elseif s.recording then
        local t = s.rec_t or 0
        st = string.format("REC %d:%02d | %d SAMP",
            math.floor(t / 60), math.floor(t) % 60, s.rec_n or 0)
    end
    slotText(x, y + 74, w, st, C.accent, "left")

    -- navigation rows
    local vx, vw = x + 90, w - 90
    slotText(vx, y + 102, vw, string.format("%.1f", s.yaw or 0), C.accent, "right")
    slotText(vx, y + 118, vw, string.format("%.1f", s.target_altitude or 0), C.accent, "right")
    local err = (s.altitude or 0) - (s.target_altitude or 0)
    local ec = C.good
    if math.abs(err) > 10 then ec = C.bad elseif math.abs(err) > 3 then ec = C.warn end
    slotText(vx, y + 134, vw, string.format("%+.1f", err), ec, "right")

    -- autopilot row: objective distance, route progress %, ETA
    if s.ap then
        local ap = s.ap
        local d = math.floor(tonumber(ap.dist) or 0)
        local pct = math.floor((tonumber(ap.progress) or 0) * 100 + 0.5)
        local eta = ap.eta
        local eta_s = (eta and eta >= 0) and string.format("%dM%02dS",
            math.floor(eta / 60), math.floor(eta % 60)) or "--"
        local txt = string.format("%s %dM %d%% ETA %s",
            tostring(ap.name):upper(), d, pct, eta_s)
        if ap.paused then txt = "PAUSED " .. txt end
        slotText(vx - 20, y + 158, vw + 20, txt, C.good, "right")
    else
        slotText(vx - 20, y + 158, vw + 20, "OFF", C.dim, "right")
    end
end

local function drawAlarmsDynamic(s, status_msg)
    local x, y = L.content_x, L.body_y + 4
    local w = L.content_w - 4
    local msgs = {}
    local function add(text, color) msgs[#msgs + 1] = { text, color } end
    if s.unflip then add("AUTOMATIC UNFLIP SEQUENCE", C.bad) end
    if s.estop then add("E-STOP ON (SPACE/CTRL/SHIFT CLEARS)", C.bad) end
    -- Control loop starving (persistent late timers): see SYSTEMS LOOP row
    local loop = s.loop
    if loop and (loop.late_streak or 0) >= 5 then
        add(string.format("CONTROL LOOP SLOW %.0fMS", (loop.ema or 0) * 1000), C.bad)
    end
    if (s.altitude or 0) < 70 and not s.landed then add("LOW ALTITUDE", C.bad) end
    -- fast descent is expected while auto-landing (6 m/s walk)
    if (s.climb_rate or 0) < -4 and not s.auto_land then add("FAST DESCENT", C.warn) end
    if math.abs(s.pitch or 0) > 15 or math.abs(s.roll or 0) > 15 then
        add("EXTREME ATTITUDE", C.bad)
    end
    if s.sable_error then add("NO SHIP TELEMETRY (CC:SABLE)", C.bad) end
    -- the latest status line, as a dim footnote under the real alarms
    if status_msg and status_msg ~= "" then add(status_msg, C.accent) end
    if #msgs == 0 then add("NO ACTIVE ALARMS", C.good) end

    for i = 1, ALARM_ROWS do
        local ry = y + 16 + (i - 1) * 20
        local m = msgs[i]
        if m then
            Gfx.fillRect(x, ry, w, 16, C.panel)
            Gfx.fillRect(x, ry, 3, 16, m[2])
            Gfx.text(x + 8, ry + 5, fit(m[1], w - 12), m[2])
        else
            Gfx.fillRect(x, ry, w, 16, C.bg)
        end
    end
end

-- Header readouts. One region right of the ship name: a fresh status
-- message takes it over for its 3 s, otherwise it shows ALT / SPD / MODE and
-- a state chip. (These used to be separate, overlapping slots, so a long
-- status line was cut through by the readouts: "STOPEAR DOWN".)
local function drawHeader(s, status_msg)
    local y = L.border + 7
    local x0 = L.title_x + Font.textWidth(ship_label) + 12
    local x1 = L.W - L.border - 6
    Gfx.fillRect(x0, y, x1 - x0, Font.height, C.panel)
    if status_msg ~= "" then
        slotText(x0, y, x1 - x0, status_msg, C.title, "right", C.panel)
        return
    end
    local parts = {
        { string.format("ALT %.0f", s.altitude or 0), C.title },
        { string.format("SPD %.1f", s.speed or 0), C.title },
        { tostring(s.mode or ""), s.mode == "HOVER" and C.good or C.warn },
    }
    if s.estop then parts[#parts + 1] = { "E-STOP", C.bad }
    elseif s.ap then parts[#parts + 1] = { "A/P", C.good }
    elseif s.landed then parts[#parts + 1] = { "GND", C.good }
    elseif s.auto_land then parts[#parts + 1] = { "LAND", C.warn } end
    local tx = x1
    for i = #parts, 1, -1 do
        local str = parts[i][1]
        local tw = Font.textWidth(str)
        if tx - tw < x0 then break end
        Gfx.text(tx - tw, y, str, parts[i][2])
        tx = tx - tw - 12
    end
end

local function drawDynamic(s, status_msg)
    drawShutdownButton()
    drawHeader(s, status_msg)

    if active_tab == "flight" then
        drawFlightDynamic(s)
    elseif active_tab == "engines" then
        drawEnginesDynamic(s)
    elseif active_tab == "systems" then
        drawSystemsDynamic(s)
    elseif active_tab == "nav" then
        drawNavDynamic(s)
    elseif active_tab == "alarms" then
        drawAlarmsDynamic(s, status_msg)
    elseif active_tab == "actions" then
        drawActionsDynamic(s)
    elseif active_tab == "ap" then
        drawApDynamic(s)
    end

    -- Waypoint window: full-monitor modal over everything (the unflip
    -- banner below still draws on top of it - safety first).
    if wp_view then
        drawWpWindow()
        drawShutdownButton() -- the wp window would cover it; keep it visible
    end

    -- Auto-unflip warning: black on red, drawn last so it sits on top.
    if s.unflip then
        local msg = fit("AUTOMATIC UNFLIP SEQUENCE", L.content_w - 12)
        local bw = Font.textWidth(msg) + 12
        local bx = L.content_x + math.floor((L.content_w - bw) / 2)
        local by = L.body_y + 4
        Gfx.fillRect(bx, by, bw, Font.height + 6, C.bad)
        Gfx.text(bx + 6, by + 3, msg, 0)
    end
end

-- ============================================================
-- Public API
-- ============================================================

function HUD.init(mon)
    local ok = Gfx.init(mon, SCALE)
    if not ok then
        error("CC:Graphics not available (need CC:Graphics mod + colour monitor)", 0)
    end
    applyLayout()
    initialized = true
    chrome_dirty = true
    content_dirty = true
    power_dirty = true
    return Gfx.W, Gfx.H
end

function HUD.setShipLabel(label)
    if label and label ~= "" then
        ship_label = tostring(label):upper()
    end
end

function HUD.markChromeDirty()
    chrome_dirty = true
    content_dirty = true
    power_dirty = true
end

function HUD.renderPower(mode, progress, status_msg)
    if not initialized then return end
    splash_active = true
    Gfx.begin()
    drawSplash(progress or 0, mode == "booting")
    Gfx.finish()
end

function HUD.render(mon, status, config, status_msg)
    if not initialized or not status then return end
    splash_active = false
    render_config = config
    status_msg = status_msg or ""
    -- The auto-unflip banner is a dynamic overlay drawn over static content.
    -- Force a full redraw on start/end so stale banner pixels are cleared
    -- (otherwise it lingers until the next tab change).
    if (status.unflip or false) ~= unflip_shown then
        unflip_shown = status.unflip or false
        chrome_dirty = true
        content_dirty = true
    end
    -- Autopilot start/end switches the chrome to green outlines: force a
    -- full redraw so the change is immediate (not only on tab change).
    if (status.ap ~= nil) ~= ap_shown then
        ap_shown = (status.ap ~= nil)
        chrome_dirty = true
        content_dirty = true
        -- Follow the run: opening on the A/P screen when the autopilot starts
        -- is the whole point of it (distance, progress, phase, cancel). On the
        -- way OUT, only reclaim the screen if the pilot never left it -- if
        -- they switched to FLIGHT or NAV to watch something else, yanking them
        -- back to A/P on arrival would be the UI fighting the operator.
        if ap_shown then
            if active_tab ~= "ap" then
                active_tab = "ap"
            end
        elseif active_tab == "ap" then
            active_tab = "flight"
        end
    end
    -- Modal closed: it painted over the static chrome/content, which only
    -- redraw on dirty flags - force a full redraw so everything comes back
    -- (otherwise only the per-frame dynamic widgets repopulate).
    if wp_shown and not wp_view then
        chrome_dirty = true
        content_dirty = true
    end
    wp_shown = wp_view ~= nil
    Gfx.begin()
    if chrome_dirty then
        drawChrome()
        chrome_dirty = false
        content_dirty = true
    end
    if content_dirty then
        drawContentStatic()
        content_dirty = false
    end
    drawDynamic(status, status_msg)
    Gfx.finish()
end

function HUD.setTab(id)
    for _, tab in ipairs(TABS) do
        if tab.id == id then
            if active_tab ~= id then
                active_tab = id
                chrome_dirty = true
                content_dirty = true
            end
            return true
        end
    end
    return false
end

function HUD.getTab()
    return active_tab
end

-- Fresh-start UI state: default tab + full redraw. Used by the stop button
-- so the next boot matches a first-time OS start.
function HUD.resetState()
    active_tab = "flight"
    wp_view = nil
    wp_sel = nil
    wp_scroll = 0
    chrome_dirty = true
    content_dirty = true
    power_dirty = true
end

function HUD.nextTab()
    for i, tab in ipairs(TABS) do
        if tab.id == active_tab then
            local nxt = TABS[(i % #TABS) + 1]
            HUD.setTab(nxt.id)
            return nxt.id
        end
    end
end

-- ============================================================
-- Waypoint window API (called by os_main)
-- ============================================================
function HUD.setWaypoints(list)
    wp_list = type(list) == "table" and list or {}
    if wp_sel and wp_sel > #wp_list then
        wp_sel = nil
        wp_view = "list"
    end
    local maxrows = wpMaxRows(select(3, wpListRect()))
    if wp_scroll > #wp_list then wp_scroll = 0 end
    if wp_scroll > 0 and wp_scroll >= #wp_list - maxrows + 1 then
        wp_scroll = math.max(0, #wp_list - maxrows)
    end
    if wp_view == "confirm" and not wp_sel then wp_view = "list" end
end

function HUD.wpOpen()
    wp_view = "list"
    wp_scroll = 0
    wp_sel = nil
end

function HUD.wpClose()
    wp_view = nil
    wp_sel = nil
end

function HUD.wpIsOpen()
    return wp_view ~= nil
end

-- After a confirmed delete: back to the list (os_main refreshes via
-- setWaypoints first, which keeps this view).
function HUD.wpAfterDelete()
    wp_sel = nil
    wp_view = "list"
    wp_scroll = 0
end

function HUD.prevTab()
    for i, tab in ipairs(TABS) do
        if tab.id == active_tab then
            local prv = TABS[((i - 2) % #TABS) + 1]
            HUD.setTab(prv.id)
            return prv.id
        end
    end
end

-- Returns: "boot" | "shutdown" | tab_id | "act:<id>" | nil
-- monitor_touch officially reports 1-based CHARACTER cells (tweaked.cc);
-- out-of-grid coordinates are treated as pixels (pixel-space events).
local last_touch_t, last_touch_x, last_touch_y = -1, -1, -1

-- Waypoint window hits. Returns a command ("wp:travel:N", "wp:confirmdel:N")
-- or "wp:noop" for internal transitions/blocked clicks - never nil, so the
-- cell sampler stops and taps never fall through to the tabs underneath.
local function wpHitTest(x, y)
    if wp_view ~= "list" and wp_view ~= nil
        and (not wp_sel or not wp_list[wp_sel]) then
        wp_view = "list"
        wp_sel = nil
    end
    if wp_view == "list" then
        local px, py, pw, ph = wpListRect()
        if inRect(px + pw - 20, py + 4, 16, 16, x, y) then
            wp_view = nil
            return "wp:noop"
        end
        if inRect(px, py, pw, ph, x, y) then
            local maxrows = wpMaxRows(ph)
            for k = 1, maxrows do
                local i = wp_scroll + k
                if not wp_list[i] then break end
                local ry = py + 26 + (k - 1) * 16
                if inRect(px + 4, ry, pw - 8, 14, x, y) then
                    wp_sel = i
                    wp_view = "popup"
                    return "wp:noop"
                end
            end
            if #wp_list > maxrows then
                if wp_scroll > 0
                    and inRect(px + pw - 46, py + ph - 20, 18, 16, x, y) then
                    wp_scroll = math.max(0, wp_scroll - maxrows)
                    return "wp:noop"
                end
                if wp_scroll + maxrows < #wp_list
                    and inRect(px + pw - 24, py + ph - 20, 18, 16, x, y) then
                    wp_scroll = wp_scroll + maxrows
                    return "wp:noop"
                end
            end
        end
        return "wp:noop" -- modal: clicks outside the panel do nothing

    elseif wp_view == "popup" then
        local px, py, pw, ph = wpPopupRect()
        if inRect(px + 4, py + 4, 14, 14, x, y) then
            wp_view = "list"
            return "wp:noop"
        end
        if inRect(px + 16, py + ph - 30, 56, 22, x, y) then
            return "wp:travel:" .. tostring(wp_sel)
        end
        if inRect(px + pw - 72, py + ph - 30, 56, 22, x, y) then
            wp_view = "confirm"
            return "wp:noop"
        end
        return "wp:noop"

    elseif wp_view == "confirm" then
        local px, py, pw, ph = wpConfirmRect()
        if inRect(px + 16, py + ph - 28, 70, 20, x, y) then
            return "wp:confirmdel:" .. tostring(wp_sel)
        end
        if inRect(px + pw - 86, py + ph - 28, 70, 20, x, y) then
            wp_view = "popup"
            return "wp:noop"
        end
        return "wp:noop"
    end
    return "wp:noop"
end

local function hitTest(x, y)
    if splash_active and boot_rect
        and inRect(boot_rect.x - 6, boot_rect.y - 9, boot_rect.w + 12, boot_rect.h + 18, x, y) then
        return "boot"
    end
    -- Nothing else is on the splash. Without this a tap over the (hidden)
    -- tab strip silently switched the tab the ship would boot into.
    if splash_active then return nil end

    -- Shutdown is gated on the ring actually being DRAWN. On the splash/boot
    -- screens drawSplash never paints it, but the rect stayed hit-testable, so
    -- a tap in the top-left corner was consumed and did nothing -- it could
    -- not boot either (boot lives centre-screen), so the tap was simply lost.
    if not splash_active and shutdown_rect
        and inRect(shutdown_rect.x, shutdown_rect.y, shutdown_rect.w, shutdown_rect.h, x, y) then
        return "shutdown"
    end

    -- Waypoint window is modal: it swallows everything (except shutdown,
    -- which stays live as a safety).
    if wp_view then
        return wpHitTest(x, y)
    end

    if active_tab == "actions" then
        for i, btn in ipairs(ACTION_BTNS) do
            local bx, by, bw, bh = actionBtnRect(i)
            if inRect(bx, by, bw, bh, x, y) then
                return "act:" .. btn.id
            end
        end
    end

    if active_tab == "nav" then
        for i, btn in ipairs(NAV_BTNS) do
            local bx, by, bw, bh = navBtnRect(i)
            if inRect(bx, by, bw, bh, x, y) then
                return "nav:" .. btn.id
            end
        end
    end

    -- A/P tab: the cancel button. Reported as an "act:" action so os_main's
    -- existing apcancel path (and its "AUTOPILOT CANCELLED" status line)
    -- handles it unchanged.
    if active_tab == "ap" then
        local cx, cy, cw, ch = apCancelRect()
        if inRect(cx, cy, cw, ch, x, y) then
            return "act:apcancel"
        end
    end

    -- Tabs: pad the hit rect by one cell (same trick as the boot button) so
    -- cell-quantized touches register reliably. The 5px gap is smaller than a
    -- 9px cell, so unpadded top-corner samples often fell into the tab above
    -- (a no-op when it was the active tab). Overlapping pads resolve to the
    -- nearest tab center.
    local best_i, best_d2 = nil, nil
    for i, tab in ipairs(TABS) do
        local tx, ty, tw, th = tabRect(i)
        if x >= tx - 6 and x < tx + tw + 6
            and y >= ty - 9 and y < ty + th + 9 then
            local dx = x - (tx + tw / 2)
            local dy = y - (ty + th / 2)
            local d2 = dx * dx + dy * dy
            if not best_d2 or d2 < best_d2 then
                best_i, best_d2 = i, d2
            end
        end
    end
    if best_i then
        local tab = TABS[best_i]
        if active_tab ~= tab.id then
            HUD.setTab(tab.id)
        end
        return "tab:" .. tab.id
    end
    return nil
end

-- Sample a character cell: center first (the aim point), then corners, so a
-- button partially covered by the cell still hits (cell 6x9 px vs 12 px
-- shutdown circle). Center-first matters: top corners sit closer to the tab
-- above in the 5px gap and would win the nearest-center race.
local function hitTestCell(cx, cy)
    local x0, y0 = (cx - 1) * 6, (cy - 1) * 9
    local x1, y1 = cx * 6 - 1, cy * 9 - 1
    local mx, my = math.floor((x0 + x1) / 2), math.floor((y0 + y1) / 2)
    local pts = { { mx, my }, { x0, y0 }, { x1, y0 }, { x0, y1 }, { x1, y1 } }
    for _, p in ipairs(pts) do
        local action = hitTest(p[1], p[2])
        if action then return action end
    end
    return nil
end

function HUD.handleTouch(rx, ry)
    if not initialized then return nil end
    if type(rx) ~= "number" or type(ry) ~= "number" then return nil end

    -- multi-block monitors can double-fire the same touch
    local t = os.clock()
    if rx == last_touch_x and ry == last_touch_y and t - last_touch_t < 0.05 then
        return nil
    end
    last_touch_t, last_touch_x, last_touch_y = t, rx, ry

    local cols = math.floor(Gfx.W / 6)
    local rows = math.floor(Gfx.H / 9)
    -- monitor_touch is cell-based; W/H are not always multiples of the cell
    -- size, so the partial edge column/row reports cells beyond floor(W/6).
    -- Those used to fall to the pixel path (cell number read as pixels = a
    -- point in the content area) and never matched anything. Anything that
    -- looks like a cell goes through the cell sampler.
    if rx >= 1 and ry >= 1 and rx <= cols + 2 and ry <= rows + 2 then
        return hitTestCell(rx, ry)
    end
    -- out-of-grid: pixel-space event
    return hitTest(rx, ry)
end

function HUD.shutdown()
    if not initialized then return end
    Gfx.shutdown()
    initialized = false
    chrome_dirty = true
    content_dirty = true
    power_dirty = true
end

return HUD
