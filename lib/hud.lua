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
    power_on   = 14, -- red
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
    L.tab_h = 24
    L.tab_gap = 5
    L.tab_y0 = L.body_y + 4

    -- shutdown circle: top-left of header
    local d = 12
    shutdown_rect = { x = L.border + 4, y = L.border + 4, w = d, h = d, d = d }
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

local function slotText(x, y, w, str, color, align)
    if w < 1 or x >= L.W then return end
    if y < 0 or y + Font.height > L.H then return end
    Gfx.fillRect(x, y, w, Font.height, C.bg)
    str = fit(str, w)
    if str == "" then return end
    local tw = Font.textWidth(str)
    local tx = x
    if align == "right" then
        tx = x + w - tw
    elseif align == "center" then
        tx = x + math.floor((w - tw) / 2)
    end
    if tx < x then tx = x end
    if tx + tw > x + w then tx = math.max(x, x + w - tw) end
    Gfx.text(tx, y, str, color or C.text)
end

local function drawBar(x, y, w, h, ratio, fg)
    Gfx.fillRect(x, y, w, h, C.bar_bg)
    local fill = math.floor(w * clamp(ratio or 0, 0, 1) + 0.5)
    if fill > 0 then
        Gfx.fillRect(x, y, fill, h, fg or C.good)
    end
end

-- 15-segment level bar (rear speed level): one cut per possible speed,
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
    local col = C.power_on
    -- dark ring
    drawCircle(cx, cy, rad + 1, 15)
    drawCircle(cx, cy, rad, col)
    -- inner highlight
    drawCircle(cx, cy, math.max(1, rad - 3), 0)
    drawCircle(cx, cy, math.max(1, rad - 4), col)
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
    -- drop shadow / bold
    Gfx.textScaled(tx + TITLE_SCALE, ty + TITLE_SCALE, title, C.accent, nil, TITLE_SCALE)
    Gfx.textScaled(tx, ty, title, C.title, nil, TITLE_SCALE)
    -- subtle accent edge
    Gfx.textScaled(tx - 1, ty - 1, title, C.accent, nil, TITLE_SCALE)

    -- subtitle: ship name when known (below the large title)
    local sub = ship_label or "FLIGHT OS"
    local sw = Font.textWidth(sub)
    Gfx.text(math.floor((W - sw) / 2), ty + th + 8, sub, C.dim)

    if boot_rect then
        local b = boot_rect
        local active = not booting
        Gfx.fillRect(b.x - 2, b.y - 2, b.w + 4, b.h + 4, C.border)
        Gfx.fillRect(b.x, b.y, b.w, b.h, active and C.boot_bg or C.panel)
        local lab = booting and "..." or "boot"
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

    -- title starts after shutdown circle
    local title_x = L.border + 22
    Gfx.text(title_x, L.border + 6, "ARTCORPOS", C.title)
    Gfx.text(title_x + 60, L.border + 6, ship_label ~= "FLIGHT OS" and ship_label or "ATLAS",
        ap_shown and C.good or C.accent)

    Gfx.fillRect(L.strip_x - 3, L.body_y - 2, 3, L.body_h + 4, edge)

    for i, tab in ipairs(TABS) do
        local x, y, w, h = tabRect(i)
        local on = tab.id == active_tab
        Gfx.fillRect(x, y, w, h, on and C.tab_on_bg or C.tab_off_bg)
        if ap_shown then
            Gfx.fillRect(x, y, w, 1, C.good)
            Gfx.fillRect(x, y + h - 1, w, 1, C.good)
            Gfx.fillRect(x, y, 1, h, C.good)
            Gfx.fillRect(x + w - 1, y, 1, h, C.good)
        end
        local label_txt = fit(tab.label, w - 4)
        local tw = Font.textWidth(label_txt)
        local tx = x + math.floor((w - tw) / 2)
        local ty = y + math.floor((h - Font.height) / 2)
        Gfx.text(tx, ty, label_txt, on and C.tab_on_fg or C.tab_off_fg)
    end
end

