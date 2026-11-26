-- v2 drawing layer over CC:Graphics (monitor graphics mode 2, 0-based pixels).
-- Owns the colour palette: v2 redefines the 16 palette slots for a darker,
-- higher-contrast cockpit look and puts the stock colours back on exit.
local Font = require("font")

local D = { W = 0, H = 0, ok = false, n = 0 }

-- palette slot -> name, RGB
D.C = {
    bg = 0, panel = 1, panel2 = 2, line = 3, dim = 4, text = 5, white = 6,
    accent = 7, accent_dk = 8, good = 9, warn = 10, bad = 11, sky = 12,
    ground = 13, ap = 14, black = 15,
}
local PALETTE = {
    [0] = 0x0B0F14, [1] = 0x151C26, [2] = 0x1F2935, [3] = 0x2E3A4A,
    [4] = 0x6E7D8F, [5] = 0xC6D0DB, [6] = 0xFFFFFF, [7] = 0x3FC8E4,
    [8] = 0x1D5E70, [9] = 0x4CD07D, [10] = 0xF2B33D, [11] = 0xEF5350,
    [12] = 0x2F6FA8, [13] = 0x7A5430, [14] = 0xB388FF, [15] = 0x000000,
}
D.PALETTE = PALETTE

-- The tour (ui.lua) dims everything but the element it explains by drawing
-- the screen again in darker colours. Mode 2 has 256 palette slots, so where
-- they can be set, slots 16-31 hold the 16 colours at ~40 % (a true dimmed
-- copy). Otherwise each colour falls back to a darker one of the 16 (a muted
-- silhouette), which every monitor can show.
local DIM_TO = { bg = "bg", panel = "bg", panel2 = "panel", line = "panel2", dim = "line",
    text = "dim", white = "dim", accent = "accent_dk", accent_dk = "panel2", good = "line",
    warn = "line", bad = "line", sky = "panel2", ground = "panel", ap = "line", black = "black" }
local DIM_K = 0.4
D.dim_map = {}

local mon
local STOCK

-- Graphics calls go through `dev`: the monitor itself when CC:Graphics adds
-- its methods to monitor peripherals, otherwise the terminal API redirected
-- to the monitor (the original OS supported both; the gfxcheck tool existed
-- to tell them apart). Without this fallback v2 would run headless on such
-- a monitor: nothing drawn, so the old screen stays up and no taps register.
local dev

local function viaTerm(m)
    local function wrap(name)
        return function(...)
            local f = term[name]
            if type(f) ~= "function" then error(name .. " not on term", 0) end
            local old = term.redirect(m)
            local r = table.pack(pcall(f, ...))
            term.redirect(old)
            if not r[1] then error(r[2], 0) end
            return table.unpack(r, 2, r.n)
        end
    end
    local d = {}
    for _, n in ipairs({ "setGraphicsMode", "drawPixels", "setFrozen", "setPaletteColor", "getPaletteColor" }) do
        d[n] = wrap(n)
    end
    return d
end

local function pixelSize(m)
    local ok, w, h = pcall(m.getSize, 2)
    local okt, tw, th = pcall(m.getSize)
    if ok and type(w) == "number" and okt and (w ~= tw or h ~= th) then return w, h end
    if okt and type(tw) == "number" then return tw * 6, th * 9 end
    return 0, 0
end

function D.init(m, use_palette)
    mon = m
    pcall(m.setTextScale, 0.5)
    D.path, dev, D.ok = nil, nil, false
    if type(m.setGraphicsMode) == "function" and type(m.drawPixels) == "function"
        and pcall(m.setGraphicsMode, 2) then
        dev, D.path = m, "direct"
    elseif type(term.setGraphicsMode) == "function" then
        local d = viaTerm(m)
        if pcall(d.setGraphicsMode, 2) then dev, D.path = d, "redirect" end
    end
    if not dev then
        -- no pixel graphics at all: say so on the monitor instead of leaving
        -- the previous OS's picture up (which looks like a frozen screen)
        pcall(function()
            m.setBackgroundColor(colors.black)
            m.clear()
            m.setCursorPos(2, 2)
            m.setTextColor(colors.red)
            m.write("ArtCorp OS v2: no CC:Graphics on this monitor")
            m.setCursorPos(2, 4)
            m.setTextColor(colors.white)
            m.write("Pilot keys still work: SPACE starts the engines.")
        end)
        return false, "monitor has no CC:Graphics mode 2 (direct or via term)"
    end
    D.W, D.H = pixelSize(m)
    D.ok = D.W > 0
    D.palette_ok = use_palette ~= false and D.setPalette()
    if not D.palette_ok then
        -- the stock 16 colours, mapped to the closest roles
        for k, v in pairs(STOCK) do D.C[k] = v end
        D.dim_map = {}
        for role, to in pairs(DIM_TO) do D.dim_map[D.C[role]] = D.C[to] end
    end
    return D.ok
