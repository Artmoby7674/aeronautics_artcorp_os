-- v2 monitor UI: six tabs along the bottom, a status bar on top.
--
--   FLY    attitude indicator, heading tape, flight numbers, prop bars
--   NAV    map + waypoint list (fly / delete / save here / new via keyboard)
--   AUTO   the autopilot run: phase stepper, distance, ETA, cancel
--   SHIP   hardware state and everything the controller has learned
--   ALERT  active warnings only
--   CTRL   big buttons: land, gear, mode, e-stop, hold, record, print, power
--   ?      (top bar, right) replays the tour
--
-- Also drawn here: the tour, which explains one real element of the live
-- screen at a time with the rest dimmed.
--
-- Rendering is retained: each part is redrawn only when its signature (the
-- text/values it shows) changes, so a quiet screen costs almost nothing.
local D = require("draw")
local U = require("util")
local V = require("version")

local UI = {}
UI.__index = UI

local C = D.C
local TABS = {
    { id = "fly", label = "FLY" }, { id = "nav", label = "NAV" },
    { id = "auto", label = "AUTO" }, { id = "ship", label = "SHIP" },
    { id = "alert", label = "ALERT" }, { id = "ctrl", label = "CTRL" },
}
UI.TABS = TABS
local TOP, TAB_H = 16, 20

function UI.new()
    local self = setmetatable({}, UI)
    self.tab = "fly"
    self.sig, self.hits = {}, {}
    self.sel, self.scroll = 1, 0
    self.full = true
    self.screen = nil
    return self
end

function UI:invalidate() self.full = true end

function UI:setTab(id)
    if id ~= self.tab then self.tab = id self.full = true end
end

-- The bar tab a screen belongs to (every screen is a tab of its own).
function UI:barTab() return self.tab end

