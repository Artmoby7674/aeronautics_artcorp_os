-- v2 atmosphere model, LEARNED from the ship's own flights.
--
-- Servers set the atmosphere differently (thicker, thinner, a ceiling at
-- Y300 or at Y1000), so nothing about the air is trusted from the tuning
-- file once the ship has flown. Whenever the ship hangs steady at some
-- altitude, the prop speed it needs to hover there IS the air at that
-- altitude. Those measurements are kept in 10 m bands; between measured
-- bands the hover speed is interpolated, beyond them it is extended with the
-- trend measured so far (the tuning file's exponential curve until there is
-- enough height spread to measure one).
--
-- Everything that needs the air asks this module:
--   hoverAt(h)   prop speed that holds the ship up at altitude h
--   press(h)     air density at h relative to press_ref (1 = reference)
--   ceiling(m)   highest altitude where hovering leaves m prop units spare
local U = require("util")

local Atmos = {}
Atmos.__index = Atmos

local BAND = 10        -- m per band
local TAU = 8          -- s: smoothing of one band's measurement
local MIN_W = 3        -- s of steady hovering before a band counts
local MAX_W = 120      -- s: weight cap (old bands still move when the air changes)
local MIN_SPAN = 30    -- m of measured height spread before the trend is measured
local K_MIN, K_MAX = 0.0002, 0.03

function Atmos.new(tune, base_hover)
    local self = setmetatable({}, Atmos)
    self.t = tune
    self.base_hover = base_hover or tune.ship.hover_throttle
    self.bands = {} -- [index] = { ln = log(hover speed), w = seconds seen }
    self.dirty = false
    return self
end

-- ---------------------------------------------------------------- learning

-- Feed one tick of flight. `thr` = the hover prop speed measured right now
-- (lift actually used, corrected for climb acceleration, airflow and tilt).
function Atmos:observe(alt, thr, dt)
    if not (alt and thr) or thr <= 0.2 or thr > 20 then return end
    local i = math.floor(alt / BAND)
    local b = self.bands[i]
    local ln = math.log(thr)
    if not b then
        b = { ln = ln, h = alt, w = 0 }
        self.bands[i] = b
    end
    b.ln = U.lowpass(b.ln, ln, dt, TAU)
    -- where in the band it was measured (placing it at the band's middle
    -- instead put a 1-2 % error on the hover speed)
    b.h = U.lowpass(b.h or alt, alt, dt, TAU)
    b.w = math.min(b.w + dt, MAX_W)
    self.cache = nil
    self.dirty = true
end

-- Valid bands, low to high: { { h = centre, ln = ..., w = ... }, ... }
function Atmos:points()
    if self.cache then return self.cache end
    local pts = {}
    for i, b in pairs(self.bands) do
        if b.w >= MIN_W then pts[#pts + 1] = { h = b.h or (i + 0.5) * BAND, ln = b.ln, w = b.w } end
    end
    table.sort(pts, function(a, b) return a.h < b.h end)
    -- trend (ln speed per metre): weighted least squares once the measured
    -- heights spread far enough, else the tuning file's curve
    local k = self.t.physics.press_k
    local measured = false
    if #pts >= 2 and pts[#pts].h - pts[1].h >= MIN_SPAN then
        local sw, sh, sl = 0, 0, 0
        for _, p in ipairs(pts) do sw, sh, sl = sw + p.w, sh + p.w * p.h, sl + p.w * p.ln end
        local mh, ml = sh / sw, sl / sw
        local num, den = 0, 0
        for _, p in ipairs(pts) do
            num = num + p.w * (p.h - mh) * (p.ln - ml)
            den = den + p.w * (p.h - mh) ^ 2
        end
        if den > 0 then
            k = U.clamp(num / den, K_MIN, K_MAX)
            measured = true
        end
    end
    pts.k, pts.measured = k, measured
    self.cache = pts
    return pts
end

-- ---------------------------------------------------------------- model

-- Prop speed that holds the ship up at altitude h.
function Atmos:hoverAt(h)
    local pts = self:points()
    local k = pts.k
    if #pts == 0 then
        local ph = self.t.physics
        return self.base_hover * math.exp(k * (h - ph.press_ref))
    end
    if h <= pts[1].h then return math.exp(pts[1].ln + k * (h - pts[1].h)) end
    local last = pts[#pts]
    if h >= last.h then return math.exp(last.ln + k * (h - last.h)) end
    for j = 1, #pts - 1 do
        local a, b = pts[j], pts[j + 1]
        if h <= b.h then
            local f = (h - a.h) / (b.h - a.h)
            return math.exp(a.ln + f * (b.ln - a.ln))
        end
    end
    return math.exp(last.ln)
end

-- Air density at h relative to the reference altitude (what lift scales with).
function Atmos:press(h)
    return self:hoverAt(self.t.physics.press_ref) / self:hoverAt(h)
end

-- Highest altitude (searched up from `from`, capped at `cap`) where hovering
-- still leaves `margin` prop units spare.
function Atmos:ceiling(margin, from, cap)
    local need = 15 - margin
    local h = from
    if self:hoverAt(h) > need then return h end
    while h < cap do
        if self:hoverAt(h + 5) > need then return h end
        h = h + 5
    end
    return cap
end

-- One line for the log / screen.
function Atmos:summary()
    local pts = self:points()
    local lo, hi = pts[1], pts[#pts]
    return string.format("%d bands%s, trend %.4f/m (%s), hover %.2f at Y%.0f",
        #pts, lo and string.format(" Y%.0f-Y%.0f", lo.h, hi.h) or "",
        pts.k, pts.measured and "measured" or "assumed", self:hoverAt(self.t.physics.press_ref),
        self.t.physics.press_ref)
end

-- ---------------------------------------------------------------- disk

function Atmos:toTable()
    local out = { band = BAND, bands = {} }
    for i, b in pairs(self.bands) do out.bands[#out.bands + 1] = { i = i, ln = b.ln, h = b.h, w = b.w } end
    return out
end

function Atmos:fromTable(t)
    if type(t) ~= "table" or t.band ~= BAND or type(t.bands) ~= "table" then return false end
    self.bands = {}
    for _, b in ipairs(t.bands) do
        if type(b.i) == "number" and type(b.ln) == "number" and type(b.w) == "number" then
            self.bands[b.i] = { ln = b.ln, h = type(b.h) == "number" and b.h or (b.i + 0.5) * BAND, w = b.w }
        end
    end
    self.cache = nil
    return true
end

function Atmos:reset()
    self.bands, self.cache, self.dirty = {}, nil, true
end

return Atmos