end

-- stock CC colour index (log2 of colors.X) for each role
STOCK = { bg = 15, panel = 7, panel2 = 7, line = 8, dim = 8, text = 0, white = 0,
    accent = 9, accent_dk = 11, good = 5, warn = 4, bad = 14, sky = 3, ground = 12,
    ap = 10, black = 15 }

-- Graphics mode 2 takes raw palette indices; plain CC takes colour bits.
-- Try raw first, verify by reading back, and report whether it stuck.
function D.setPalette()
    local function rgb3(rgb)
        return math.floor(rgb / 65536) % 256 / 255, math.floor(rgb / 256) % 256 / 255, rgb % 256 / 255
    end
    for _, idx in ipairs({ function(i) return i end, function(i) return 2 ^ i end }) do
        local good = true
        for i, rgb in pairs(PALETTE) do
            local r, g, b = rgb3(rgb)
            if not pcall(dev.setPaletteColor, idx(i), r, g, b) then good = false break end
        end
        if good and type(dev.getPaletteColor) == "function" then
            local ok, r = pcall(dev.getPaletteColor, idx(7))
            local want = rgb3(PALETTE[7])
            if not ok or type(r) ~= "number" or math.abs(r - want) > 0.02 then good = false end
        end
        if good then
            D.setDimPalette(idx(0) == 0, rgb3)
            return true
        end
    end
    return false
end

-- Dimmed copies in slots 16-31, only with raw indices (mode 2) and only if
-- the monitor keeps them (read back when it can be). Otherwise: DIM_TO.
function D.setDimPalette(raw, rgb3)
    D.dim_map = {}
    for role, to in pairs(DIM_TO) do D.dim_map[D.C[role]] = D.C[to] end
    if not raw then return false end
    for i = 0, 15 do
        local r, g, b = rgb3(PALETTE[i])
        if not pcall(dev.setPaletteColor, 16 + i, r * DIM_K, g * DIM_K, b * DIM_K) then return false end
    end
    if type(dev.getPaletteColor) ~= "function" then return false end
    local ok, r = pcall(dev.getPaletteColor, 16 + 7)
    if not ok or type(r) ~= "number" or math.abs(r - rgb3(PALETTE[7]) * DIM_K) > 0.02 then return false end
    for i = 0, 15 do D.dim_map[i] = 16 + i end
    return true
end

-- RGB of a dimmed slot (for the screenshot renderer).
function D.dimRGB(rgb)
    local r, g, b = math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256
    return math.floor(r * DIM_K) * 65536 + math.floor(g * DIM_K) * 256 + math.floor(b * DIM_K)
end

function D.shutdown()
    if not dev then return end
    for i = 0, 15 do
        local okn, r, g, b = pcall(term.nativePaletteColour, 2 ^ i)
        if okn and r then pcall(dev.setPaletteColor, i, r, g, b) end
    end
    pcall(dev.setFrozen, false)
    pcall(dev.setGraphicsMode, 0)
    D.ok = false
end

function D.begin() pcall(dev.setFrozen, true) end
function D.finish() pcall(dev.setFrozen, false) end

local function clip(x, y, w, h)
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    if x < 0 then w, x = w + x, 0 end
    if y < 0 then h, y = h + y, 0 end
    if x + w > D.W then w = D.W - x end
    if y + h > D.H then h = D.H - y end
    if w < 1 or h < 1 then return nil end
    return x, y, w, h
end

-- D.dry: draw nothing (the tour lays a screen out first to find where an
-- element is). D.keep = {x,y,w,h}: dim everything drawn outside it.
local function fill(x, y, w, h, c)
    if w < 1 or h < 1 then return end
    D.n = D.n + 1
    dev.drawPixels(x, y, c, w, h)
end