local function drawFlightStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "ALTITUDE")
    label(x, y + 18, "SPEED")
    label(x, y + 36, "CLIMB")
    label(x, y + 54, "MODE")
    label(x, y + 72, "GEAR/PROX")
    label(x, y + 90, "THRUST")
    Gfx.fillRect(x, y + 102, L.content_w - 16, 6, C.bar_bg)
    label(x, y + 116, "PROP SPD")
    -- per-prop thrust (0..15) from drone mixer — not tilt
    label(x, y + 156, "REAR")
    -- 15-segment rear level line drawn in dynamic (y+168)
    -- vertical altitude-target gauge track (right edge of content)
    local gx = x + L.content_w - 12
    Gfx.fillRect(gx, y, 12, 184, C.bar_bg)
    Gfx.fillRect(gx, y, 1, 184, C.border)
    Gfx.fillRect(gx + 11, y, 1, 184, C.border)
    Gfx.fillRect(gx, y, 12, 2, C.border)
    Gfx.fillRect(gx, y + 182, 12, 2, C.border)
end

local function drawEnginesStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "PROPELLERS")
    Gfx.fillRect(x, y + 8, L.content_w, 2, C.panel)
    label(x, y + 16, "FL")
    label(x, y + 34, "FR")
    label(x, y + 52, "RL")
    label(x, y + 70, "RR")
    label(x, y + 90, "REAR")
    Gfx.fillRect(x, y + 100, L.content_w, 2, C.panel)
    label(x, y + 108, "SPEED")
    -- 15-segment rear level line drawn in dynamic (y+120)
    label(x, y + 164, "TOTAL")
    Gfx.fillRect(x, y + 176, L.content_w, 8, C.bar_bg)
end

local function drawSystemsStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "ATTITUDE")
    Gfx.fillRect(x, y + 10, L.content_w, 2, C.panel)
    label(x, y + 20, "PITCH")
    label(x, y + 40, "ROLL")
    label(x, y + 60, "YAW")
    label(x, y + 70, "LOOP") -- control-loop period (20 Hz target)
    label(x, y + 86, "PID GAINS")
    Gfx.fillRect(x, y + 96, L.content_w, 2, C.panel)
    label(x, y + 106, "ALT")
    label(x, y + 126, "PIT")
    label(x, y + 146, "ROL")
    label(x, y + 166, "YAW")
end

local function drawNavStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "NAVIGATION")
    Gfx.fillRect(x, y + 8, L.content_w, 2, C.panel)
    -- position block, top-left (buttons occupy the top-right)
    label(x, y + 16, "X")
    label(x, y + 34, "Y")
    label(x, y + 52, "Z")
    Gfx.fillRect(x, y + 96, L.content_w, 2, C.panel)
    label(x, y + 106, "HEADING")
    label(x, y + 124, "TARGET ALT")
    label(x, y + 142, "ALT ERROR")
    Gfx.fillRect(x, y + 154, L.content_w, 2, C.panel)
    label(x, y + 162, "AUTOPILOT")
end

local function drawAlarmsStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "ALARMS")
    Gfx.fillRect(x, y + 10, L.content_w, 2, C.panel)
    for i = 0, 7 do
        Gfx.fillRect(x, y + 18 + i * 20, L.content_w, 16, C.panel)
    end
end