function UI:cycleTab(dir)
    local cur = self:barTab()
    for i, t in ipairs(TABS) do
        if t.id == cur then
            self:setTab(TABS[(i - 1 + dir) % #TABS + 1].id)
            return
        end
    end
end

-- -------------------------------------------------------------- widgets

function UI:hit(x, y, w, h, action)
    self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, action = action }
end

function UI:part(id, sig, fn)
    if self.sig[id] ~= sig then
        self.sig[id] = sig
        fn()
    end
end

local function chip(x, y, text, fg, bg)
    local w = D.textW(text) + 8
    D.rect(x, y, w, 11, bg)
    D.text(x + 4, y + 2, text, fg, bg)
    return w
end

local STYLES = {
    normal = { C.panel2, C.text, C.line },
    primary = { C.accent_dk, C.white, C.accent },
    danger = { C.panel, C.bad, C.bad },
    active = { C.accent, C.black, C.accent },
    warn = { C.panel2, C.warn, C.warn },
    off = { C.panel, C.dim, C.panel2 },
}

function UI:button(x, y, w, h, label, action, style, sub)
    local st = STYLES[style or "normal"]
    local bg = st[1]
    D.rect(x, y, w, h, bg)
    D.frame(x, y, w, h, st[3])
    local ty = y + math.floor((h - 7) / 2)
    if sub then ty = ty - 5 end
    D.text(x + math.floor(w / 2), ty, label, st[2], bg, 1, "c")
    if sub then
        local sc = (style == "active") and C.accent_dk or C.dim
        D.text(x + math.floor(w / 2), ty + 11, sub, sc, bg, 1, "c")
    end
    if action then self:hit(x, y, w, h, action) end
end

local function card(x, y, w, label)
    D.rect(x, y, w, 34, C.panel)
    D.rect(x, y, 2, 34, C.accent_dk)
    D.text(x + 7, y + 4, label, C.dim, C.panel)
end

local function cardValue(x, y, w, value, color, unit)
    D.rect(x + 7, y + 15, w - 9, 14, C.panel)
    D.text(x + 7, y + 15, value, color or C.white, C.panel, 2)
    if unit then
        D.text(x + 9 + D.textW(value, 2), y + 22, unit, C.dim, C.panel)
    end
end

local function bar(x, y, w, h, frac, color, back)
    frac = U.clamp(frac or 0, 0, 1)
    D.rect(x, y, w, h, back or C.panel2)
    local f = math.floor(w * frac + 0.5)
    if f > 0 then D.rect(x, y, f, h, color) end
end

local function vbar(x, y, w, h, frac, color)
    frac = U.clamp(frac or 0, 0, 1)
    D.rect(x, y, w, h, C.panel2)
    local f = math.floor(h * frac + 0.5)
    if f > 0 then D.rect(x, y + h - f, w, f, color) end
end

local function thrustColor(v)
    if v >= 14 then return C.bad elseif v >= 11.5 then return C.warn end
    return C.good
end

local function fmtDist(m)
    if not m then return "--" end
    if m >= 10000 then return string.format("%.0fKM", m / 1000) end
    if m >= 1000 then return string.format("%.1fKM", m / 1000) end
    return string.format("%.0fM", m)
end

local function fmtTime(s)
    if not s or s ~= s or s > 359999 then return "--" end
    s = math.floor(s)
    if s >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
    end
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
UI.fmtTime, UI.fmtDist = fmtTime, fmtDist

function UI.marginColor(v)
    if v < 1.5 then return C.bad elseif v < 3 then return C.warn end
    return C.good
end

-- -------------------------------------------------------------- chrome

function UI:chrome(m)
    local W, H = D.W, D.H
    D.rect(0, 0, W, H, C.bg)
    D.rect(0, 0, W, TOP, C.panel)
    D.rect(0, TOP, W, 1, C.line)
    -- tab bar
    local ty = H - TAB_H
    D.rect(0, ty - 1, W, 1, C.line)
    D.rect(0, ty, W, TAB_H, C.panel)
    local tw = math.floor(W / #TABS)
    for i, t in ipairs(TABS) do
        local x = (i - 1) * tw
        local w = (i == #TABS) and (W - x) or tw
        self:hit(x, ty, w, TAB_H, "tab:" .. t.id)
    end
    -- "?" in the top bar's right corner replays the tour (topBar draws it)
    self:hit(W - 20, 0, 20, TOP, "tour:start")
    self.sig = {}
end

function UI:topBar(m)
    local W = D.W
    local fl = m.fl
    local phase = fl.phase
    local pc = ({ parked = C.dim, flying = C.good, landing = C.warn, unflip = C.bad, estop = C.bad })[phase] or C.text
    local mode = (phase == "flying" or phase == "landing") and fl.mode:upper() or ""
    local ap = m.ap and ("A/P " .. m.ap.phase:upper()) or ""
    local msg = m.msg or ""
    self:part("top", table.concat({ m.name, phase, mode, ap, msg, m.kbd and "k" or "", m.rec and "r" or "" }, "|"), function()
        D.rect(0, 0, W, TOP, C.panel)
        D.text(6, 5, m.name:upper(), C.white, C.panel)
        local x = 10 + D.textW(m.name:upper())
        x = x + chip(x, 3, phase:upper(), C.black, pc) + 3
        if mode ~= "" then x = x + chip(x, 3, mode, C.text, C.panel2) + 3 end
        if ap ~= "" then x = x + chip(x, 3, ap, C.black, C.ap) + 3 end
        local rx = W - 4
        local function rchip(text, fg, bg)
            local w = D.textW(text) + 8
            rx = rx - w
            chip(rx, 3, text, fg, bg)
            rx = rx - 3
        end
        rchip("?", C.text, C.panel2) -- the tour (hit area: chrome)
        rchip("KBD", m.kbd and C.black or C.dim, m.kbd and C.good or C.panel2)
        if m.rec then rchip("REC", C.white, C.bad) end
        if msg ~= "" then
            local room = rx - x - 6
            local txt = msg
            local maxc = math.floor(room / 6)
            if #txt > maxc then txt = txt:sub(1, maxc) end
            D.text(rx - 2, 5, txt, m.msg_color or C.accent, C.panel, 1, "r")
        end
    end)
end

function UI:tabBar(m)
    local W, H = D.W, D.H
    local ty = H - TAB_H
    local tw = math.floor(W / #TABS)
    local cur = self:barTab()
    self:part("tabs", cur .. (m.alerts_bad and "!" or "") .. (#(m.alerts or {}) > 0 and "a" or ""), function()
        for i, t in ipairs(TABS) do
            local x = (i - 1) * tw
            local w = (i == #TABS) and (W - x) or tw
            local on = t.id == cur
            local bg = on and C.accent or C.panel
            local fg = on and C.black or C.dim
            if t.id == "alert" and #(m.alerts or {}) > 0 and not on then fg = m.alerts_bad and C.bad or C.warn end
            D.rect(x, ty, w, TAB_H, bg)
            if i > 1 then D.rect(x, ty + 4, 1, TAB_H - 8, C.line) end
            D.text(x + math.floor(w / 2), ty + 7, t.label, fg, bg, 1, "c")
        end
    end)
end

-- -------------------------------------------------------------- FLY

local HZ_W, HZ_H = 124, 96

local function horizon(pitch, roll)
    local cv = D.canvas(HZ_W, HZ_H, C.sky)
    local cx, cy = HZ_W / 2, HZ_H / 2
    local ppd = 2
    local r = math.rad(roll)
    local sr, cr = math.sin(r), math.cos(r)
    local vh = U.clamp(pitch, -40, 40) * ppd
    local step = 10 * ppd
    local rows = cv.rows
    for y = 0, HZ_H - 1 do
        local dy = y - cy
        local line = rows[y + 1]
        local vy, uy = dy * cr, -dy * sr
        for x = 0, HZ_W - 1 do
            local dx = x - cx
            local d = dx * sr + vy - vh
            local c
            if d >= 0 then c = C.ground else c = C.sky end
            if d > -0.7 and d < 0.7 then
                c = C.white
            else
                local k = -d / step
                local kr = math.floor(k + 0.5)
                if kr ~= 0 and kr >= -3 and kr <= 3 and math.abs(k - kr) * step < 0.55 then
                    local u = dx * cr + uy
                    local half = (kr % 2 == 0) and 14 or 8
                    if u > -half and u < half then c = C.text end
                end
            end
            line[x + 1] = c
        end
    end
    -- aircraft symbol
    local ax, ay = math.floor(cx), math.floor(cy)
    cv.fill(ax - 26, ay, 16, 2, C.warn)
    cv.fill(ax + 11, ay, 16, 2, C.warn)
    cv.fill(ax - 11, ay, 2, 5, C.warn)
    cv.fill(ax + 10, ay, 2, 5, C.warn)
    cv.fill(ax - 1, ay, 3, 2, C.warn)
    -- roll pointer on an arc at the top
    local R = 40
    for _, a in ipairs({ -30, -20, -10, 0, 10, 20, 30 }) do
        local ra = math.rad(a)
        cv.set(cx + R * math.sin(ra), cy - R * math.cos(ra), C.white)
    end
    local rr = math.rad(-roll)
    local px, py = cx + (R - 4) * math.sin(rr), cy - (R - 4) * math.cos(rr)
    cv.fill(px - 1, py - 1, 3, 3, C.warn)
    return cv
end

local function compass(x, y, w, hdg)
    D.rect(x, y, w, 16, C.panel)
    local cx = x + math.floor(w / 2)
    local ppd = 2
    local first = math.floor((hdg - w / (2 * ppd)) / 5) * 5
    for deg = first, hdg + w / (2 * ppd), 5 do
        local px = math.floor(cx + (deg - hdg) * ppd + 0.5)
        if px > x + 1 and px < x + w - 2 then
            local d = deg % 360
            local tall = (d % 10 == 0)
            D.rect(px, y + 12 - (tall and 4 or 2), 1, tall and 4 or 2, C.dim)
            if d % 30 == 0 then
                local lab = ({ [0] = "N", [90] = "E", [180] = "S", [270] = "W" })[d] or string.format("%d", math.floor(d / 10))
                D.text(px, y + 2, lab, (d % 90 == 0) and C.white or C.dim, C.panel, 1, "c")
            end
        end
    end
    D.rect(cx, y + 9, 1, 7, C.warn)
end

function UI:fly(m, static)
    local fl, s = m.fl, m.s
    local W = D.W
    local x0, y0 = 6, TOP + 5
    local rx = x0 + HZ_W + 8
    local cw = math.floor((W - rx - 6 - 6) / 2)
    local cards = {
        { "ALTITUDE", rx, y0 }, { "CLIMB", rx + cw + 6, y0 },
        { "SPEED", rx, y0 + 39 }, { "HEADING", rx + cw + 6, y0 + 39 },
        { "TARGET ALT", rx, y0 + 78 }, { "LIFT LEFT", rx + cw + 6, y0 + 78 },
    }
    local py = y0 + HZ_H + 22
    if static then
        D.frame(x0 - 1, y0 - 1, HZ_W + 2, HZ_H + 2, C.line)
        for _, c in ipairs(cards) do card(c[2], c[3], cw, c[1]) end
        D.rect(x0 - 1, py - 4, W - 10, 1, C.line)
        D.text(x0, py, "PROPS", C.dim, C.bg)
    end
    if not s or not s.valid then
        self:part("hz", "invalid", function()
            D.rect(x0, y0, HZ_W, HZ_H, C.panel)
            D.text(x0 + HZ_W / 2, y0 + HZ_H / 2 - 3, "NO TELEMETRY", C.bad, C.panel, 1, "c")
        end)
        return
    end
    self:part("hz", string.format("%.0f/%.0f", s.pitch * 2, s.roll * 2), function()
        D.blit(x0, y0, horizon(s.pitch, s.roll).rows)
        local pr = string.format("P%+d^ R%+d^", math.floor(s.pitch + 0.5), math.floor(s.roll + 0.5))
        D.rect(x0, y0 + HZ_H - 10, D.textW(pr) + 6, 10, C.panel)
        D.text(x0 + 3, y0 + HZ_H - 9, pr, C.text, C.panel)
    end)
    self:part("cmp", string.format("%.0f", s.heading * 2), function()
        compass(x0, y0 + HZ_H + 2, HZ_W, s.heading)
    end)

    local vals = {
        { string.format("%.1f", s.alt), C.white, "M" },
        { string.format("%+.1f", s.vs), math.abs(s.vs) > 4 and C.warn or C.white, "M/S" },
        { string.format("%.1f", s.hspeed), C.white, "M/S" },
        { string.format("%03d^", math.floor(s.heading + 0.5) % 360), C.white, nil },
        { string.format("%.0f", (m.ap and m.ap.goal_alt) or fl.alt_target), C.accent, "M" },
        { string.format("%.1f", fl.ctl.margin), UI.marginColor(fl.ctl.margin), "/15" },
    }
    if fl.phase == "parked" then vals[5] = { "GND", C.dim, nil } end
    for i, c in ipairs(cards) do
        local v = vals[i]
        self:part("card" .. i, v[1] .. v[2], function() cardValue(c[2], c[3], cw, v[1], v[2], v[3]) end)
    end

    -- props + rear
    local o = fl.out
    local bx = x0 + 44
    local names = { "FL", "FR", "RL", "RR" }
    local sig = {}
    for _, p in ipairs(names) do sig[#sig + 1] = string.format("%.0f%d", (o[p] or 0) * 2, o.tilt and o.tilt[p] or 0) end
    sig[#sig + 1] = string.format("%.0f%s", (o.rear or 0) * 2, tostring(o.rear_rev))
    self:part("props", table.concat(sig, ","), function()
        D.rect(bx, py, W - bx - 6, 46, C.bg)
        for i, p in ipairs(names) do
            local x = bx + (i - 1) * 46
            local v = o[p] or 0
            D.text(x, py, p, C.dim, C.bg)
            local t = o.tilt and o.tilt[p] or 0
            bar(x, py + 11, 40, 12, v / 15, thrustColor(v))
            D.text(x, py + 27, string.format("%.1f", v), C.text, C.bg)
            if t ~= 0 then D.text(x + 40, py + 27, t > 0 and "FWD" or "BCK", C.accent, C.bg, 1, "r") end
        end
        local x = bx + 4 * 46 + 6
        D.text(x, py, o.rear_rev and "REAR REV" or "REAR", o.rear_rev and C.warn or C.dim, C.bg)
        bar(x, py + 11, W - x - 8, 12, (o.rear or 0) / 15, C.accent)
        D.text(x, py + 27, string.format("%.0f/15", o.rear or 0), C.text, C.bg)
    end)
end

-- -------------------------------------------------------------- NAV

local MAP_W, MAP_H = 172, 172
local RANGES = { 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000 }

function UI:nav(m, static)
    local s, wps = m.s, m.wps or {}
    local W, H = D.W, D.H
    local mx, my = 4, TOP + 4
    local lx = mx + MAP_W + 8
    local lw = W - lx - 4
    local rows_y = my + 14
    local ROW, NROWS = 14, 6
    if self.sel > #wps then self.sel = math.max(#wps, 1) end
    if static then
        D.text(lx, my + 2, "WAYPOINTS", C.dim, C.bg)
        local by = rows_y + NROWS * ROW + 4
        local bw = math.floor((lw - 4) / 2)
        self:button(lx + lw - 30, my, 14, 11, "{", "wp:up")
        self:button(lx + lw - 14, my, 14, 11, "}", "wp:down")
        for i = 0, NROWS - 1 do self:hit(lx, rows_y + i * ROW, lw, ROW, "wp:row:" .. i) end
        self.nav_btn_y = by + 16
        self:hit(lx, self.nav_btn_y, bw, 22, "wp:fly")
        self:hit(lx + bw + 4, self.nav_btn_y, bw, 22, "wp:del")
        self:hit(lx, self.nav_btn_y + 26, bw, 22, "wp:save")
        self:hit(lx + bw + 4, self.nav_btn_y + 26, bw, 22, "wp:new")
        self:hit(mx, my, MAP_W, MAP_H, "map:zoom")
    end
    if not s or not s.valid then return end

    local wsel = wps[self.sel]
    -- map range: fit the selected waypoint (or the nearest few) around the ship
    local need = 0
    if wsel then need = U.hypot(wsel.x - s.x, wsel.z - s.z) end
    if m.ap then need = math.max(need, m.ap.dist or 0) end
    local range = RANGES[#RANGES]
    for _, r in ipairs(RANGES) do if r * 0.85 >= need then range = r break end end
    if self.zoom then range = self.zoom end
    local scale = range / (MAP_W / 2)
    local cxw, czw = s.x, s.z
    local function toMap(x, z) return MAP_W / 2 + (x - cxw) / scale, MAP_H / 2 + (z - czw) / scale end
    local sig = string.format("%d|%d|%d|%d|%d|%d|%s", range, math.floor(s.x / scale), math.floor(s.z / scale),
        math.floor(s.heading / 6), self.sel, #wps, tostring(m.ap and m.ap.name))
    self:part("map", sig, function()
        local cv = D.canvas(MAP_W, MAP_H, C.panel)
        for i = 1, 3 do
            local g = math.floor(MAP_W / 4 * i)
            cv.fill(g, 0, 1, MAP_H, C.panel2)
            cv.fill(0, g, MAP_W, 1, C.panel2)
        end
        if m.ap then
            local tx, tz = toMap(m.ap.x, m.ap.z)
            cv.line(MAP_W / 2, MAP_H / 2, tx, tz, C.ap)
        end
        for i, w in ipairs(wps) do
            local px, pz = toMap(w.x, w.z)
            local c = (i == self.sel) and C.warn or C.accent
            local r = (i == self.sel) and 2 or 1
            cv.fill(px - r, pz - r, r * 2 + 1, r * 2 + 1, c)
        end
        -- ship arrow
        local h = math.rad(s.heading)
        local fx, fz = math.sin(h), -math.cos(h)
        local c0x, c0z = MAP_W / 2, MAP_H / 2
        local tipx, tipz = c0x + fx * 7, c0z + fz * 7
        local lx2, lz2 = c0x - fx * 4 - fz * 4, c0z - fz * 4 + fx * 4
        local rx2, rz2 = c0x - fx * 4 + fz * 4, c0z - fz * 4 - fx * 4
        cv.line(tipx, tipz, lx2, lz2, C.white)
        cv.line(tipx, tipz, rx2, rz2, C.white)
        cv.line(lx2, lz2, rx2, rz2, C.white)
        D.blit(mx, my, cv.rows)
        D.frame(mx - 1, my - 1, MAP_W + 2, MAP_H + 2, C.line)
        -- labels
        for i, w in ipairs(wps) do
            local px, pz = toMap(w.x, w.z)
            if px > 4 and px < MAP_W - 30 and pz > 4 and pz < MAP_H - 10 then
                D.text(mx + px + 4, my + pz - 3, w.name, (i == self.sel) and C.warn or C.dim, C.panel)
            end
        end
        D.text(mx + 3, my + MAP_H - 10, "N{  " .. fmtDist(range * 2) .. (self.zoom and " (TAP)" or ""), C.dim, C.panel)
    end)

    -- list
    local lsig = { self.sel, self.scroll, #wps }
    for i = 1, NROWS do
        local w = wps[self.scroll + i]
        if w then lsig[#lsig + 1] = w.name .. fmtDist(U.hypot(w.x - s.x, w.z - s.z)) end
    end
    self:part("list", table.concat(lsig, ","), function()
        D.rect(lx, rows_y, lw, NROWS * ROW, C.bg)
        if #wps == 0 then
            D.text(lx + 2, rows_y + 4, "NONE YET:", C.dim, C.bg)
            D.text(lx + 2, rows_y + 16, "SAVE HERE OR NEW", C.dim, C.bg)
        end
        for i = 1, NROWS do
            local idx = self.scroll + i
            local w = wps[idx]
            if w then
                local y = rows_y + (i - 1) * ROW
                local on = idx == self.sel
                local bg = on and C.panel2 or C.bg
                D.rect(lx, y, lw, ROW - 2, bg)
                if on then D.rect(lx, y, 2, ROW - 2, C.warn) end
                D.text(lx + 5, y + 3, w.name, on and C.white or C.text, bg)
                D.text(lx + lw - 3, y + 3, fmtDist(U.hypot(w.x - s.x, w.z - s.z)), C.dim, bg, 1, "r")
            end
        end
    end)
    local info = ""
    if wsel then
        info = string.format("BRG %03d^  LAND HDG %03d^", math.floor(U.bearing(wsel.x - s.x, wsel.z - s.z)), math.floor(wsel.heading or 0))
    end
    local by = self.nav_btn_y or (rows_y + NROWS * ROW + 20)
    local bw = math.floor((lw - 4) / 2)
    local del_label = (m.confirm == "wp:del") and "SURE?" or "DELETE"
    self:part("navbtn", info .. "|" .. del_label .. "|" .. tostring(m.kbd_prompt) .. tostring(#wps), function()
        D.slot(lx, by - 13, lw, info, C.dim, C.bg)
        self:button(lx, by, bw, 22, "FLY >", nil, wsel and "primary" or "off")
        self:button(lx + bw + 4, by, bw, 22, del_label, nil, wsel and "danger" or "off")
        self:button(lx, by + 26, bw, 22, "SAVE HERE", nil, "normal")
        self:button(lx + bw + 4, by + 26, bw, 22, m.kbd_prompt and "TYPING..." or "NEW (KBD)", nil, m.kbd and "normal" or "off")
    end)
end

-- -------------------------------------------------------------- AUTO

local STEPS = { { "depart", "DEPART" }, { "cruise", "CRUISE" }, { "stop", "STOP + ALIGN" }, { "land", "LAND" } }
local STEP_OF = { turn = "depart", align = "stop" }

function UI:auto(m, static)
    local W = D.W
    local ap, s = m.ap, m.s
    local y0 = TOP + 6
    if not ap then
        self:part("apidle", tostring(m.last_ap), function()
            D.rect(0, TOP + 1, W, D.H - TOP - TAB_H - 2, C.bg)
            D.text(W / 2, y0 + 30, "NO ACTIVE ROUTE", C.white, C.bg, 2, "c")
            D.text(W / 2, y0 + 54, "PICK A WAYPOINT ON NAV AND PRESS FLY", C.dim, C.bg, 1, "c")
            if m.last_ap then D.text(W / 2, y0 + 70, m.last_ap, C.accent, C.bg, 1, "c") end
            self:button(W / 2 - 70, y0 + 92, 140, 26, "CHOOSE WAYPOINT", "tab:nav", "primary")
        end)
        return
    end
    local cw = math.floor((W - 12 - 12) / 3)
    local cards = {
        { "DISTANCE", 6, y0 + 50 }, { "ETA", 6 + cw + 6, y0 + 50 }, { "SPEED", 6 + 2 * (cw + 6), y0 + 50 },
        { "ALT / GOAL", 6, y0 + 89 }, { "COURSE ERR", 6 + cw + 6, y0 + 89 }, { "LIFT LEFT", 6 + 2 * (cw + 6), y0 + 89 },
    }
    if static or self.sig.apidle then
        self.sig.apidle = nil
        D.rect(0, TOP + 1, W, D.H - TOP - TAB_H - 2, C.bg)
        D.text(6, y0, "EN ROUTE TO", C.dim, C.bg)
        for _, c in ipairs(cards) do card(c[2], c[3], cw, c[1]) end
        self:button(W - 96, y0 + 128, 90, 22, "CANCEL A/P", "ap:cancel", "danger")
        self:part("apname", "", function() end)
    end
    self:part("apname", ap.name .. (ap.hop and "h" or ""), function()
        D.slot(6, y0 + 10, W - 12, ap.name .. (ap.hop and "  (HOVER HOP)" or ""), C.white, C.bg, 2)
    end)
    local cur = STEP_OF[ap.phase] or ap.phase
    self:part("steps", cur, function()
        local sw = math.floor((W - 12 - 3 * 4) / 4)
        local done = true
        for i, st in ipairs(STEPS) do
            local x = 6 + (i - 1) * (sw + 4)
            local on = st[1] == cur
            if on then done = false end
            local bg = on and C.ap or (done and C.panel2 or C.panel)
            local fg = on and C.black or (done and C.good or C.dim)
            D.rect(x, y0 + 30, sw, 14, bg)
            D.text(x + sw / 2, y0 + 34, (done and not on) and (st[2] .. " @") or st[2], fg, bg, 1, "c")
        end
    end)
    local herr = ap.herr or 0
    local vals = {
        { fmtDist(ap.dist), C.white }, { fmtTime(ap.eta), C.white },
        { string.format("%.0f", s.hspeed or 0), C.white, ap.v_sp and string.format("/%.0f", ap.v_sp) or "M/S" },
        { string.format("%.0f", s.alt or 0), C.white, string.format("/%.0f", ap.goal_alt or 0) },
        { string.format("%+.0f^", herr), math.abs(herr) > 15 and C.warn or C.white },
        { string.format("%.1f", m.fl.ctl.margin), UI.marginColor(m.fl.ctl.margin), "/15" },
    }
    for i, c in ipairs(cards) do
        local v = vals[i]
        self:part("apc" .. i, v[1] .. (v[3] or "") .. v[2], function() cardValue(c[2], c[3], cw, v[1], v[2], v[3]) end)
    end
    self:part("approg", string.format("%.0f", (ap.progress or 0) * 200), function()
        D.text(6, y0 + 128, "PROGRESS", C.dim, C.bg)
        bar(6, y0 + 139, W - 112, 8, ap.progress or 0, C.ap)
        D.slot(64, y0 + 128, 40, string.format("%d%%", math.floor((ap.progress or 0) * 100)), C.text, C.bg)
    end)
end

-- -------------------------------------------------------------- SHIP

function UI:ship(m, static)
    local W = D.W
    local fl, s = m.fl, m.s
    local c = fl.ctl
    local y0 = TOP + 6
    local colw = math.floor((W - 18) / 2)
    local lx, rx = 6, 12 + colw
    if static then
        D.text(lx, y0, "HARDWARE", C.accent, C.bg)
        D.text(rx, y0, "LEARNED IN FLIGHT", C.accent, C.bg)
        self:button(rx, y0 + 140, colw, 18, "RESET LEARNED VALUES", "ship:reset", "normal")
        -- world backup (waypoints, air, learned) on a floppy in any disk drive
        local bw = math.floor((colw - 4) / 2)
        self:button(lx, y0 + 140, bw, 18, "SAVE DISK", "ship:disksave", "normal")
        self:button(lx + bw + 4, y0 + 140, bw, 18, "LOAD DISK", "ship:diskload", "normal")
        D.text(lx + colw, y0, "OS V" .. V.number, C.accent, C.bg, 1, "r")
    end
    local loop = m.loop or {}
    local left = {
        { "ENGINE", m.power == "on" and "RUNNING" or m.power:upper(), m.power == "on" and C.good or C.warn },
        { "CLUTCH", m.clutch and "ENGAGED" or "OPEN", m.clutch and C.good or C.warn },
        { "GEAR", fl.gear_down and "DOWN" or "UP", C.text },
        { "GROUND SENSOR", string.format("%d/15", fl.prox or 0), (fl.prox or 0) > 0 and C.warn or C.text },
        { "TELEMETRY", (s and s.valid) and "OK" or "LOST", (s and s.valid) and C.good or C.bad },
        { "CONTROL LOOP", loop.ms and string.format("%.0f MS", loop.ms) or "--", (loop.ms or 50) > 65 and C.bad or C.good },
        { "KEYBOARD", m.kbd and "ONLINE" or "OFFLINE", m.kbd and C.good or C.dim },
        { "DISK FREE", m.disk and string.format("%.0f KB", m.disk / 1024) or "--", (m.disk or 1e9) < 50000 and C.bad or C.text },
        { "MISSING", m.missing and #m.missing > 0 and table.concat(m.missing, " "):upper() or "NONE", (m.missing and #m.missing > 0) and C.bad or C.good },
    }
    local base = fl.t.ship.hover_throttle
    local right = {
        { "HOVER THRUST", string.format("%.2f / CFG %.1f", c.hover, base), C.text },
        { "PITCH TRIM", string.format("%+.2f", c.pi_), C.text },
        { "ROLL TRIM", string.format("%+.2f", c.ri), C.text },
        { "YAW TRIM", string.format("%+.2f", c.yi), math.abs(c.yi) > 0.3 and C.warn or C.text },
        { "REAR PITCH FF", string.format("%+.2f", c.rear_pk or 0), C.text },
        { "REAR YAW FF", string.format("%+.2f", c.rear_yk or 0), math.abs(c.rear_yk or 0) > 0.3 and C.warn or C.text },
        { "TURN BRAKE", string.format("%.1f ^/S2", c.yaw_brake or fl.t.yaw.brake_accel), C.text },
        { "REAR CAP", string.format("%.0f/15", fl.rear_cap or 15), (fl.rear_cap or 15) < 14 and C.warn or C.text },
        { "CALIBRATION", ((c.calibrated or 0) > 0) and "DONE (FROZEN)"
            or (fl.cal and string.format("RUNNING %d%%", math.floor((fl.cal.progress or 0) * 100)))
            or "HOVER HANDS-OFF", ((c.calibrated or 0) > 0) and C.good or C.warn },
    }
    local function column(id, x, list)
        for i, r in ipairs(list) do
            local y = y0 + 4 + i * 14
            self:part(id .. i, r[2] .. r[3], function()
                D.rect(x, y, colw, 12, C.bg)
                D.text(x, y + 2, r[1], C.dim, C.bg)
                D.text(x + colw, y + 2, r[2], r[3], C.bg, 1, "r")
            end)
        end
    end
    column("l", lx, left)
    column("r", rx, right)
end

-- -------------------------------------------------------------- ALERT

function UI:alert(m, static)
    local W = D.W
    local list = m.alerts or {}
    local sig = {}
    for _, a in ipairs(list) do sig[#sig + 1] = a.level .. a.text end
    self:part("alerts", table.concat(sig, "|"), function()
        D.rect(0, TOP + 1, W, D.H - TOP - TAB_H - 2, C.bg)
        if #list == 0 then
            D.text(W / 2, TOP + 60, "ALL CLEAR", C.good, C.bg, 2, "c")
            D.text(W / 2, TOP + 84, "NO ACTIVE WARNINGS", C.dim, C.bg, 1, "c")
            return
        end
        for i, a in ipairs(list) do
            if i > 9 then break end
            local y = TOP + 6 + (i - 1) * 19
            local col = ({ bad = C.bad, warn = C.warn, info = C.accent })[a.level] or C.text
            D.rect(6, y, W - 12, 16, C.panel)
            D.rect(6, y, 4, 16, col)
            D.text(16, y + 5, a.text, col == C.accent and C.text or col, C.panel)
            if a.hint then D.text(W - 10, y + 5, a.hint, C.dim, C.panel, 1, "r") end
        end
    end)
end

-- -------------------------------------------------------------- CTRL

function UI:ctrl(m, static)
    local W, H = D.W, D.H
    local fl = m.fl
    local gx, gy = 6, TOP + 6
    local cols, rowsN = 3, 3
    local bw = math.floor((W - 12 - (cols - 1) * 6) / cols)
    local bh = math.floor((H - TAB_H - gy - 6 - (rowsN - 1) * 6) / rowsN)
    local landing = fl.phase == "landing"
    local items = {
        fl.phase == "parked"
            and { "ctl:land", "TAKE OFF", "", "primary" }
            or { "ctl:land", landing and "LANDING" or "AUTO-LAND", landing and "TAP TO CANCEL" or "DESCEND HERE", landing and "active" or (fl.phase == "flying" and "primary" or "off") },
        { "ctl:gear", "GEAR " .. (fl.gear_down and "DOWN" or "UP"), "TAP TO " .. (fl.gear_down and "RAISE" or "LOWER"), fl:feature("gear") and "normal" or "off" },
        { "ctl:mode", fl.mode:upper(), "SHIFT TOGGLES", (fl.phase == "flying" and not fl.ap and fl:feature("cruise_mode")) and "normal" or "off" },
        { "ctl:estop", fl.phase == "estop" and "RESET E-STOP" or "E-STOP", fl.phase == "estop" and "OR PRESS SPACE" or "CUTS ALL LIFT", fl.phase == "estop" and "warn" or "danger" },
        { "ctl:hold", "AUTO BRAKE", fl.t.hover.brake and "CANCEL DRIFT: ON" or "CANCEL DRIFT: OFF", fl.t.hover.brake and "active" or "normal" },
        { "ctl:rec", m.rec and ("REC " .. fmtTime(m.rec_t)) or "RECORD", m.rec and "TAP TO STOP" or "LOG THE FLIGHT", m.rec and "warn" or "normal" },
        { "ctl:print", "PRINT LOG", m.rec_n and (m.rec_n .. " SAMPLES") or "NEEDS A RECORDING", (m.rec_n or 0) > 1 and "normal" or "off" },
        { "ctl:landoff", "LAND + OFF", "THEN SHUT DOWN", (fl.phase == "flying" or landing) and "normal" or "off" },
        { "ctl:power", m.confirm == "ctl:power" and "TAP AGAIN" or "POWER OFF", (fl.phase == "parked" or fl.phase == "estop") and "CLUTCH OFF" or "SHIP WILL FALL!", m.confirm == "ctl:power" and "danger" or "normal" },
    }
    for i, it in ipairs(items) do
        local cx = gx + ((i - 1) % cols) * (bw + 6)
        local cy = gy + math.floor((i - 1) / cols) * (bh + 6)
        if static then self:hit(cx, cy, bw, bh, it[1]) end
        self:part("cb" .. i, it[2] .. it[3] .. it[4], function()
            self:button(cx, cy, bw, bh, it[2], nil, it[4], it[3] ~= "" and it[3] or nil)
        end)
    end
end

-- -------------------------------------------------------------- splash

function UI:splash(m)
    local W, H = D.W, D.H
    local booting = m.power == "booting"
    local sig = m.power .. string.format("%.0f", (m.boot_frac or 0) * 40) .. tostring(m.boot_step) .. table.concat(m.missing or {}, ",")
    if self.screen ~= "splash" then self.screen = "splash" self.sig = {} self.hits = {} self.full = false
        D.rect(0, 0, W, H, C.bg)
    end
    self:part("splash", sig, function()
        self.hits = {}
        D.rect(0, 0, W, H, C.bg)
        D.rect(0, 0, W, 3, C.accent)
        local name = "ATLAS" -- this OS flies one ship: the title never follows the config's name
        local sc = 4
        while sc > 1 and D.textW(name, sc) > W - 20 do sc = sc - 1 end
        D.text(W / 2, 44, name, C.white, C.bg, sc, "c")
        D.rect(W / 2 - 30, 44 + 7 * sc + 4, 60, 2, C.accent)
        D.text(W / 2, 44 + 7 * sc + 10, "ARTCORP FLIGHT OS  V" .. V.number, C.dim, C.bg, 1, "c")
        local by = 128
        if booting then
            D.text(W / 2, by - 14, m.boot_step or "STARTING", C.accent, C.bg, 1, "c")
            bar(W / 2 - 100, by, 200, 8, m.boot_frac or 0, C.accent)
        else
            self:button(W / 2 - 75, by - 8, 150, 30, "START ENGINES", "boot", "primary")
        end
        if m.missing and #m.missing > 0 then
            D.text(W / 2, H - 22, "MISSING: " .. table.concat(m.missing, " "):upper(), C.bad, C.bg, 1, "c")
        end
    end)
end

-- -------------------------------------------------------------- text wrap

-- Word-wraps text into lines of at most `maxc` characters (6 px each).
local function wrap(text, maxc)
    local lines, cur = {}, ""
    for w in tostring(text):gmatch("%S+") do
        local word = w
        while #word > maxc do -- a word longer than a line: cut it
            if cur ~= "" then lines[#lines + 1] = cur cur = "" end
            lines[#lines + 1] = word:sub(1, maxc)
            word = word:sub(maxc + 1)
        end
        if cur == "" then cur = word
        elseif #cur + 1 + #word <= maxc then cur = cur .. " " .. word
        else lines[#lines + 1] = cur cur = word end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
end
UI.wrap = wrap

local function maxChars(w) return math.floor((w + 1) / 6) end

-- -------------------------------------------------------------- tour
-- One real element at a time: the screen it lives on is drawn dimmed except
-- that element, which gets an accent frame and a popup saying what it does.
-- Elements are found by their touch actions (`find`: patterns, the union of
-- every matching hit area), so the frame follows the real layout; the few
-- that are not buttons give a `rect`. While the tour is up only its own
-- NEXT / SKIP buttons take taps (UI:touch).

-- SHIP tab geometry (UI:ship): row i of the right-hand column.
local function shipRow(i)
    local colw = math.floor((D.W - 18) / 2)
    local y = TOP + 6 + 4 + i * 14
    return { x = 12 + colw - 2, y = y - 1, w = colw + 4, h = 14 }
end

local TOUR = {
    { screen = "splash", find = { "^boot$" }, title = "START ENGINES",
        text = "FIRST OPEN THE STEAM ENGINE'S WATER INPUT VALVE BY HAND: THE OS CAN'T DO THAT. THEN TAP START ENGINES (OR PRESS SPACE)." },
    { screen = "fly", find = { "^tab:" }, title = "TABS",
        text = "FLY: ATTITUDE + NUMBERS. NAV: MAP + WAYPOINTS. AUTO: AUTOPILOT. SHIP: HARDWARE + LEARNING. ALERT: WARNINGS. CTRL: BIG BUTTONS." },
    { screen = "ctrl", find = { "^ctl:land$" }, title = "TAKE OFF",
        text = "LIFTS THE SHIP OFF THE GROUND. IN THE AIR THE SAME BUTTON LANDS RIGHT WHERE YOU ARE." },
    { screen = "ctrl", find = { "^ctl:estop$" }, title = "E-STOP",
        text = "CUTS ALL LIFT AT ONCE: THE SHIP FALLS. EMERGENCIES ONLY. TAP AGAIN (OR SPACE) TO RESET." },
    { screen = "nav", find = { "^wp:row:", "^wp:up$", "^wp:down$" }, title = "WAYPOINTS",
        text = "YOUR SAVED PLACES: TAP ONE TO PICK IT. SAVE HERE STORES WHERE THE SHIP IS, NEW TAKES COORDINATES FROM THE KEYBOARD COMPUTER." },
    { screen = "nav", find = { "^wp:fly$" }, title = "FLY",
        text = "FLIES TO THE PICKED WAYPOINT ON AUTOPILOT: CLIMB, CRUISE, STOP AND LAND." },
    { screen = "auto", find = { "^tab:auto$" }, title = "AUTO",
        text = "THE AUTO TAB FOLLOWS AN AUTOPILOT RUN: STAGE, DISTANCE, ETA. CANCEL A/P HANDS THE SHIP BACK TO YOU, HOVERING." },
    { screen = "ship", title = "CALIBRATION", rect = function() return shipRow(9) end,
        text = "AFTER TAKE-OFF, HOVER HANDS-OFF UNTIL THIS SAYS DONE (FROZEN). THE SHIP LEARNS ITS TRIMS, THEN KEEPS THEM." },
    { screen = "ship", find = { "^ship:disk" }, title = "SAVE / LOAD DISK",
        text = "BACKS UP THIS WORLD'S DATA (WAYPOINTS, MEASURED AIR, LEARNED TRIMS) TO A FLOPPY IN ANY DISK DRIVE, OR LOADS IT BACK." },
    { screen = "fly", find = { "^tour:start$" }, title = "THIS TOUR",
        text = "TAP ? ANY TIME ON THE GROUND TO SEE THIS TOUR AGAIN. HAPPY FLYING!" },
}
UI.TOUR = TOUR

function UI:tourStart()
    self.tour = { i = 1, prev = self.tab, hits = {} }
    self.full = true
end

-- Next step; true when that was the last one (the tour is over).
function UI:tourNext()
    local t = self.tour
    if not t then return true end
    t.i = t.i + 1
    if t.i > #TOUR then self:tourEnd() return true end
    return false
end

function UI:tourEnd()
    local t = self.tour
    if not t then return end
    self.tour = nil
    self.tab = t.prev or "fly"
    self.screen, self.full, self.hits, self.sig = nil, true, {}, {}
end

-- Draws screen `scr` ("splash" or a tab) for the tour. The splash is shown
-- as on the ground (its START button is the element being explained).
function UI:tourScreen(m, scr, full)
    if scr == "splash" then
        if full then self.screen = nil end
        local m2 = {}
        for k, v in pairs(m) do m2[k] = v end
        m2.power = "off"
        return self:splash(m2)
    end
    self.tab = scr
    if full then
        self.hits = {}
        self:chrome(m)
        self.screen = scr
    end
    self:topBar(m)
    self:tabBar(m)
    self[scr](self, m, full)
end

function UI:tourTarget(st)
    if st.rect then return st.rect() end
    local x0, y0, x1, y1
    for _, h in ipairs(self.hits) do
        for _, pat in ipairs(st.find) do
            if h.action:match(pat) then
                x0, y0 = math.min(x0 or h.x, h.x), math.min(y0 or h.y, h.y)
                x1, y1 = math.max(x1 or 0, h.x + h.w), math.max(y1 or 0, h.y + h.h)
                break
            end
        end
    end
    if not x0 then return { x = 0, y = TOP + 1, w = D.W, h = D.H - TOP - TAB_H - 2 } end
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- The accent frame round the element and the popup next to it.
function UI:tourPopup(t, st)
    local W, H = D.W, D.H
    local r = t.rect
    -- (kept on screen: an element at the edge still gets all four sides)
    for k = 2, 3 do
        local x0, y0 = math.max(r.x - k, 0), math.max(r.y - k, 0)
        local x1, y1 = math.min(r.x + r.w + k, W), math.min(r.y + r.h + k, H)
        D.frame(x0, y0, x1 - x0, y1 - y0, C.accent)
    end
    local pw = math.min(W - 8, 232)
    local lines = wrap(st.text, maxChars(pw - 12))
    local ph = 19 + #lines * 10 + 30
    local px = U.clamp(math.floor(r.x + r.w / 2 - pw / 2), 4, W - pw - 4)
    local py
    if r.y + r.h + 6 + ph <= H - 2 then py = r.y + r.h + 6          -- below
    elseif r.y - 6 - ph >= 2 then py = r.y - 6 - ph                 -- above
    else
        py = U.clamp(r.y, 2, H - ph - 2)
        if r.x + r.w + 6 + pw <= W - 2 then px = r.x + r.w + 6      -- right
        elseif r.x - 6 - pw >= 2 then px = r.x - 6 - pw             -- left
        -- no room anywhere: the bigger gap, over the (dimmed) bars
        elseif H - (r.y + r.h) >= r.y then py = H - ph - 2
        else py = 2 end
    end
    D.rect(px, py, pw, ph, C.panel)
    D.frame(px, py, pw, ph, C.accent)
    D.text(px + 6, py + 6, st.title, C.accent, C.panel)
    D.text(px + pw - 6, py + 6, t.i .. "/" .. #TOUR, C.dim, C.panel, 1, "r")
    for i, l in ipairs(lines) do D.text(px + 6, py + 19 + (i - 1) * 10, l, C.text, C.panel) end
    local saved = self.hits
    self.hits = {}
    local by = py + ph - 24
    self:button(px + 6, by, 64, 18, "SKIP", "tour:skip", "normal")
    self:button(px + pw - 70, by, 64, 18, t.i == #TOUR and "DONE" or "NEXT >", "tour:next", "primary")
    t.hits, self.hits = self.hits, saved
end

function UI:tourFrame(m)
    local t = self.tour
    local st = TOUR[t.i]
    if t.drawn ~= t.i or self.full then
        self.full = false
        -- lay the screen out unseen to find the element, then draw it dimmed
        -- around that element
        D.dry = true
        self:tourScreen(m, st.screen, true)
        D.dry = false
        t.rect = self:tourTarget(st)
        D.keep = t.rect
        self:tourScreen(m, st.screen, true)
        D.keep = nil
        t.drawn = t.i
        self:tourPopup(t, st)
        return
    end
    -- live values keep updating (dimmed); the popup goes back on top of
    -- anything they drew
    local n0 = D.n
    D.keep = t.rect
    self:tourScreen(m, st.screen, false)
    D.keep = nil
    if D.n ~= n0 then self:tourPopup(t, st) end
end

-- -------------------------------------------------------------- frame

function UI:render(m)
    if not D.ok then return end
    D.begin()
    if self.tour then
        local ok, err = pcall(self.tourFrame, self, m)
        D.dry, D.keep = false, nil -- an error must not leave the screen dimmed
        D.finish()
        if not ok then self.full = true error(err, 0) end
        return
    end
    if m.power ~= "on" then
        self:splash(m)
        D.finish()
        return
    end
    local full = self.full or self.screen ~= self.tab
    if full then
        self.hits = {}
        self:chrome(m)
        self.screen = self.tab
        self.full = false
    end
    self:topBar(m)
    self:tabBar(m)
    local fn = self[self.tab]
    if fn then fn(self, m, full) end
    D.finish()
end

-- touch in PIXELS -> action string (or nil)
-- While the tour is up only its own buttons answer (nothing underneath).
function UI:touch(px, py)
    local hits = self.tour and (self.tour.hits or {}) or self.hits
    for i = #hits, 1, -1 do
        local h = hits[i]
        if px >= h.x and px < h.x + h.w and py >= h.y and py < h.y + h.h then return h.action end
    end
end

return UI