function D.rect(x, y, w, h, c)
    if D.dry then return end
    local cx, cy, cw, ch = clip(x, y, w, h)
    if not cx then return end
    local k = D.keep
    if not k then return fill(cx, cy, cw, ch, c) end
    local dc = D.dim_map[c] or c
    -- bands above / below the kept rect, then left / inside / right of it
    local y1, y2 = math.max(cy, k.y), math.min(cy + ch, k.y + k.h)
    if y2 <= y1 then return fill(cx, cy, cw, ch, dc) end
    fill(cx, cy, cw, y1 - cy, dc)
    fill(cx, y2, cw, cy + ch - y2, dc)
    local x1, x2 = math.max(cx, k.x), math.min(cx + cw, k.x + k.w)
    if x2 <= x1 then return fill(cx, y1, cw, y2 - y1, dc) end
    fill(cx, y1, x1 - cx, y2 - y1, dc)
    fill(x1, y1, x2 - x1, y2 - y1, c)
    fill(x2, y1, cx + cw - x2, y2 - y1, dc)
end

function D.frame(x, y, w, h, c)
    D.rect(x, y, w, 1, c)
    D.rect(x, y + h - 1, w, 1, c)
    D.rect(x, y, 1, h, c)
    D.rect(x + w - 1, y, 1, h, c)
end

-- rows = { {c,...}, ... } at x,y (clipped on the right/bottom only)
function D.blit(x, y, rows)
    if D.dry then return end
    if x < 0 or y < 0 or x >= D.W or y >= D.H or #rows == 0 then return end
    local maxw, maxh = D.W - x, D.H - y
    if #rows > maxh or #rows[1] > maxw then
        local cut = {}
        for r = 1, math.min(#rows, maxh) do
            local line = {}
            for c = 1, math.min(#rows[r], maxw) do line[c] = rows[r][c] end
            cut[r] = line
        end
        rows = cut
    end
    x, y = math.floor(x), math.floor(y)
    local k = D.keep
    if k then
        -- a dimmed copy (glyph rows may be shared: never change them)
        local map, out = D.dim_map, {}
        for r = 1, #rows do
            local src, line, py = rows[r], {}, y + r - 1
            local inY = py >= k.y and py < k.y + k.h
            for c = 1, #src do
                local px, v = x + c - 1, src[c]
                if inY and px >= k.x and px < k.x + k.w then line[c] = v else line[c] = map[v] or v end
            end
            out[r] = line
        end
        rows = out
    end
    D.n = D.n + 1
    dev.drawPixels(x, y, rows)
end

function D.textW(str, scale) return Font.width(tostring(str), scale) end

-- align: "l" | "c" | "r" relative to x (c/r: x is the centre / right edge)
function D.text(x, y, str, fg, bg, scale, align)
    str = tostring(str)
    if str == "" then return end
    scale = scale or 1
    local w = Font.width(str, scale)
    if align == "c" then x = x - math.floor(w / 2) elseif align == "r" then x = x - w end
    D.blit(x, y, Font.render(str, fg, bg, scale))
end

-- Text fitted into a fixed slot: clears the slot first (so shorter text
-- never leaves stale pixels) and trims to the slot width.
function D.slot(x, y, w, str, fg, bg, scale, align)
    scale = scale or 1
    D.rect(x, y, w, 7 * scale, bg)
    str = tostring(str)
    local maxc = math.floor((w + scale) / (Font.adv * scale))
    if #str > maxc then str = str:sub(1, math.max(maxc, 0)) end
    if align == "c" then D.text(x + math.floor(w / 2), y, str, fg, bg, scale, "c")
    elseif align == "r" then D.text(x + w, y, str, fg, bg, scale, "r")
    else D.text(x, y, str, fg, bg, scale) end
end

-- A pixel buffer for drawn regions (horizon, map), blitted in one call.
function D.canvas(w, h, bg)
    local cv = { w = w, h = h, rows = {} }
    for y = 1, h do
        local line = {}
        for x = 1, w do line[x] = bg end
        cv.rows[y] = line
    end
    function cv.set(x, y, c)
        x, y = math.floor(x), math.floor(y)
        if x >= 0 and y >= 0 and x < w and y < h then cv.rows[y + 1][x + 1] = c end
    end
    function cv.fill(x, y, ww, hh, c)
        x, y = math.floor(x + 0.5), math.floor(y + 0.5)
        for yy = math.max(0, y), math.min(h - 1, y + hh - 1) do
            local line = cv.rows[yy + 1]
            for xx = math.max(0, x), math.min(w - 1, x + ww - 1) do line[xx + 1] = c end
        end
    end
    function cv.line(x0, y0, x1, y1, c)
        local n = math.max(math.abs(x1 - x0), math.abs(y1 - y0), 1)
        for i = 0, n do cv.set(x0 + (x1 - x0) * i / n + 0.5, y0 + (y1 - y0) * i / n + 0.5, c) end
    end
    return cv
end

return D