-- ACTIONS tab: touch buttons replacing M/L/G/X/R/T/N keys
local ACTION_BTNS = {
    { id = "land",  label = "AUTO-LAND", feat = "auto_land" },
    { id = "gear",  label = "GEAR",      feat = "gear" },
    { id = "estop", label = "E-STOP" },
    { id = "autopilot", label = "AUTOPILOT" },
    { id = "apcancel",  label = "CANCEL A/P" },
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

local function drawActionsStatic()
    local x = L.content_x
    local y = L.body_y + 2
    label(x, y, "CONTROLS")
    Gfx.fillRect(x, y + 8, L.content_w, 2, C.panel)
end

local function drawActionsDynamic(s)
    local cfg = render_config
    local feats = (cfg and cfg.features) or {}
    for i, btn in ipairs(ACTION_BTNS) do
        local bx, by, bw, bh = actionBtnRect(i)
        local enabled = true
        if btn.feat and feats[btn.feat] == false then enabled = false end
        local bg = enabled and C.panel or C.bar_bg
        local fg = enabled and C.text or C.dim
        if btn.id == "estop" then
            bg = C.bad
            fg = 15
        elseif btn.id == "land" and s.auto_land then
            bg = C.warn
            fg = 15
        elseif btn.id == "gear" and s.gear_down then
            bg = C.good
            fg = 15
        elseif btn.id == "autopilot" and s.ap then
            bg = C.good
            fg = 15
        elseif btn.id == "apcancel" then
            if s.ap then
                bg = C.good -- light green: the one live control during autopilot
                fg = 15
            else
                bg = C.bar_bg
                fg = C.dim
            end
        end
        Gfx.fillRect(bx, by, bw, bh, bg)
        Gfx.fillRect(bx, by, bw, 1, C.border)
        Gfx.fillRect(bx, by + bh - 1, bw, 1, C.border)
        Gfx.fillRect(bx, by, 1, bh, C.border)
        Gfx.fillRect(bx + bw - 1, by, 1, bh, C.border)
        local txt = btn.label
        if btn.id == "estop" and s.estop then
            txt = "E-STOP (ON)"
        end
        local tw = Font.textWidth(txt)
        Gfx.text(bx + math.floor((bw - tw) / 2), by + math.floor((bh - Font.height) / 2), txt, fg)
    end
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
    Gfx.fillRect(x, y, w, 1, C.border)
    Gfx.fillRect(x, y + h - 1, w, 1, C.border)
    Gfx.fillRect(x, y, 1, h, C.border)
    Gfx.fillRect(x + w - 1, y, 1, h, C.border)
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
    end
end

local function drawFlightDynamic(s)
    local x = L.content_x
    local y = L.body_y + 2
    local o = s.outputs or {}
    local vw = L.content_w - 20

    slotText(x + 70, y, vw - 70, string.format("%.1f", s.altitude or 0), C.accent, "right")
    slotText(x + 70, y + 18, vw - 70, string.format("%.1f", s.speed or 0) .. " MS", C.accent, "right")

    local clb = s.climb_rate or 0
    local cc = C.good
    if clb < -2 then cc = C.bad elseif clb < 0 then cc = C.warn end
    slotText(x + 70, y + 36, vw - 70, string.format("%+.1f", clb), cc, "right")

    local mode = s.mode or "???"
    slotText(x + 70, y + 54, vw - 70, mode, mode == "HOVER" and C.good or C.warn, "left")

    local gp = string.format("%s %d", s.gear_down and "DN" or "UP", s.proximity or 0)
    if s.auto_land then gp = "AL " .. (s.land_state or "") .. " " .. gp end
    if s.landed then gp = "GND " .. gp end
    slotText(x + 70, y + 72, vw - 70, gp, s.landed and C.good or C.text, "left")

    local thrust = (o.speed or 0) / 15
    drawBar(x, y + 102, L.content_w - 16, 6, thrust, C.good)
    slotText(x + L.content_w - 60, y + 90, 44,
        tostring(math.floor(thrust * 100 + 0.5)) .. "%", C.good, "right")

    local labels = { "FL", "FR", "RL", "RR" }
    for i, p in ipairs(labels) do
        local t = o[p .. "_speed"] or o.speed or 0
        local tc = C.good
        if t < 1 then tc = C.bad elseif t > 12 then tc = C.warn end
        slotText(x + 40, y + 128 + (i - 1) * 8, 70, string.format("%5.1f", t), tc, "right")
    end

    drawSegments(x, y + 168, L.content_w - 16, 6, s.target_speed)

    -- Vertical altitude target gauge (right edge)
    local gx = x + L.content_w - 12
    local gh = 184
    local max_alt = 450 -- gauge scale: AP_CEIL_HARD, not the discovered ceiling
    -- (a learned ceiling above this would otherwise pin the needle)
    local function altY(alt)
        local a = clamp(alt or 0, 0, max_alt)
        return y + gh - 3 - math.floor((a / max_alt) * (gh - 8))
    end
    local cur = s.altitude or 0
    local tgt = s.target_altitude or 0
    local cy = altY(cur)
    local bottom = y + gh - 2
    if bottom > cy then
        Gfx.fillRect(gx + 2, cy, 8, bottom - cy, C.accent)
    end
    local ty = altY(tgt)
    Gfx.fillRect(gx, ty, 12, 2, C.warn)
    -- current altitude chip above gauge (target shown by the marker line)
    slotText(x + L.content_w - 60, y - 0, 44, string.format("%.0f", cur), C.accent, "right")
end

local function drawEnginesDynamic(s)
    local x = L.content_x
    local y = L.body_y + 2
    local o = s.outputs or {}
    local labels = { "FL", "FR", "RL", "RR" }
    for i, p in ipairs(labels) do
        local spd = o[p .. "_speed"] or o.speed or 0
        local tc = C.good
        if spd < 1 then tc = C.bad elseif spd > 12 then tc = C.warn end
        slotText(x + 40, y + 16 + (i - 1) * 18, 80, string.format("%5.1f", spd), tc, "right")
    end
    drawSegments(x, y + 120, L.content_w, 8, s.target_speed)
    drawBar(x, y + 176, L.content_w, 8, (o.speed or 0) / 15, C.good)
end

local function drawSystemsDynamic(s)
    local x = L.content_x
    local y = L.body_y + 2
    local vw = L.content_w - 70

    local pitch = s.pitch or 0
    local pc = C.good
    if math.abs(pitch) > 10 then pc = C.bad elseif math.abs(pitch) > 5 then pc = C.warn end
    slotText(x + 70, y + 20, vw, string.format("%+8.1f", pitch), pc, "right")

    local roll = s.roll or 0
    local rc = C.good
    if math.abs(roll) > 10 then rc = C.bad elseif math.abs(roll) > 5 then rc = C.warn end
    slotText(x + 70, y + 40, vw, string.format("%+8.1f", roll), rc, "right")

    slotText(x + 70, y + 60, vw, string.format("%+8.1f", s.yaw or 0), C.text, "right")

    -- Control-loop period: green = on the 20 Hz timer, red = starved
    local loop = s.loop
    if loop and (loop.ema or 0) > 0 then
        local lp = loop.ema
        local lc = C.good
        if lp > 0.09 then lc = C.bad elseif lp > 0.06 then lc = C.warn end
        slotText(x + 70, y + 70, vw, string.format("%.1fms", lp * 1000), lc, "right")
    else
        slotText(x + 70, y + 70, vw, "--", C.dim, "right")
    end

    local pid = {
        { y + 106, (s.pid_gains or {}).altitude },
        { y + 126, (s.pid_gains or {}).pitch },
        { y + 146, (s.pid_gains or {}).roll },
        { y + 166, (s.pid_gains or {}).yaw },
    }
    for _, row in ipairs(pid) do
        local g = row[2] or {}
        slotText(x + 50, row[1], L.content_w - 50,
            string.format("K%.1f I%.2f D%.1f", g.kp or 0, g.ki or 0, g.kd or 0),
            C.text, "left")
    end
end

local function drawNavDynamic(s)
    local x = L.content_x
    local y = L.body_y + 2
    local w = L.content_w
    local pos = s.position or {}

    -- position, top-left
    slotText(x + 40, y + 16, 88, string.format("%.1f", pos.x or 0), C.text, "left")
    slotText(x + 40, y + 34, 88,
        string.format("%.1f", pos.y or (s.altitude or 0)), C.text, "left")
    slotText(x + 40, y + 52, 88, string.format("%.1f", pos.z or 0), C.text, "left")

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
        Gfx.fillRect(bx, by, bw, bh, bg)
        Gfx.fillRect(bx, by, bw, 1, C.border)
        Gfx.fillRect(bx, by + bh - 1, bw, 1, C.border)
        Gfx.fillRect(bx, by, 1, bh, C.border)
        Gfx.fillRect(bx + bw - 1, by, 1, bh, C.border)
        local txt = (btn.id == "rec" and s.recording) and "STOP" or btn.label
        local tw = Font.textWidth(txt)
        Gfx.text(bx + math.floor((bw - tw) / 2),
            by + math.floor((bh - Font.height) / 2), txt, fg)
    end

    -- status line: keyboard prompt > printing > recent kbd event > recording
    Gfx.fillRect(x, y + 82, w, Font.height + 4, C.bg) -- y+82..95: keeps the y+96 divider clear
    local st = nil
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
    if st then
        Gfx.text(x, y + 86, fit(st, w), C.accent)
    end

    -- navigation rows
    slotText(x + 90, y + 106, w - 90, string.format("%.1f", s.yaw or 0), C.accent, "right")
    slotText(x + 90, y + 124, w - 90, string.format("%.1f", s.target_altitude or 0), C.accent, "right")
    local err = (s.altitude or 0) - (s.target_altitude or 0)
    local ec = C.good
    if math.abs(err) > 10 then ec = C.bad elseif math.abs(err) > 3 then ec = C.warn end
    slotText(x + 90, y + 142, w - 90, string.format("%+.1f", err), ec, "right")

    -- autopilot row: objective distance, route progress %, ETA
    if s.ap then
        local ap = s.ap
        local d = math.floor(tonumber(ap.dist) or 0)
        local pct = math.floor((tonumber(ap.progress) or 0) * 100 + 0.5)
        local eta = ap.eta
        local eta_s = (eta and eta >= 0) and string.format("%dm%02ds",
            math.floor(eta / 60), math.floor(eta % 60)) or "--"
        local txt = string.format("%s %dm %d%% ETA %s",
            tostring(ap.name):upper(), d, pct, eta_s)
        if ap.paused then txt = "PAUSED " .. txt end
        slotText(x + 90, y + 162, w - 90, fit(txt, w - 90), C.good, "left")
    else
        slotText(x + 90, y + 162, w - 90, "-", C.dim, "left")
    end
end

local function drawAlarmsDynamic(s, status_msg)
    local x = L.content_x
    local y = L.body_y + 2
    local msgs = {}
    if s.unflip then
        table.insert(msgs, { "AUTOMATIC UNFLIP SEQUENCE", C.bad })
    end
    if s.estop then
        table.insert(msgs, { "E-STOP LATCHED (RESET)", C.bad })
    end
    -- Control loop starving (persistent late timers): see SYSTEMS LOOP row
    local loop = s.loop
    if loop and (loop.late_streak or 0) >= 5 then
        table.insert(msgs, { string.format("CONTROL LOOP SLOW %.0fMS",
            (loop.ema or 0) * 1000), C.bad })
    end
    -- status feedback ("Tab: X", "GEAR DOWN", ...) is not an alarm — this
    -- tab is reserved for real alarms
    if status_msg and status_msg ~= "" and status_msg:sub(1, 4) ~= "Tab:" then
        table.insert(msgs, { status_msg, C.accent })
    end
    local alt = s.altitude or 0
    if alt < 70 then
        table.insert(msgs, { "LOW ALTITUDE", C.bad })
    end
    -- fast descent is expected while auto-landing (6 m/s walk)
    if (s.climb_rate or 0) < -4 and not s.auto_land then
        table.insert(msgs, { "FAST DESCENT", C.warn })
    end
    if math.abs(s.pitch or 0) > 15 or math.abs(s.roll or 0) > 15 then
        table.insert(msgs, { "EXTREME ATTITUDE", C.bad })
    end
    if #msgs == 0 then
        table.insert(msgs, { "NO ACTIVE ALARMS", C.good })
    end
    for i = 1, 8 do
        local m = msgs[i]
        Gfx.fillRect(x + 2, y + 18 + (i - 1) * 20, L.content_w - 4, 16, C.panel)
        if m then
            Gfx.text(x + 6, y + 22 + (i - 1) * 20, fit(m[1], L.content_w - 12), m[2])
        end
    end
end

local function drawDynamic(s, status_msg)
    local x = L.content_x
    local y = L.border + 6

    drawShutdownButton()

    local hdr = status_msg or ""
    if hdr == "" then hdr = s.mode or "" end
    local hdr_x = L.W - L.border - 140
    local hdr_w = 130
    -- keep clear of power button on left / not overlap title
    if hdr_x < L.border + 120 then
        hdr_x = L.border + 120
        hdr_w = L.W - L.border - hdr_x - 4
    end
    -- slotText fits to hdr_w itself (fit(hdr, 20) truncated to ~3 chars)
    slotText(hdr_x, y, hdr_w, hdr, C.accent, "right")

    local readout_x = L.border + 120
    slotText(readout_x, y, 56, string.format("A%.0f", s.altitude or 0), C.text, "right")
    slotText(readout_x + 60, y, 56, string.format("S%.0f", s.speed or 0), C.text, "right")
    if s.estop then
        slotText(readout_x + 120, y, 44, "STOP", C.bad, "right")
    elseif s.landed then
        slotText(readout_x + 120, y, 44, "GND", C.good, "right")
    elseif s.auto_land then
        slotText(readout_x + 120, y, 44, "LAND", C.warn, "right")
    end

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

    if shutdown_rect and inRect(shutdown_rect.x, shutdown_rect.y, shutdown_rect.w, shutdown_rect.h, x, y) then
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
