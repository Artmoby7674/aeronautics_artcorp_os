-- v2 flight recorder: one sample every 5 s while recording (memory only),
-- printed as a one-page summary with an altitude profile.
local U = require("util")

local Rec = { on = false, samples = {}, t0 = 0, last = -1e9 }
local EVERY, CAP = 5, 1500

function Rec.toggle(now)
    Rec.on = not Rec.on
    if Rec.on then Rec.samples, Rec.t0, Rec.last = {}, now, -1e9 end
    return Rec.on
end

function Rec.tick(now, s)
    if not Rec.on or not s.valid or now - Rec.last < EVERY then return end
    Rec.last = now
    local n = Rec.samples
    if #n >= CAP then table.remove(n, 1) end
    n[#n + 1] = { t = now - Rec.t0, x = s.x, y = s.alt, z = s.z, v = s.hspeed }
end

function Rec.duration()
    local n = Rec.samples
    if #n == 0 then return 0 end
    return n[#n].t - n[1].t
end

local function findPrinter()
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "printer" then return peripheral.wrap(n) end
    end
end

function Rec.print(shipname)
    local n = Rec.samples
    if #n < 2 then return false, "NOTHING RECORDED" end
    local p = findPrinter()
    if not p then return false, "NO PRINTER" end
    if (p.getPaperLevel() or 0) < 1 then return false, "NO PAPER" end
    if (p.getInkLevel() or 0) < 1 then return false, "NO INK" end
    if not p.newPage() then return false, "PRINTER BUSY" end
    local W, H = p.getPageSize()
    p.setPageTitle((shipname or "SHIP") .. " FLIGHT")
    local lo, hi, dist, vmax = math.huge, -math.huge, 0, 0
    for i, s in ipairs(n) do
        lo, hi = math.min(lo, s.y), math.max(hi, s.y)
        vmax = math.max(vmax, s.v or 0)
        if i > 1 then dist = dist + U.hypot(s.x - n[i - 1].x, s.z - n[i - 1].z) end
    end
    local lines = {
        (shipname or "SHIP") .. " FLIGHT LOG",
        string.format("TIME %dm%02ds", math.floor(Rec.duration() / 60), math.floor(Rec.duration() % 60)),
        string.format("DIST %.0f m  MAX %.0f m/s", dist, vmax),
        string.format("ALT %.0f - %.0f", lo, hi),
        string.format("FROM %.0f %.0f", n[1].x, n[1].z),
        string.format("TO   %.0f %.0f", n[#n].x, n[#n].z),
    }
    for i, l in ipairs(lines) do p.setCursorPos(1, i) p.write(l:sub(1, W)) end
    -- altitude profile: columns = time, rows = height
    local top, rows = #lines + 2, H - #lines - 2
    if rows >= 3 then
        local span = math.max(hi - lo, 1)
        for c = 1, W do
            local i = math.max(1, math.floor((c - 1) / (W - 1) * (#n - 1) + 1.5))
            local r = math.floor((n[i].y - lo) / span * (rows - 1) + 0.5)
            p.setCursorPos(c, top + rows - 1 - r)
            p.write("*")
        end
    end
    p.endPage()
    return true
end

return Rec
